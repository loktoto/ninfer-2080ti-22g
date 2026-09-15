#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# RTX 2080 Ti 22GB / Qwen3.8-27B profile autotuner.
#
# Prefer ninfer_bench when available: it loads the artifact once per profile and performs warmup +
# measured repetitions inside one Engine. This avoids repeatedly loading a ~19 GiB container for
# every repetition. A CLI fallback is retained for minimal builds without benchmarks.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_autotune.sh MODEL.ninfer [NINFER_BIN]
#
# Environment overrides:
#   DEVICE=0
#   MAX_CONTEXT=65536
#   MAX_NEW=256
#   BENCH_PROMPT=2048
#   PREFILL_CHUNKS="512 1024"
#   KV_MODES="int8 rk4v4-e8"
#   DRAFTS="0 2 3 4 5"
#   WARMUP=1
#   REPS=3
#   BENCH_BIN=./build/bench/ninfer_bench
#   LOG_DIR=sm75-autotune
#
# Build the preferred benchmark path with:
#   cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
#     -DCMAKE_CUDA_ARCHITECTURES=75 -DNINFER_BUILD_BENCHMARKS=ON
#   cmake --build build --parallel --target ninfer_bench ninfer
#
# Use sm75_rk4v4e8_probe.sh separately for the 64K/128K/192K/256K capacity ladder.

MODEL=${1:-}
BIN=${2:-./build/apps/ninfer}
BENCH_BIN=${BENCH_BIN:-./build/bench/ninfer_bench}
DEVICE=${DEVICE:-0}
MAX_CONTEXT=${MAX_CONTEXT:-65536}
MAX_NEW=${MAX_NEW:-256}
BENCH_PROMPT=${BENCH_PROMPT:-2048}
PREFILL_CHUNKS=${PREFILL_CHUNKS:-"512 1024"}
KV_MODES=${KV_MODES:-"int8 rk4v4-e8"}
DRAFTS=${DRAFTS:-"0 2 3 4 5"}
WARMUP=${WARMUP:-1}
REPS=${REPS:-3}
LOG_DIR=${LOG_DIR:-sm75-autotune}
CORPUS=${CORPUS:-bench/fixtures/bench_corpus.ids}

fail() {
  echo "error: $*" >&2
  exit 2
}

[[ -n "${MODEL}" ]] || fail "usage: $0 MODEL.ninfer [NINFER_BIN]"
[[ -f "${MODEL}" ]] || fail "model not found: ${MODEL}"
[[ "${DEVICE}" =~ ^[0-9]+$ ]] || fail "DEVICE must be a non-negative integer"
[[ "${MAX_CONTEXT}" =~ ^[0-9]+$ ]] && (( MAX_CONTEXT > 0 )) || fail "MAX_CONTEXT must be positive"
[[ "${MAX_NEW}" =~ ^[0-9]+$ ]] && (( MAX_NEW >= 32 )) || fail "MAX_NEW must be at least 32"
[[ "${BENCH_PROMPT}" =~ ^[0-9]+$ ]] && (( BENCH_PROMPT > 0 )) || fail "BENCH_PROMPT must be positive"
[[ "${WARMUP}" =~ ^[0-9]+$ ]] || fail "WARMUP must be non-negative"
[[ "${REPS}" =~ ^[0-9]+$ ]] && (( REPS > 0 )) || fail "REPS must be positive"

for chunk in ${PREFILL_CHUNKS}; do
  [[ "${chunk}" =~ ^[0-9]+$ ]] && (( chunk > 0 && chunk % 128 == 0 )) || \
    fail "invalid PREFILL_CHUNKS entry: ${chunk}; expected positive multiples of 128"
done
for kv in ${KV_MODES}; do
  [[ "${kv}" == "int8" || "${kv}" == "rk4v4-e8" ]] || \
    fail "invalid KV_MODES entry: ${kv}"
done
for draft in ${DRAFTS}; do
  [[ "${draft}" =~ ^[0-9]+$ ]] && (( draft >= 0 && draft <= 5 )) || \
    fail "invalid DRAFTS entry: ${draft}; expected 0..5"
done

USE_BENCH=0
if [[ -x "${BENCH_BIN}" ]]; then
  [[ -f "${CORPUS}" ]] || fail "benchmark corpus not found: ${CORPUS}"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse ninfer_bench JSON"
  USE_BENCH=1
else
  [[ -x "${BIN}" ]] || \
    fail "neither benchmark (${BENCH_BIN}) nor CLI (${BIN}) is executable"
fi

mkdir -p "${LOG_DIR}"
SUMMARY="${LOG_DIR}/summary.tsv"
RAW="${LOG_DIR}/raw.tsv"
printf 'kv\tprefill_chunk\tdraft\tstatus\tdecode_mean_tok_s\tdecode_stddev_tok_s\tacceptance_pct\tmode\treport\n' > "${SUMMARY}"
printf 'kv\tprefill_chunk\tdraft\trep\tdecode_tok_s\tacceptance_pct\tlog\n' > "${RAW}"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -i "${DEVICE}" \
    --query-gpu=index,name,driver_version,memory.total,power.limit \
    --format=csv,noheader > "${LOG_DIR}/gpu.txt" 2>&1 || true
