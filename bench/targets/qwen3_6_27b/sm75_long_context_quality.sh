#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Token-calibrated long-context retrieval / needle-in-a-haystack probe for
# RTX 2080 Ti 22GB + Qwen3.8-27B.
#
# The server is loaded once. /v1/messages/count_tokens is then used to binary-search the filler
# length for each requested context, so a PASS is tied to an observed prompt-token depth rather
# than an estimate from bytes/words. Three default needle depths exercise early, middle and late
# retrieval. This is a quality gate, not a capacity proof; run sm75_rk4v4e8_probe.sh first.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_long_context_quality.sh MODEL.ninfer [NINFER_SERVE_BIN]
#
# Environment:
#   DEVICE=0
#   MAX_CONTEXT=65536             # raise only after explicit capacity probe passes
#   QUALITY_CONTEXTS="32768 65536 131072 196608 262144"
#   DEPTHS="0.10 0.50 0.90"
#   OUTPUT_RESERVE=128            # tokens reserved below each context ceiling
#   PREFILL_CHUNK=1024
#   KV_DTYPE=rk4v4-e8             # int8 is useful as a quality control
#   MTP_DRAFT=3                   # 0 disables speculative decoding
#   PORT=18080
#   LOG_DIR=sm75-long-context-quality

MODEL=${1:-}
SERVE_BIN=${2:-./build/apps/ninfer-serve}
DEVICE=${DEVICE:-0}
MAX_CONTEXT=${MAX_CONTEXT:-65536}
QUALITY_CONTEXTS=${QUALITY_CONTEXTS:-"32768 65536 131072 196608 262144"}
DEPTHS=${DEPTHS:-"0.10 0.50 0.90"}
OUTPUT_RESERVE=${OUTPUT_RESERVE:-128}
PREFILL_CHUNK=${PREFILL_CHUNK:-1024}
KV_DTYPE=${KV_DTYPE:-rk4v4-e8}
MTP_DRAFT=${MTP_DRAFT:-3}
PORT=${PORT:-18080}
LOG_DIR=${LOG_DIR:-sm75-long-context-quality}
MODEL_ID=sm75-qwen3.8-27b-quality
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
[[ "${OUTPUT_RESERVE}" =~ ^[0-9]+$ ]] && (( OUTPUT_RESERVE >= 32 )) || \
  fail "OUTPUT_RESERVE must be at least 32"
[[ "${PREFILL_CHUNK}" =~ ^[0-9]+$ ]] && (( PREFILL_CHUNK > 0 && PREFILL_CHUNK % 128 == 0 )) || \
  fail "PREFILL_CHUNK must be a positive multiple of 128"
[[ "${MTP_DRAFT}" =~ ^[0-9]+$ ]] && (( MTP_DRAFT <= 5 )) || \
  fail "MTP_DRAFT must be in [0,5]"
[[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT <= 65535 )) || fail "invalid PORT"
[[ "${KV_DTYPE}" == "int8" || "${KV_DTYPE}" == "rk4v4-e8" ]] || \
  fail "KV_DTYPE must be int8 or rk4v4-e8"

for context in ${QUALITY_CONTEXTS}; do
  [[ "${context}" =~ ^[0-9]+$ ]] && (( context >= 4096 && context <= 262144 )) || \
    fail "invalid QUALITY_CONTEXTS entry: ${context}"
done
for depth in ${DEPTHS}; do
  python3 - "${depth}" <<'PY' || fail "DEPTHS entries must be floating-point values strictly between 0 and 1"
import sys
try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if 0.0 < value < 1.0 else 1)
PY
done

mkdir -p "${LOG_DIR}"
SERVER_LOG="${LOG_DIR}/server.log"
SUMMARY="${LOG_DIR}/summary.tsv"
printf 'context\tdepth\tinput_tokens\ttarget_tokens\tresult\tneedle\tresponse_file\n' > "${SUMMARY}"

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
  --default-max-tokens 32
  --greedy
  --no-thinking
  --no-prefix-reuse
  --log-stats-interval-ms 0
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

python3 - "${HOST}" "${PORT}" "${MODEL_ID}" "${MAX_CONTEXT}" "${OUTPUT_RESERVE}" \
  "${QUALITY_CONTEXTS}" "${DEPTHS}" "${SUMMARY}" "${LOG_DIR}" <<'PY'
import json
import math
import os
import re
import sys
import urllib.error
import urllib.request

host, port, model_id, max_context_s, reserve_s, contexts_s, depths_s, summary_path, log_dir = sys.argv[1:]
max_context = int(max_context_s)
reserve = int(reserve_s)
contexts = [int(x) for x in contexts_s.split() if int(x) <= max_context]
depths = [float(x) for x in depths_s.split()]
base = f"http://{host}:{port}"

if not contexts:
    raise SystemExit("no QUALITY_CONTEXTS entry is <= MAX_CONTEXT")

