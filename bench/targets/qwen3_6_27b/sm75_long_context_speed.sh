#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Token-calibrated long-context speed curve for RTX 2080 Ti 22GB / Qwen3.8-27B.
#
# The server is loaded once. Prompt sizes are calibrated through /v1/messages/count_tokens, then
# NInfer's request-log JSONL is used as the timing authority. Decode throughput is therefore based
# on engine decode_seconds, not HTTP wall time or TTFT:
#
#   decode_tok_s = (completion_tokens - 1) / timings_seconds.decode
#
# The first successful context is the retention baseline. Later rows report decode throughput as a
# percentage of that baseline. MIN_RETENTION_PCT defaults to 0 (report-only) until a physical-card
# curve has been qualified; set it explicitly to turn retention into an acceptance gate.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_long_context_speed.sh MODEL.ninfer [NINFER_SERVE_BIN]
#
# Environment:
#   DEVICE=0
#   MAX_CONTEXT=65536
#   SPEED_CONTEXTS="8192 32768 65536 131072 196608 262144"
#   OUTPUT_TOKENS=256
#   MIN_COMPLETION_TOKENS=64
#   RESERVE_TOKENS=320
#   PREFILL_CHUNK=1024
#   KV_DTYPE=rk4v4-e8
#   MTP_DRAFT=3
#   PORT=18081
#   LOG_DIR=sm75-long-context-speed
#   MIN_RETENTION_PCT=0

MODEL=${1:-}
SERVE_BIN=${2:-./build/apps/ninfer-serve}
DEVICE=${DEVICE:-0}
MAX_CONTEXT=${MAX_CONTEXT:-65536}
SPEED_CONTEXTS=${SPEED_CONTEXTS:-"8192 32768 65536 131072 196608 262144"}
OUTPUT_TOKENS=${OUTPUT_TOKENS:-256}
MIN_COMPLETION_TOKENS=${MIN_COMPLETION_TOKENS:-64}
RESERVE_TOKENS=${RESERVE_TOKENS:-320}
PREFILL_CHUNK=${PREFILL_CHUNK:-1024}
KV_DTYPE=${KV_DTYPE:-rk4v4-e8}
MTP_DRAFT=${MTP_DRAFT:-3}
PORT=${PORT:-18081}
LOG_DIR=${LOG_DIR:-sm75-long-context-speed}
MIN_RETENTION_PCT=${MIN_RETENTION_PCT:-0}
MODEL_ID=sm75-qwen3.8-27b-speed
HOST=127.0.0.1

fail() {
  echo "error: $*" >&2
  exit 2
}

[[ -n "${MODEL}" ]] || fail "usage: $0 MODEL.ninfer [NINFER_SERVE_BIN]"
[[ -f "${MODEL}" ]] || fail "model not found: ${MODEL}"
[[ -x "${SERVE_BIN}" ]] || fail "ninfer-serve not executable: ${SERVE_BIN}"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ "${DEVICE}" =~ ^[0-9]+$ ]] || fail "DEVICE must be a non-negative integer"
[[ "${MAX_CONTEXT}" =~ ^[0-9]+$ ]] && (( MAX_CONTEXT >= 4096 && MAX_CONTEXT <= 262144 )) || \
  fail "MAX_CONTEXT must be in [4096,262144]"
[[ "${OUTPUT_TOKENS}" =~ ^[0-9]+$ ]] && (( OUTPUT_TOKENS >= 64 )) || \
  fail "OUTPUT_TOKENS must be at least 64"
[[ "${MIN_COMPLETION_TOKENS}" =~ ^[0-9]+$ ]] && \
  (( MIN_COMPLETION_TOKENS >= 16 && MIN_COMPLETION_TOKENS <= OUTPUT_TOKENS )) || \
  fail "MIN_COMPLETION_TOKENS must be in [16,OUTPUT_TOKENS]"
