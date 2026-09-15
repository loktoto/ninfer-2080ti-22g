#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# RTX 2080 Ti 22GB / Qwen3.8-27B profile autotuner.
#
# Prefer ninfer_bench when available: it loads the artifact once per profile and performs warmup +
# measured repetitions inside one Engine. This avoids repeatedly loading a ~19 GiB container for
# every repetition. A CLI fallback is retained for minimal builds without benchmarks. Both paths
# reserve MAX_CONTEXT explicitly so KV-mode comparisons use the same requested memory footprint.
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
printf 'kv\tprefill_chunk\tdraft\tstatus\tprefill_mean_tok_s\tdecode_mean_tok_s\tdecode_stddev_tok_s\tacceptance_pct\tmode\treport\n' > "${SUMMARY}"
printf 'kv\tprefill_chunk\tdraft\trep\tprefill_tok_s\tdecode_tok_s\tacceptance_pct\tlog\n' > "${RAW}"

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
    printf '%s\t%s\t%s\tFAIL\t-\t-\t-\t-\tbench\t%s\n' \
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
prefill = test.get("prefill_prompt_tok_s_mean")
decode = test.get("decode_output_tok_s_mean")
stddev = test.get("decode_output_tok_s_stddev")
spec = test.get("speculative", {})
acceptance = spec.get("acceptance_rate")
if prefill is None:
    raise SystemExit(f"missing prefill throughput in {path}")
if decode is None:
    raise SystemExit(f"missing decode throughput in {path}")
if stddev is None:
    stddev = 0.0
if acceptance is None:
    acceptance = 0.0
print(
    f"{kv}\t{chunk}\t{draft}\tPASS\t{float(prefill):.3f}\t{float(decode):.3f}\t"
    f"{float(stddev):.3f}\t{100.0*float(acceptance):.3f}\tbench\t{path}"
)
PY
}

parse_prefill_rate() {
  local file=$1
  sed -nE 's/.*prefill speed[[:space:]]+([0-9]+([.][0-9]+)?) tok\/s.*/\1/p' "${file}" | tail -n 1
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
    --kv-capacity "${MAX_CONTEXT}" \
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

  local prefill decode acceptance
  prefill=$(parse_prefill_rate "${log}")
  decode=$(parse_decode_rate "${log}")
  [[ -n "${prefill}" ]] || return 89
  [[ -n "${decode}" ]] || return 90
  acceptance=0
  if (( draft > 0 )); then
    acceptance=$(parse_acceptance "${log}")
    [[ -n "${acceptance}" ]] || acceptance=0
  fi
  printf '%s\t%s\t%s\n' "${prefill}" "${decode}" "${acceptance}"
}

run_cli_profile() {
  local kv=$1
  local chunk=$2
  local draft=$3
  local prefix="${kv}-p${chunk}-d${draft}"
  local warm rep prefills="" decodes="" accepts=""

  for ((warm = 1; warm <= WARMUP; ++warm)); do
    run_cli_once "${kv}" "${chunk}" "${draft}" "${prefix}-warm${warm}" >/dev/null || {
      printf '%s\t%s\t%s\tFAIL\t-\t-\t-\t-\tcli\t%s\n' \
        "${kv}" "${chunk}" "${draft}" "${prefix}" >> "${SUMMARY}"
      return 0
    }
  done

  for ((rep = 1; rep <= REPS; ++rep)); do
    local result prefill decode acceptance
    result=$(run_cli_once "${kv}" "${chunk}" "${draft}" "${prefix}-rep${rep}") || {
      printf '%s\t%s\t%s\tFAIL\t-\t-\t-\t-\tcli\t%s\n' \
        "${kv}" "${chunk}" "${draft}" "${prefix}" >> "${SUMMARY}"
      return 0
    }
    IFS=$'\t' read -r prefill decode acceptance <<< "${result}"
    prefills+=" ${prefill}"
    decodes+=" ${decode}"
    accepts+=" ${acceptance}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${kv}" "${chunk}" "${draft}" "${rep}" "${prefill}" "${decode}" "${acceptance}" \
      "${LOG_DIR}/${prefix}-rep${rep}.log" >> "${RAW}"
  done

  awk -v kv="${kv}" -v chunk="${chunk}" -v draft="${draft}" -v prefix="${prefix}" \
      -v pvals="${prefills}" -v dvals="${decodes}" -v accs="${accepts}" 'BEGIN {
        pn = split(pvals, p, " "); pcount = 0; psum = 0;
        for (i = 1; i <= pn; ++i) if (p[i] != "") { psum += p[i] + 0; ++pcount; }
        dn = split(dvals, d, " "); dcount = 0; dsum = 0; dsum2 = 0;
        for (i = 1; i <= dn; ++i) if (d[i] != "") {
          x = d[i] + 0; dsum += x; dsum2 += x*x; ++dcount;
        }
        an = split(accs, a, " "); asum = 0; acount = 0;
        for (i = 1; i <= an; ++i) if (a[i] != "") { asum += a[i] + 0; ++acount; }
        if (pcount == 0 || dcount == 0) exit 1;
        pmean = psum / pcount;
        dmean = dsum / dcount;
        variance = dcount > 1 ? (dsum2 - dcount*dmean*dmean)/(dcount-1) : 0;
        if (variance < 0) variance = 0;
        printf "%s\t%s\t%s\tPASS\t%.3f\t%.3f\t%.3f\t%.3f\tcli\t%s\n",
               kv, chunk, draft, pmean, dmean, sqrt(variance),
               acount ? asum/acount : 0, prefix;
      }' >> "${SUMMARY}"
}