FILLER = " pebble"
INTRO = (
    "This is a deterministic long-context retrieval test. Ignore every occurrence of the filler "
    "word pebble. Memorize the single retrieval needle below. At the final question, answer with "
    "only the secret code and no punctuation or explanation.\n\n"
)
QUESTION = "\n\nQuestion: What is the secret code? Output the code only."


def post(path, payload, timeout=3600):
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


def make_prompt(repetitions, depth, needle):
    before = int(round(repetitions * depth))
    before = min(max(before, 0), repetitions)
    after = repetitions - before
    marker = f"\n\nRETRIEVAL NEEDLE: The secret code is {needle}.\n\n"
    return INTRO + FILLER * before + marker + FILLER * after + QUESTION


def count_tokens(prompt):
    body = {
        "model": model_id,
        "max_tokens": 32,
        "messages": [{"role": "user", "content": prompt}],
    }
    response = post("/v1/messages/count_tokens", body, timeout=300)
    value = response.get("input_tokens")
    if not isinstance(value, int) or value <= 0:
        raise RuntimeError(f"invalid count_tokens response: {response!r}")
    return value


def calibrate(target, needle):
    # The repeated filler is deliberately one short lexical unit. Count-tokens, not this assumption,
    # is authoritative; binary search returns the largest prompt that does not exceed the target.
    lo, hi = 0, max(1, target)
    while True:
        tokens = count_tokens(make_prompt(hi, 0.5, needle))
        if tokens >= target:
            break
        lo = hi
        hi *= 2
        if hi > max_context * 4:
            raise RuntimeError("could not bracket requested token depth")
    best_rep, best_tokens = lo, count_tokens(make_prompt(lo, 0.5, needle))
    while lo <= hi:
        mid = (lo + hi) // 2
        tokens = count_tokens(make_prompt(mid, 0.5, needle))
        if tokens <= target:
            best_rep, best_tokens = mid, tokens
            lo = mid + 1
        else:
            hi = mid - 1
    return best_rep, best_tokens


def extract_text(response):
    parts = response.get("content", [])
    if not isinstance(parts, list):
        return ""
    return "".join(
        part.get("text", "")
        for part in parts
        if isinstance(part, dict) and part.get("type") == "text"
    ).strip()

failures = 0
with open(summary_path, "a", encoding="utf-8") as summary:
    for context in contexts:
        target = context - reserve
        if target <= 0:
            raise RuntimeError(f"OUTPUT_RESERVE leaves no prompt budget at context {context}")
        calibration_needle = f"SM75CAL{context}X"
        repetitions, _ = calibrate(target, calibration_needle)
        for depth in depths:
            depth_pct = int(round(depth * 100))
            needle = f"SM75K{context}D{depth_pct}Z9Q7"
            prompt = make_prompt(repetitions, depth, needle)
            observed = count_tokens(prompt)
            if observed > target:
                # A boundary merge around the moved needle can shift tokenization by a token or two.
                # Trim filler until this exact depth is safely below the generation ceiling.
                while observed > target and repetitions > 0:
                    repetitions -= 1
                    prompt = make_prompt(repetitions, depth, needle)
                    observed = count_tokens(prompt)
            body = {
                "model": model_id,
                "max_tokens": 16,
                "messages": [{"role": "user", "content": prompt}],
            }
            response = post("/v1/messages", body)
            text = extract_text(response)
            normalized = re.sub(r"[^A-Za-z0-9]", "", text).upper()
            expected = re.sub(r"[^A-Za-z0-9]", "", needle).upper()
            passed = normalized == expected
            result = "PASS" if passed else "FAIL"
            if not passed:
                failures += 1
            stem = f"ctx{context}-depth{depth_pct}"
            response_file = os.path.join(log_dir, stem + ".json")
            with open(response_file, "w", encoding="utf-8") as handle:
                json.dump(
                    {
                        "context": context,
                        "depth": depth,
                        "target_tokens": target,
                        "input_tokens": observed,
                        "needle": needle,
                        "response_text": text,
                        "response": response,
                    },
                    handle,
                    ensure_ascii=False,
                    indent=2,
                )
            summary.write(
                f"{context}\t{depth:.2f}\t{observed}\t{target}\t{result}\t{needle}\t{response_file}\n"
            )
            summary.flush()
            print(
                f"context={context} depth={depth:.2f} input_tokens={observed} "
                f"target={target} result={result} response={text!r}"
            )

if failures:
    raise SystemExit(f"{failures} long-context retrieval case(s) failed; see {summary_path}")
PY

echo
echo "Long-context quality results: ${SUMMARY}"
column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
echo "A PASS is an exact-code retrieval result at the measured input-token depth."
echo "If MTP fails but capacity fits, rerun with MTP_DRAFT=0 before attributing the failure to RK4V4E8."
