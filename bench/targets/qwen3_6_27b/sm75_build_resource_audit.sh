#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WHOLE_PROGRAM="${WHOLE_PROGRAM:-0}"
TARGETS="${TARGETS:-ninfer}"
CLEAN="${CLEAN:-0}"

case "${WHOLE_PROGRAM}" in
  0)
    build_mode="rdc"
    whole_program_cmake="OFF"
    ;;
  1)
    build_mode="whole-program"
    whole_program_cmake="ON"
    ;;
  *)
    echo "error: WHOLE_PROGRAM must be 0 or 1" >&2
    exit 2
    ;;
esac

BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build-sm75-audit-${build_mode}}"
LOG_FILE="${LOG_FILE:-${BUILD_DIR}/sm75-build-audit.log}"

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake is required" >&2
  exit 2
fi
if ! command -v nvcc >/dev/null 2>&1; then
  echo "error: nvcc is required and must be on PATH" >&2
  exit 2
fi

if [[ "${CLEAN}" == "1" ]]; then
  rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"

{
  echo "== SM75 build resource audit =="
  echo "root=${ROOT_DIR}"
  echo "build_mode=${build_mode}"
  echo "whole_program=${WHOLE_PROGRAM}"
  echo "build_dir=${BUILD_DIR}"
  echo "targets=${TARGETS}"
  echo "uname=$(uname -a)"
  if [[ -r /proc/version ]]; then
    echo "proc_version=$(tr '\n' ' ' < /proc/version)"
  fi
  cmake --version | head -n 1
  nvcc --version | tail -n 1
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
  fi
} | tee "${LOG_FILE}"

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=75 \
  -DCMAKE_CUDA_FLAGS="-Xptxas=-v" \
  -DNINFER_CUDA_WHOLE_PROGRAM="${whole_program_cmake}" \
  -DBUILD_TESTING=OFF \
  -DNINFER_BUILD_APPS=ON \
  -DNINFER_BUILD_BENCHMARKS=ON \
  2>&1 | tee -a "${LOG_FILE}"

read -r -a target_array <<< "${TARGETS}"
set +e
cmake --build "${BUILD_DIR}" --parallel 1 --target "${target_array[@]}" \
  2>&1 | tee -a "${LOG_FILE}"
build_status=${PIPESTATUS[0]}
set -e

echo | tee -a "${LOG_FILE}"
echo "== Audit summary ==" | tee -a "${LOG_FILE}"

if grep -Eq -- '(^|[[:space:]])-rdc=true([[:space:]]|$)|--relocatable-device-code[=[:space:]]+true' "${LOG_FILE}"; then
  echo "relocatable_device_code=detected" | tee -a "${LOG_FILE}"
else
  echo "relocatable_device_code=not-observed-in-build-log" | tee -a "${LOG_FILE}"
fi

ptxas_function_count=$(grep -c 'ptxas info.*Function properties for' "${LOG_FILE}" || true)
spill_line_count=$(grep -Ec 'ptxas info.*[1-9][0-9]* bytes spill (stores|loads)' "${LOG_FILE}" || true)
stack_line_count=$(grep -Ec 'ptxas info.*[1-9][0-9]* bytes stack frame' "${LOG_FILE}" || true)
register_line_count=$(grep -Ec 'ptxas info.*Used [0-9]+ registers' "${LOG_FILE}" || true)

echo "ptxas_function_records=${ptxas_function_count}" | tee -a "${LOG_FILE}"
echo "ptxas_register_records=${register_line_count}" | tee -a "${LOG_FILE}"
echo "nonzero_spill_records=${spill_line_count}" | tee -a "${LOG_FILE}"
echo "nonzero_stack_records=${stack_line_count}" | tee -a "${LOG_FILE}"

if (( spill_line_count > 0 )); then
  echo "-- non-zero spill records (first 40) --" | tee -a "${LOG_FILE}"
  grep -E 'ptxas info.*[1-9][0-9]* bytes spill (stores|loads)' "${LOG_FILE}" | head -n 40 | tee -a "${LOG_FILE}" || true
fi
if (( stack_line_count > 0 )); then
  echo "-- non-zero stack records (first 40) --" | tee -a "${LOG_FILE}"
  grep -E 'ptxas info.*[1-9][0-9]* bytes stack frame' "${LOG_FILE}" | head -n 40 | tee -a "${LOG_FILE}" || true
fi

if grep -Eqi 'ptxas.*(segmentation fault|error 139)|segmentation fault.*ptxas|ptxas fatal' "${LOG_FILE}"; then
  echo "ptxas_crash=detected" | tee -a "${LOG_FILE}"
  echo "hint: this matches the known SM75/WSL2 -O3 -rdc=true failure class; compare WHOLE_PROGRAM=0 and WHOLE_PROGRAM=1 before changing optimization level." | tee -a "${LOG_FILE}"
else
  echo "ptxas_crash=not-detected" | tee -a "${LOG_FILE}"
fi

echo "build_exit_code=${build_status}" | tee -a "${LOG_FILE}"
echo "log=${LOG_FILE}" | tee -a "${LOG_FILE}"

exit "${build_status}"
