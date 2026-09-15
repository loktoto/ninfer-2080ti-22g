#!/usr/bin/env bash
set -Eeuo pipefail

# RTX 2080 Ti 22GB / Qwen3.8-27B RK4V4E8 capacity and decode smoke probe.
#
# This deliberately distinguishes a successful allocator/runtime fit from a
# performance claim. A context size is only printed as PASS after NInfer has
# loaded the artifact, resolved the compressed KV capacity, and generated a
# token on the selected device.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_rk4v4e8_probe.sh MODEL.ninfer [NINFER_BIN]
#
# Environment:
#   DEVICE=0
#   CONTEXTS="65536 131072 196608 262144"
#   PREFILL_CHUNK=1024
#   MTP_DRAFT=3              # 0 disables the MTP pass
#   LOG_DIR=sm75-rk4v4e8-probe

MODEL=${1:-}
BIN=${2:-./build/apps/ninfer}
DEVICE=${DEVICE:-0}
CONTEXTS=${CONTEXTS:-"65536 131072 196608 262144"}
PREFILL_CHUNK=${PREFILL_CHUNK:-1024}
MTP_DRAFT=${MTP_DRAFT:-3}
LOG_DIR=${LOG_DIR:-sm75-rk4v4e8-probe}

if [[ -z "${MODEL}" ]]; then
  echo "usage: $0 MODEL.ninfer [NINFER_BIN]" >&2
  exit 2
fi
if [[ ! -f "${MODEL}" ]]; then
  echo "model not found: ${MODEL}" >&2
  exit 2
fi
if [[ ! -x "${BIN}" ]]; then
  echo "ninfer binary not executable: ${BIN}" >&2
  exit 2
fi
if ! [[ "${DEVICE}" =~ ^[0-9]+$ ]]; then
  echo "DEVICE must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "${PREFILL_CHUNK}" =~ ^[0-9]+$ ]] || (( PREFILL_CHUNK == 0 || PREFILL_CHUNK % 128 != 0 )); then
  echo "PREFILL_CHUNK must be a positive multiple of 128" >&2
  exit 2
fi
if ! [[ "${MTP_DRAFT}" =~ ^[0-9]+$ ]] || (( MTP_DRAFT > 5 )); then
  echo "MTP_DRAFT must be in [0,5]" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"
SUMMARY="${LOG_DIR}/summary.tsv"
printf 'context\tmode\tresult\tlog\n' > "${SUMMARY}"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.total,driver_version \
    --format=csv,noheader | tee "${LOG_DIR}/gpu.txt"
fi

run_probe() {
  local context=$1
  local mode=$2
  shift 2
  local log="${LOG_DIR}/${context}-${mode}.log"

  echo "== ${context} tokens / ${mode} =="
  set +e
  "${BIN}" "${MODEL}" \
    --prompt "Reply with exactly: OK" \
    --max-context "${context}" \
    --kv-capacity auto \
    --prefill-chunk "${PREFILL_CHUNK}" \
    --kv-dtype rk4v4-e8 \
    --device "${DEVICE}" \
    --max-new 1 \
    --greedy \
    --no-thinking \
    --raw-output \
    "$@" >"${log}" 2>&1
  local rc=$?
  set -e

  if (( rc == 0 )); then
    printf '%s\t%s\tPASS\t%s\n' "${context}" "${mode}" "${log}" | tee -a "${SUMMARY}"
    return 0
  fi

  printf '%s\t%s\tFAIL(%s)\t%s\n' "${context}" "${mode}" "${rc}" "${log}" | tee -a "${SUMMARY}"
  tail -n 30 "${log}" >&2 || true
  return 1
}

highest_base=0
for context in ${CONTEXTS}; do
  if ! [[ "${context}" =~ ^[0-9]+$ ]] || (( context <= 0 || context > 262144 )); then
    echo "invalid context in CONTEXTS: ${context}" >&2
    exit 2
  fi

  if run_probe "${context}" eager --no-cuda-graph; then
    highest_base=${context}
  else
    # Capacity is monotonic for this fixed model/storage profile. Once a larger
    # context fails to fit, later sizes are expected to fail as well; keep the
    # log concise instead of reloading 17 GiB weights repeatedly.
    break
  fi
done

if (( MTP_DRAFT > 0 && highest_base > 0 )); then
  # Re-test the highest eager-fitting context with the intended fast path.
  # MTP and CUDA graph reserve additional state, so this can legitimately fail
  # even when the eager allocator probe passed.
  run_probe "${highest_base}" "mtp${MTP_DRAFT}-graph" \
    --spec mtp --draft-tokens "${MTP_DRAFT}" --lm-head-draft || true
fi

echo
echo "Results: ${SUMMARY}"
echo "Highest eager RK4V4E8 fit observed in this run: ${highest_base} tokens"
echo "Do not publish a 192K/256K ceiling unless the corresponding row is PASS on the actual 22GB card."
