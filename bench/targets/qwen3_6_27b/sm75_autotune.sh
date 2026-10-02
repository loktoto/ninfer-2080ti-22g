#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# RTX 2080 Ti 22GB / Qwen3.8-27B profile autotuner.
#
# This harness intentionally measures the physical card instead of assuming that
# the best MTP draft window or prefill chunk from Ada/Blackwell also wins on
# Turing. It compares AR and MTP2/3/4 across INT8 and RK4V4E8 while keeping the
# model, prompt, context allocation and sampling policy fixed.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_autotune.sh MODEL.ninfer [NINFER_BIN]
#
# Environment overrides:
#   DEVICE=0
#   MAX_CONTEXT=65536
#   MAX_NEW=256
#   PREFILL_CHUNKS="512 1024"
#   KV_MODES="int8 rk4v4-e8"
#   DRAFTS="0 2 3 4"
#   WARMUP=1
#   REPS=3
#   LOG_DIR=sm75-autotune
#
# Notes:
# - MAX_CONTEXT controls the allocation/runtime profile but this short-prompt
#   sweep is primarily a decode/MTP tuning test. Use sm75_rk4v4e8_probe.sh for
#   actual 64K/128K/192K/256K capacity validation.
# - Draft 0 is ordinary autoregressive decode. Draft >0 enables MTP with the
#   optimized proposal head.

MODEL=${1:-}
BIN=${2:-./build/apps/ninfer}
DEVICE=${DEVICE:-0}
MAX_CONTEXT=${MAX_CONTEXT:-65536}
MAX_NEW=${MAX_NEW:-256}
PREFILL_CHUNKS=${PREFILL_CHUNKS:-"512 1024"}
KV_MODES=${KV_MODES:-"int8 rk4v4-e8"}
DRAFTS=${DRAFTS:-"0 2 3 4"}
WARMUP=${WARMUP:-1}
REPS=${REPS:-3}
LOG_DIR=${LOG_DIR:-sm75-autotune}

fail() {
  echo "error: $*" >&2
  exit 2
}

[[ -n "${MODEL}" ]] || fail "usage: $0 MODEL.ninfer [NINFER_BIN]"
[[ -f "${MODEL}" ]] || fail "model not found: ${MODEL}"
[[ -x "${BIN}" ]] || fail "ninfer binary not executable: ${BIN}"
[[ "${DEVICE}" =~ ^[0-9]+$ ]] || fail "DEVICE must be a non-negative integer"
[[ "${MAX_CONTEXT}" =~ ^[0-9]+$ ]] && (( MAX_CONTEXT > 0 )) || fail "MAX_CONTEXT must be positive"
[[ "${MAX_NEW}" =~ ^[0-9]+$ ]] && (( MAX_NEW >= 32 )) || fail "MAX_NEW must be at least 32"
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

mkdir -p "${LOG_DIR}"
SUMMARY="${LOG_DIR}/summary.tsv"
RAW="${LOG_DIR}/raw.tsv"
printf 'kv\tprefill_chunk\tdraft\tstatus\tdecode_mean_tok_s\tdecode_min_tok_s\tdecode_max_tok_s\tacceptance_mean_pct\tlog_prefix\n' > "${SUMMARY}"
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

parse_decode_rate() {
  local file=$1
  sed -nE 's/.*decode speed[[:space:]]+([0-9]+([.][0-9]+)?) tok\/s.*/\1/p' "${file}" | tail -n 1
}

parse_acceptance() {
  local file=$1
  sed -nE 's/.*mtp acceptance rate[[:space:]]+([0-9]+([.][0-9]+)?)%.*/\1/p' "${file}" | tail -n 1
}

run_once() {
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
    echo "profile failed: kv=${kv} chunk=${chunk} draft=${draft}; see ${log}" >&2
    tail -n 25 "${log}" >&2 || true
    return "${rc}"
  fi

  local decode
  decode=$(parse_decode_rate "${log}")
  [[ -n "${decode}" ]] || {
    echo "could not parse decode speed from ${log}" >&2
    return 90
  }
  local acceptance=0
  if (( draft > 0 )); then
    acceptance=$(parse_acceptance "${log}")
    [[ -n "${acceptance}" ]] || acceptance=0
  fi
  printf '%s\t%s\n' "${decode}" "${acceptance}"
}

