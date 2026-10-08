#!/usr/bin/env bash
set -Eeuo pipefail

# RTX 2080 Ti 22GB / Qwen3.8-27B RK4V4E8 capacity and decode smoke probe.
#
# This deliberately distinguishes a successful allocator/runtime fit from a
# performance claim. A context size is only printed as PASS after NInfer has
# loaded the artifact, reserved that exact KV token capacity, and generated a
# token on the selected device. Do not use --kv-capacity auto here: automatic
# sizing is allowed to resolve below --max-context and would make a large-context
# allocation probe report false positives.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_rk4v4e8_probe.sh MODEL.ninfer [NINFER_BIN]
#
# Environment:
#   DEVICE=0
#   CONTEXTS="65536 131072 196608 262144"
#   PREFILL_CHUNK=1024
#   MTP_DRAFT=3              # 0 disables the MTP+graph pass
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
    --kv-capacity "${context}" \
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

highest_eager=0
eager_passed=()
for context in ${CONTEXTS}; do
  if ! [[ "${context}" =~ ^[0-9]+$ ]] || (( context <= 0 || context > 262144 )); then
    echo "invalid context in CONTEXTS: ${context}" >&2
    exit 2
  fi

  if run_probe "${context}" eager --no-cuda-graph; then
    highest_eager=${context}
    eager_passed+=("${context}")
  else
    # Capacity is monotonic for this fixed model/storage profile. Once a larger
    # explicit context reservation fails, later sizes are expected to fail as well;
    # keep the log concise instead of reloading the weights repeatedly.
    break
  fi
done

highest_mtp_graph=0
if (( MTP_DRAFT > 0 && ${#eager_passed[@]} > 0 )); then
  # Resolve the usable MTP+CUDA-Graph ceiling independently from eager capacity.
  # Start from the largest eager-fitting rung. If graph/speculative state pushes it
  # over the VRAM limit, walk downward until the first exact-capacity profile passes.
  for ((i = ${#eager_passed[@]} - 1; i >= 0; --i)); do
    context=${eager_passed[$i]}
    if run_probe "${context}" "mtp${MTP_DRAFT}-graph" \
      --spec mtp --draft-tokens "${MTP_DRAFT}" --lm-head-draft; then
      highest_mtp_graph=${context}
      break
    fi
  done
fi

echo
echo "Results: ${SUMMARY}"
echo "Highest explicit eager RK4V4E8 fit observed: ${highest_eager} tokens"
if (( MTP_DRAFT > 0 )); then
  echo "Highest explicit RK4V4E8 + MTP${MTP_DRAFT} + CUDA Graph fit observed: ${highest_mtp_graph} tokens"
fi
echo "Do not publish a 192K/256K ceiling unless the corresponding row is PASS on the actual 22GB card."