print_profile() {
  local label=$1
  local row=$2
  local kv chunk draft status prefill decode stddev acceptance mode report
  IFS=$'\t' read -r kv chunk draft status prefill decode stddev acceptance mode report <<< "${row}"
  echo "${label}:"
  echo "  kv=${kv} prefill_chunk=${chunk} draft=${draft} prefill=${prefill} tok/s decode=${decode} tok/s stddev=${stddev} acceptance=${acceptance}%"
  echo "  measurement=${mode} report=${report}"
  if (( draft > 0 )); then
    echo "  runtime flags: --kv-dtype ${kv} --prefill-chunk ${chunk} --spec mtp --draft-tokens ${draft} --lm-head-draft"
  else
    echo "  runtime flags: --kv-dtype ${kv} --prefill-chunk ${chunk}"
  fi
}

if (( USE_BENCH )); then
  echo "Using one-load-per-profile benchmark: ${BENCH_BIN}"
else
  echo "ninfer_bench not found; using slower CLI fallback: ${BIN}" >&2
  echo "CLI fallback uses a short text prompt; use its prefill figures only as diagnostics, not as the balanced-profile selector." >&2
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

BEST_DECODE=$(awk -F '\t' 'NR > 1 && $4 == "PASS" { if (!seen || $6 + 0 > best) { seen=1; best=$6+0; line=$0 } } END { print line }' "${SUMMARY}")
BEST_PREFILL=$(awk -F '\t' 'NR > 1 && $4 == "PASS" { if (!seen || $5 + 0 > best) { seen=1; best=$5+0; line=$0 } } END { print line }' "${SUMMARY}")

if [[ -z "${BEST_DECODE}" ]]; then
  echo "No profile completed successfully." >&2
  exit 1
fi

echo
echo "Autotune results: ${SUMMARY}"
column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
echo
print_profile "Fastest decode profile" "${BEST_DECODE}"
if [[ -n "${BEST_PREFILL}" ]]; then
  echo
  print_profile "Fastest prefill profile" "${BEST_PREFILL}"
fi

if (( USE_BENCH )); then
  MAX_DECODE=$(awk -F '\t' 'NR > 1 && $4 == "PASS" { if (!seen || $6 + 0 > best) { seen=1; best=$6+0 } } END { if (seen) printf "%.9f", best }' "${SUMMARY}")
  BALANCED=$(awk -F '\t' -v max_decode="${MAX_DECODE}" '
    NR > 1 && $4 == "PASS" && ($6 + 0) >= (max_decode * 0.97) {
      p = $5 + 0; d = $6 + 0;
      if (!seen || p > best_p || (p == best_p && d > best_d)) {
        seen=1; best_p=p; best_d=d; line=$0;
      }
    }
    END { print line }
  ' "${SUMMARY}")
  if [[ -n "${BALANCED}" ]]; then
    echo
    print_profile "Balanced daily profile (>=97% of best decode, then max prefill)" "${BALANCED}"
  fi
else
  echo
  echo "Balanced daily profile is intentionally not selected from CLI fallback measurements; build ninfer_bench for a 2048-token prompt comparison."
fi

echo
echo "Use sm75_rk4v4e8_probe.sh separately before claiming any 128K/192K/256K capacity ceiling."