[[ "${RESERVE_TOKENS}" =~ ^[0-9]+$ ]] && (( RESERVE_TOKENS > OUTPUT_TOKENS )) || \
  fail "RESERVE_TOKENS must be greater than OUTPUT_TOKENS"
[[ "${PREFILL_CHUNK}" =~ ^[0-9]+$ ]] && (( PREFILL_CHUNK > 0 && PREFILL_CHUNK % 128 == 0 )) || \
  fail "PREFILL_CHUNK must be a positive multiple of 128"
[[ "${MTP_DRAFT}" =~ ^[0-9]+$ ]] && (( MTP_DRAFT <= 5 )) || fail "MTP_DRAFT must be in [0,5]"
[[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT <= 65535 )) || fail "invalid PORT"
[[ "${KV_DTYPE}" == "int8" || "${KV_DTYPE}" == "rk4v4-e8" ]] || \
  fail "KV_DTYPE must be int8 or rk4v4-e8"
python3 - "${MIN_RETENTION_PCT}" <<'PY' || fail "MIN_RETENTION_PCT must be a number in [0,100]"
import sys
try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if 0.0 <= value <= 100.0 else 1)
PY

for context in ${SPEED_CONTEXTS}; do
  [[ "${context}" =~ ^[0-9]+$ ]] && (( context >= 4096 && context <= 262144 )) || \
    fail "invalid SPEED_CONTEXTS entry: ${context}"
done

mkdir -p "${LOG_DIR}"
SERVER_LOG="${LOG_DIR}/server.log"
REQUEST_LOG="${LOG_DIR}/requests.jsonl"
SUMMARY="${LOG_DIR}/summary.tsv"
: > "${REQUEST_LOG}"
printf 'context\tinput_tokens\tcompletion_tokens\tprefill_seconds\tprefill_tok_s\tdecode_seconds\tdecode_tok_s\tretention_pct\tmtp_acceptance_pct\tmtp_rounds\tresponse_file\n' > "${SUMMARY}"

server_args=(
  "${MODEL}"
  --host "${HOST}"
  --port "${PORT}"
  --model-id "${MODEL_ID}"
  --max-context "${MAX_CONTEXT}"
  --kv-capacity "${MAX_CONTEXT}"
  --max-concurrency 1
  --prefill-chunk "${PREFILL_CHUNK}"
  --kv-dtype "${KV_DTYPE}"
  --device "${DEVICE}"
  --default-max-tokens "${OUTPUT_TOKENS}"
  --greedy
  --no-thinking
  --no-prefix-reuse
  --log-stats-interval-ms 0
  --request-log-jsonl "${REQUEST_LOG}"
)
if (( MTP_DRAFT > 0 )); then
  server_args+=(--spec mtp --draft-tokens "${MTP_DRAFT}" --lm-head-draft)
fi