fi

PROMPT='Implement a bounded lock-free ring buffer in C++20 and explain the memory ordering choices.'

snapshot_gpu() {
  local file=$1
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -i "${DEVICE}" \
      --query-gpu=timestamp,clocks.sm,clocks.mem,power.draw,temperature.gpu,memory.used,memory.total \
      --format=csv,noheader >> "${file}" 2>&1 || true
  fi
}

run_bench_profile() {
  local kv=$1
  local chunk=$2
  local draft=$3
  local prefix="${kv}-p${chunk}-d${draft}"
  local report="${LOG_DIR}/${prefix}.json"
  local stderr="${LOG_DIR}/${prefix}.bench.log"
  local gpu="${LOG_DIR}/${prefix}.gpu.csv"
  local -a spec=()
  if (( draft > 0 )); then
    spec=(--mtp-draft-tokens "${draft}" --lm-head-draft)
  fi

  : > "${gpu}"
  snapshot_gpu "${gpu}"
  set +e
  "${BENCH_BIN}" \
    --weights "${MODEL}" \
    --corpus "${CORPUS}" \
    -pg "${BENCH_PROMPT},${MAX_NEW}" \
    -r "${REPS}" \
    --warmup "${WARMUP}" \
    --max-ctx "${MAX_CONTEXT}" \
    --prefill-chunk "${chunk}" \
    --kv-dtype "${kv}" \
    --device "${DEVICE}" \
    --output json \
    --output-file "${report}" \
    "${spec[@]}" >"${LOG_DIR}/${prefix}.bench.stdout" 2>"${stderr}"
  local rc=$?
  set -e
  snapshot_gpu "${gpu}"
  if (( rc != 0 )); then
    echo "profile failed: kv=${kv} chunk=${chunk} draft=${draft}; see ${stderr}" >&2
    tail -n 30 "${stderr}" >&2 || true
    printf '%s\t%s\t%s\tFAIL\t-\t-\t-\tbench\t%s\n' \
      "${kv}" "${chunk}" "${draft}" "${report}" >> "${SUMMARY}"
    return 0
  fi

  python3 - "${report}" "${kv}" "${chunk}" "${draft}" >> "${SUMMARY}" <<'PY'
import json
import sys

path, kv, chunk, draft = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    report = json.load(handle)

tests = report.get("tests", [])
if len(tests) != 1:
    raise SystemExit(f"expected one benchmark test in {path}, got {len(tests)}")
test = tests[0]
mean = test.get("decode_output_tok_s_mean")
stddev = test.get("decode_output_tok_s_stddev")
spec = test.get("speculative", {})
acceptance = spec.get("acceptance_rate")
if mean is None:
    raise SystemExit(f"missing decode throughput in {path}")
if stddev is None:
    stddev = 0.0
if acceptance is None:
    acceptance = 0.0
print(f"{kv}\t{chunk}\t{draft}\tPASS\t{float(mean):.3f}\t{float(stddev):.3f}\t{100.0*float(acceptance):.3f}\tbench\t{path}")
PY
}

parse_decode_rate() {
  local file=$1
  sed -nE 's/.*decode speed[[:space:]]+([0-9]+([.][0-9]+)?) tok\/s.*/\1/p' "${file}" | tail -n 1
}

parse_acceptance() {
  local file=$1
  sed -nE 's/.*mtp acceptance rate[[:space:]]+([0-9]+([.][0-9]+)?)%.*/\1/p' "${file}" | tail -n 1
}

run_cli_once() {
  local kv=$1
  local chunk=$2
  local draft=$3
  local label=$4
  local log="${LOG_DIR}/${label}.log"
  local gpu="${LOG_DIR}/${label}.gpu.csv"
  local -a spec=()
  if (( draft > 0 )); then
    spec=(--spec mtp --draft-tokens "${draft}" --lm-head-draft)
  fi

  : > "${gpu}"
  snapshot_gpu "${gpu}"
  set +e
  "${BIN}" "${MODEL}" \
    --prompt "${PROMPT}" \
    --max-context "${MAX_CONTEXT}" \
    --kv-capacity auto \
    --prefill-chunk "${chunk}" \
    --kv-dtype "${kv}" \
    --device "${DEVICE}" \
    --max-new "${MAX_NEW}" \
    --greedy \
    --no-thinking \
    --raw-output \
    "${spec[@]}" >"${log}.stdout" 2>"${log}"
  local rc=$?
  set -e
  snapshot_gpu "${gpu}"
  if (( rc != 0 )); then
    tail -n 25 "${log}" >&2 || true
    return "${rc}"
  fi
  local decode acceptance
  decode=$(parse_decode_rate "${log}")
  [[ -n "${decode}" ]] || return 90
  acceptance=0
  if (( draft > 0 )); then
    acceptance=$(parse_acceptance "${log}")
    [[ -n "${acceptance}" ]] || acceptance=0
  fi
  printf '%s\t%s\n' "${decode}" "${acceptance}"
}