profile_stats() {
  local kv=$1
  local chunk=$2
  local draft=$3
  local prefix="${kv}-p${chunk}-d${draft}"
  local warm
  local rep

  for ((warm = 1; warm <= WARMUP; ++warm)); do
    run_once "${kv}" "${chunk}" "${draft}" "${prefix}-warm${warm}" >/dev/null || return 1
  done

  local values=""
  local accepts=""
  for ((rep = 1; rep <= REPS; ++rep)); do
    local result
    result=$(run_once "${kv}" "${chunk}" "${draft}" "${prefix}-rep${rep}") || return 1
    local decode=${result%%$'\t'*}
    local acceptance=${result#*$'\t'}
    values+=" ${decode}"
    accepts+=" ${acceptance}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${kv}" "${chunk}" "${draft}" "${rep}" "${decode}" "${acceptance}" \
      "${LOG_DIR}/${prefix}-rep${rep}.log" >> "${RAW}"
  done

  awk -v kv="${kv}" -v chunk="${chunk}" -v draft="${draft}" -v prefix="${prefix}" \
      -v vals="${values}" -v accs="${accepts}" 'BEGIN {
        n = split(vals, v, " ");
        count = 0; sum = 0; min = 1e30; max = -1;
        for (i = 1; i <= n; ++i) if (v[i] != "") {
          x = v[i] + 0; sum += x; if (x < min) min = x; if (x > max) max = x; ++count;
        }
        an = split(accs, a, " "); asum = 0; acount = 0;
        for (i = 1; i <= an; ++i) if (a[i] != "") { asum += a[i] + 0; ++acount; }
        if (count == 0) exit 1;
        printf "%s\t%s\t%s\tPASS\t%.3f\t%.3f\t%.3f\t%.3f\t%s\n",
               kv, chunk, draft, sum / count, min, max,
               acount ? asum / acount : 0, prefix;
      }' >> "${SUMMARY}"
}

for kv in ${KV_MODES}; do
  for chunk in ${PREFILL_CHUNKS}; do
    for draft in ${DRAFTS}; do
      echo "== kv=${kv} prefill_chunk=${chunk} draft=${draft} =="
      if ! profile_stats "${kv}" "${chunk}" "${draft}"; then
        printf '%s\t%s\t%s\tFAIL\t-\t-\t-\t-\t%s\n' \
          "${kv}" "${chunk}" "${draft}" "${kv}-p${chunk}-d${draft}" >> "${SUMMARY}"
      fi
    done
  done
done

BEST=$(awk -F '\t' 'NR > 1 && $4 == "PASS" { if (!seen || $5 + 0 > best) { seen=1; best=$5+0; line=$0 } } END { print line }' "${SUMMARY}")

echo
echo "Autotune results: ${SUMMARY}"
column -t -s $'\t' "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
if [[ -n "${BEST}" ]]; then
  IFS=$'\t' read -r best_kv best_chunk best_draft _ best_rate _rest <<< "${BEST}"
  echo
  echo "Fastest measured decode profile on this card:"
  echo "  kv=${best_kv} prefill_chunk=${best_chunk} draft=${best_draft} mean=${best_rate} tok/s"
  if (( best_draft > 0 )); then
    echo "  flags: --kv-dtype ${best_kv} --prefill-chunk ${best_chunk} --spec mtp --draft-tokens ${best_draft} --lm-head-draft"
  else
    echo "  flags: --kv-dtype ${best_kv} --prefill-chunk ${best_chunk}"
  fi
else
  echo "No profile completed successfully." >&2
  exit 1
fi

echo
echo "Use sm75_rk4v4e8_probe.sh separately before claiming any 128K/192K/256K capacity ceiling."