"${SERVE_BIN}" "${server_args[@]}" >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!
cleanup() {
  if kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

python3 - "${HOST}" "${PORT}" "${SERVER_PID}" "${SERVER_LOG}" <<'PY'
import os
import sys
import time
import urllib.error
import urllib.request

host, port, pid, log_path = sys.argv[1:]
url = f"http://{host}:{port}/health"
for _ in range(1800):
    try:
        with urllib.request.urlopen(url, timeout=1.0) as response:
            if response.status == 200:
                raise SystemExit(0)
    except (urllib.error.URLError, TimeoutError):
        pass
    try:
        os.kill(int(pid), 0)
    except OSError:
        print("ninfer-serve exited before becoming healthy", file=sys.stderr)
        try:
            print(open(log_path, "r", encoding="utf-8", errors="replace").read()[-8000:], file=sys.stderr)
        except OSError:
            pass
        raise SystemExit(1)
    time.sleep(1.0)
print("timed out waiting for ninfer-serve /health", file=sys.stderr)
raise SystemExit(1)
PY

python3 - "${HOST}" "${PORT}" "${MODEL_ID}" "${MAX_CONTEXT}" "${OUTPUT_TOKENS}" \
  "${MIN_COMPLETION_TOKENS}" "${RESERVE_TOKENS}" "${SPEED_CONTEXTS}" "${REQUEST_LOG}" \
  "${SUMMARY}" "${LOG_DIR}" "${MIN_RETENTION_PCT}" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

(
    host,
    port,
    model_id,
    max_context_s,
    output_tokens_s,
    min_completion_s,
    reserve_s,
    contexts_s,
    request_log,
    summary_path,
    log_dir,
    min_retention_s,
) = sys.argv[1:]
max_context = int(max_context_s)
output_tokens = int(output_tokens_s)
min_completion = int(min_completion_s)
reserve = int(reserve_s)
min_retention = float(min_retention_s)
contexts = [int(x) for x in contexts_s.split() if int(x) <= max_context]
base = f"http://{host}:{port}"

if not contexts:
    raise SystemExit("no SPEED_CONTEXTS entry is <= MAX_CONTEXT")
contexts = sorted(dict.fromkeys(contexts))

FILLER = " pebble"
INTRO = (
    "This is a deterministic inference-throughput fixture. Ignore the repeated filler word. "
    "Keep reading until the final instruction.\n\n"
)
TASK = (
    "\n\nNow write a complete C++20 implementation of a bounded lock-free MPMC ring buffer. "
    "Include the class, storage layout, enqueue/dequeue operations, memory-ordering details as "
    "code comments, and enough implementation detail to continue for at least 256 output tokens."
)


def post(path, payload, timeout=7200):
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        base + path,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {path}: {body}") from exc


def make_prompt(repetitions):
    return INTRO + FILLER * repetitions + TASK


def count_tokens(prompt):
    response = post(
        "/v1/messages/count_tokens",
        {
            "model": model_id,
            "max_tokens": output_tokens,
            "messages": [{"role": "user", "content": prompt}],
        },
        timeout=300,
    )
    value = response.get("input_tokens")
    if not isinstance(value, int) or value <= 0:
        raise RuntimeError(f"invalid count_tokens response: {response!r}")
    return value


def calibrate(target):
    lo, hi = 0, max(1, target)
    while count_tokens(make_prompt(hi)) < target:
        lo = hi
        hi *= 2
        if hi > max_context * 4:
            raise RuntimeError("could not bracket requested token depth")
    best_rep = lo
    best_tokens = count_tokens(make_prompt(lo))
    while lo <= hi:
        mid = (lo + hi) // 2
        tokens = count_tokens(make_prompt(mid))
        if tokens <= target:
            best_rep, best_tokens = mid, tokens
            lo = mid + 1
        else:
            hi = mid - 1
    return best_rep, best_tokens


def done_records():
    records = []
    try:
        with open(request_log, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("event") == "request_done":
                    records.append(record)
    except FileNotFoundError:
        pass
    return records


def wait_for_new_done(previous_count, timeout=30.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        records = done_records()
        if len(records) > previous_count:
            return records[previous_count]
        time.sleep(0.05)
    raise RuntimeError("request completed but request_done JSONL record did not appear")

baseline_decode = None
failures = 0
with open(summary_path, "a", encoding="utf-8") as summary:
    for context in contexts:
        target = context - reserve
        if target <= 0:
            raise RuntimeError(f"RESERVE_TOKENS leaves no prompt budget at context {context}")
        repetitions, observed = calibrate(target)
        prompt = make_prompt(repetitions)
        observed = count_tokens(prompt)
        if observed > target:
            raise RuntimeError(f"calibration exceeded target at context {context}: {observed}>{target}")

        previous_done = len(done_records())
        response = post(
            "/v1/messages",
            {
                "model": model_id,
                "max_tokens": output_tokens,
                "messages": [{"role": "user", "content": prompt}],
            },
        )
        record = wait_for_new_done(previous_done)
        result = record.get("result", {})
        timings = record.get("timings_seconds", {})
        speculative = record.get("speculative", {})

        input_tokens = result.get("prompt_tokens")
        completion_tokens = result.get("completion_tokens")
        computed_prefill = result.get("computed_prefill_tokens")
        prefill_seconds = timings.get("prefill")
        decode_seconds = timings.get("decode")
        if not isinstance(input_tokens, int) or input_tokens <= 0:
            raise RuntimeError(f"invalid prompt token count in request log: {record!r}")
        if not isinstance(completion_tokens, int) or completion_tokens < 1:
            raise RuntimeError(f"invalid completion token count in request log: {record!r}")
        if completion_tokens < min_completion:
            failures += 1
        if not isinstance(computed_prefill, int) or computed_prefill < 0:
            raise RuntimeError(f"invalid computed prefill token count: {record!r}")
        if not isinstance(prefill_seconds, (int, float)) or prefill_seconds <= 0:
            raise RuntimeError(f"invalid prefill timing: {record!r}")

        decode_tokens = max(0, completion_tokens - 1)
        if decode_tokens == 0 or not isinstance(decode_seconds, (int, float)) or decode_seconds <= 0:
            raise RuntimeError(f"insufficient decode timing data: {record!r}")
        prefill_rate = computed_prefill / float(prefill_seconds)
        decode_rate = decode_tokens / float(decode_seconds)
        if baseline_decode is None:
            baseline_decode = decode_rate
        retention = 100.0 * decode_rate / baseline_decode

        drafted = speculative.get("drafted_tokens", 0)
        accepted = speculative.get("accepted_tokens", 0)
        rounds = speculative.get("rounds", 0)
        if not isinstance(drafted, int) or drafted < 0 or not isinstance(accepted, int) or accepted < 0:
            raise RuntimeError(f"invalid speculative metrics: {record!r}")
        acceptance = 100.0 * accepted / drafted if drafted else 0.0

        if min_retention > 0.0 and retention + 1e-9 < min_retention:
            failures += 1

        stem = f"ctx{context}"
        response_file = os.path.join(log_dir, stem + ".json")
        with open(response_file, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "requested_context": context,
                    "target_prompt_tokens": target,
                    "calibrated_input_tokens": observed,
                    "response": response,
                    "request_done": record,
                    "derived": {
                        "prefill_tok_s": prefill_rate,
                        "decode_tok_s": decode_rate,
                        "retention_pct": retention,
                        "mtp_acceptance_pct": acceptance,
                    },
                },
                handle,
                ensure_ascii=False,
                indent=2,
            )

        summary.write(
            f"{context}\t{input_tokens}\t{completion_tokens}\t{float(prefill_seconds):.6f}\t"
            f"{prefill_rate:.3f}\t{float(decode_seconds):.6f}\t{decode_rate:.3f}\t"
            f"{retention:.3f}\t{acceptance:.3f}\t{int(rounds or 0)}\t{response_file}\n"
        )
        summary.flush()
        status = "PASS"
        if completion_tokens < min_completion:
            status = "FAIL-short-completion"
        elif min_retention > 0.0 and retention < min_retention:
            status = "FAIL-retention"
        print(
            f"context={context} input={input_tokens} completion={completion_tokens} "
            f"prefill={prefill_rate:.1f} tok/s decode={decode_rate:.2f} tok/s "
            f"retention={retention:.1f}% mtp_acceptance={acceptance:.1f}% status={status}"
        )

if failures:
    raise SystemExit(f"{failures} speed-curve acceptance case(s) failed; see {summary_path}")
PY

echo
echo "Long-context speed results: ${SUMMARY}"
column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
echo "Decode tok/s uses NInfer engine decode_seconds and excludes the first token emitted by prefill."
if [[ "${MIN_RETENTION_PCT}" == "0" || "${MIN_RETENTION_PCT}" == "0.0" ]]; then
  echo "Retention is report-only. Set MIN_RETENTION_PCT after the physical-card curve is qualified."
else
  echo "Retention gate: every measured context must retain at least ${MIN_RETENTION_PCT}% of the first successful context."
fi