run_cli_profile() {
  local kv=$1
  local chunk=$2
  local draft=$3
  local prefix="${kv}-p${chunk}-d${draft}"
  local warm rep values="" accepts=""

  for ((warm = 1; warm <= WARMUP; ++warm)); do
    run_cli_once "${kv}" "${chunk}" "${draft}" "${prefix}-warm${warm}" >/dev/null || {
      printf '%s\t%s\t%s\tFAIL\t-\t-\t-\tcli\t%s\n' \
        "${kv}" "${chunk}" "${draft}" "${prefix}" >> "${SUMMARY}"
      return 0
    }
  done

  for ((rep = 1; rep <= REPS; ++rep)); do
    local result decode acceptance
    result=$(run_cli_once "${kv}" "${chunk}" "${draft}" "${prefix}-rep${rep}") || {
      printf '%s\t%s\t%s\tFAIL\t-\t-\t-\tcli\t%s\n' \
        "${kv}" "${chunk}" "${draft}" "${prefix}" >> "${SUMMARY}"
      return 0
    }
    decode=${result%%$'\t'*}
    acceptance=${result#*$'\t'}
    values+=" ${decode}"
    accepts+=" ${acceptance}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${kv}" "${chunk}" "${draft}" "${rep}" "${decode}" "${acceptance}" \
      "${LOG_DIR}/${prefix}-rep${rep}.log" >> "${RAW}"
  done

  awk -v kv="${kv}" -v chunk="${chunk}" -v draft="${draft}" -v prefix="${prefix}" \
      -v vals="${values}" -v accs="${accepts}" 'BEGIN {
        n = split(vals, v, " "); count = 0; sum = 0; sum2 = 0;
        for (i = 1; i <= n; ++i) if (v[i] != "") {
          x = v[i] + 0; sum += x; sum2 += x*x; ++count;
        }
        an = split(accs, a, " "); asum = 0; acount = 0;
        for (i = 1; i <= an; ++i) if (a[i] != "") { asum += a[i] + 0; ++acount; }
        if (count == 0) exit 1;
        mean = sum / count;
        variance = count > 1 ? (sum2 - count*mean*mean)/(count-1) : 0;
        if (variance < 0) variance = 0;
        printf "%s\t%s\t%s\tPASS\t%.3f\t%.3f\t%.3f\tcli\t%s\n",
               kv, chunk, draft, mean, sqrt(variance), acount ? asum/acount : 0, prefix;
      }' >> "${SUMMARY}"
}

if (( USE_BENCH )); then
  echo "Using one-load-per-profile benchmark: ${BENCH_BIN}"
else
  echo "ninfer_bench not found; using slower CLI fallback: ${BIN}" >&2
fi

for kv in ${KV_MODES}; do
  for chunk in ${PREFILL_CHUNKS}; do
    for draft in ${DRAFTS}; do
      echo "== kv=${kv} prefill_chunk=${chunk} draft=${draft} =="
      if (( USE_BENCH )); then
        run_bench_profile "${kv}" "${chunk}" "${draft}"
      else
        run_cli_profile "${kv}" "${chunk}" "${draft}"
      fi
    done
  done
done

BEST=$(awk -F '\t' 'NR > 1 && $4 == "PASS" { if (!seen || $5 + 0 > best) { seen=1; best=$5+0; line=$0 } } END { print line }' "${SUMMARY}")

echo
echo "Autotune results: ${SUMMARY}"
column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
if [[ -n "${BEST}" ]]; then
  IFS=$'\t' read -r best_kv best_chunk best_draft _ best_rate best_std best_accept best_mode best_report <<< "${BEST}"
  echo
  echo "Fastest measured decode profile on this card:"
  echo "  kv=${best_kv} prefill_chunk=${best_chunk} draft=${best_draft} mean=${best_rate} tok/s stddev=${best_std} acceptance=${best_accept}%"
  echo "  measurement=${best_mode} report=${best_report}"
  if (( best_draft > 0 )); then
    echo "  runtime flags: --kv-dtype ${best_kv} --prefill-chunk ${best_chunk} --spec mtp --draft-tokens ${best_draft} --lm-head-draft"
  else
    echo "  runtime flags: --kv-dtype ${best_kv} --prefill-chunk ${best_chunk}"
  fi
else
  echo "No profile completed successfully." >&2
  exit 1
fi

echo
echo "Use sm75_rk4v4e8_probe.sh separately before claiming any 128K/192K/256K capacity ceiling."
