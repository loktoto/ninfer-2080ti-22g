#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# RTX 2080 Ti 22GB / Qwen3.8-27B short-context performance acceptance gate.
#
# This consumes sm75_autotune.sh's summary.tsv instead of running another model load. The external
# llama.cpp result is a reference point, not a substitute for an apples-to-apples local run; the
# default NInfer floor is deliberately higher so a 40-45 tok/s regression cannot be called done.
#
# Usage:
#   ./bench/targets/qwen3_6_27b/sm75_perf_acceptance.sh [summary.tsv]
#
# Environment overrides:
#   REFERENCE_DECODE_TOK_S=47.6  # public llama.cpp reference to beat
#   REQUIRED_DECODE_TOK_S=50.0   # minimum NInfer acceptance floor
#   STRETCH_DECODE_TOK_S=55.0    # stretch target
#   MAX_CV_PCT=5.0               # reject an unstable winning profile
#
# Exit status:
#   0  best stable profile reaches REQUIRED_DECODE_TOK_S
#   1  benchmark is valid but misses the reference/floor or is too noisy
#   2  malformed/missing input or invalid thresholds

SUMMARY=${1:-sm75-autotune/summary.tsv}
REFERENCE_DECODE_TOK_S=${REFERENCE_DECODE_TOK_S:-47.6}
REQUIRED_DECODE_TOK_S=${REQUIRED_DECODE_TOK_S:-50.0}
STRETCH_DECODE_TOK_S=${STRETCH_DECODE_TOK_S:-55.0}
MAX_CV_PCT=${MAX_CV_PCT:-5.0}

fail_config() {
  echo "error: $*" >&2
  exit 2
}

is_positive_number() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

is_nonnegative_number() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]
}

[[ -f "${SUMMARY}" ]] || fail_config "summary not found: ${SUMMARY}"
is_positive_number "${REFERENCE_DECODE_TOK_S}" || fail_config "REFERENCE_DECODE_TOK_S must be positive"
is_positive_number "${REQUIRED_DECODE_TOK_S}" || fail_config "REQUIRED_DECODE_TOK_S must be positive"
is_positive_number "${STRETCH_DECODE_TOK_S}" || fail_config "STRETCH_DECODE_TOK_S must be positive"
is_nonnegative_number "${MAX_CV_PCT}" || fail_config "MAX_CV_PCT must be non-negative"

awk -v ref="${REFERENCE_DECODE_TOK_S}" -v required="${REQUIRED_DECODE_TOK_S}" \
    -v stretch="${STRETCH_DECODE_TOK_S}" 'BEGIN {
      if (!(required > ref)) exit 1;
      if (!(stretch >= required)) exit 2;
    }' || fail_config "expected REFERENCE < REQUIRED <= STRETCH"

EXPECTED_HEADER=$'kv\tprefill_chunk\tdraft\tstatus\tprefill_mean_tok_s\tdecode_mean_tok_s\tdecode_stddev_tok_s\tacceptance_pct\tmode\treport'
IFS= read -r header < "${SUMMARY}" || fail_config "cannot read summary header"
[[ "${header}" == "${EXPECTED_HEADER}" ]] || fail_config "unexpected summary schema"

BEST=$(awk -F '\t' '
  NR > 1 && $4 == "PASS" {
    decode = $6 + 0;
    if (!seen || decode > best) {
      seen = 1;
      best = decode;
      line = $0;
    }
  }
  END { if (seen) print line }
' "${SUMMARY}")

[[ -n "${BEST}" ]] || fail_config "summary contains no successful profile"

IFS=$'\t' read -r kv chunk draft status prefill decode stddev acceptance mode report <<< "${BEST}"

METRICS=$(awk -v decode="${decode}" -v stddev="${stddev}" -v ref="${REFERENCE_DECODE_TOK_S}" \
              -v required="${REQUIRED_DECODE_TOK_S}" -v stretch="${STRETCH_DECODE_TOK_S}" \
              -v max_cv="${MAX_CV_PCT}" 'BEGIN {
  cv = decode > 0 ? (100.0 * stddev / decode) : 1e9;
  gain = 100.0 * (decode / ref - 1.0);
  beats_ref = decode > ref;
  reaches_required = decode >= required;
  reaches_stretch = decode >= stretch;
  stable = cv <= max_cv;
  printf "%.3f\t%.3f\t%d\t%d\t%d\t%d", cv, gain, beats_ref, reaches_required,
         reaches_stretch, stable;
}')
IFS=$'\t' read -r cv gain beats_ref reaches_required reaches_stretch stable <<< "${METRICS}"

echo "SM75 short-context performance acceptance"
echo "  profile: kv=${kv} prefill_chunk=${chunk} draft=${draft}"
echo "  decode:  ${decode} tok/s (stddev=${stddev}, CV=${cv}%)"
echo "  prefill: ${prefill} tok/s"
echo "  MTP acceptance: ${acceptance}%"
echo "  measurement: ${mode} report=${report}"
echo "  reference: > ${REFERENCE_DECODE_TOK_S} tok/s"
echo "  required:  >= ${REQUIRED_DECODE_TOK_S} tok/s"
echo "  stretch:   >= ${STRETCH_DECODE_TOK_S} tok/s"
echo "  gain vs reference: ${gain}%"

if (( stable == 0 )); then
  echo "FAIL: winning profile is too noisy (CV ${cv}% > ${MAX_CV_PCT}%)." >&2
  exit 1
fi
if (( beats_ref == 0 )); then
  echo "FAIL: NInfer does not beat the ${REFERENCE_DECODE_TOK_S} tok/s reference." >&2
  exit 1
fi
if (( reaches_required == 0 )); then
  echo "FAIL: NInfer beats the reference but misses the ${REQUIRED_DECODE_TOK_S} tok/s floor." >&2
  exit 1
fi

if (( reaches_stretch )); then
  echo "PASS-STRETCH: ${decode} tok/s reaches the ${STRETCH_DECODE_TOK_S} tok/s stretch target."
else
  echo "PASS: ${decode} tok/s clears the required floor; ${STRETCH_DECODE_TOK_S} tok/s remains the stretch target."
fi
