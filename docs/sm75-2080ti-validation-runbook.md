# RTX 2080 Ti 22GB / Qwen3.8-27B physical validation runbook

This runbook is the release gate for the SM75 RK4V4E8 profile. Build success is necessary but is not evidence of a context ceiling, throughput result, or long-context quality.

## 0. Freeze the environment

Record before measuring:

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total,power.limit,clocks.max.sm,clocks.max.memory --format=csv
nvcc --version
sha256sum MODEL.ninfer
```

Keep the same artifact, driver/toolkit, power limit, clocks, display load and thermal state while comparing KV modes. Do not compare one run taken at a different power/clock policy as if only the software changed.

## 1. Build the SM75 runtime and benchmark

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=75 \
  -DNINFER_BUILD_APPS=ON \
  -DNINFER_BUILD_BENCHMARKS=ON
cmake --build build --parallel --target ninfer ninfer-serve ninfer_bench
```

The hosted CI uses a serial CUDA build because the large GQA decode translation unit can exhaust runner RAM when another heavy nvcc process overlaps it. A local machine with enough host RAM may build in parallel; this does not alter runtime code.

## 2. Capacity gate — prove what actually fits

```bash
chmod +x bench/targets/qwen3_6_27b/sm75_rk4v4e8_probe.sh
./bench/targets/qwen3_6_27b/sm75_rk4v4e8_probe.sh MODEL.ninfer
```

Default ladder: 64K, 128K, 192K, 256K.

A row is a capacity PASS only when the probe uses `--max-context N --kv-capacity N`, the model loads, and one token is generated. `--kv-capacity auto` is intentionally not accepted as proof because automatic sizing may resolve below the requested maximum context.

The highest eager-fitting rung is separately retried with MTP + CUDA Graph. Eager fit and MTP/graph fit are different results.

Do not publish a 192K or 256K ceiling unless that exact row passed on the physical 22GB card.

## 3. Performance gate — compare identical workloads

```bash
chmod +x bench/targets/qwen3_6_27b/sm75_autotune.sh
./bench/targets/qwen3_6_27b/sm75_autotune.sh MODEL.ninfer
```

The default matrix compares:

- KV: `int8`, `rk4v4-e8`
- prefill chunk: 512, 1024
- speculative draft: MTP0, 2, 3, 4, 5
- repeated greedy decode

Use `ninfer_bench` rather than the CLI fallback when publishing results. It reports prefill throughput, decode mean/stddev and MTP acceptance while loading the model once per profile.

Do not choose a daily profile from decode throughput alone. The harness reports:

- fastest decode profile;
- fastest prefill profile;
- balanced profile: at least 97% of best decode throughput, then highest prefill throughput.

For long-prompt workloads, repeat the winning candidates with larger `BENCH_PROMPT` values, for example:

```bash
BENCH_PROMPT=32768 REPS=3 ./bench/targets/qwen3_6_27b/sm75_autotune.sh MODEL.ninfer
BENCH_PROMPT=65536 REPS=3 ./bench/targets/qwen3_6_27b/sm75_autotune.sh MODEL.ninfer
```

A short-prompt prefill result must not be extrapolated to 64K+ ingestion.

## 4. Quality gate — token-calibrated long-context retrieval

First set `MAX_CONTEXT` no higher than a capacity rung that passed in section 2.

```bash
chmod +x bench/targets/qwen3_6_27b/sm75_long_context_quality.sh
MAX_CONTEXT=131072 \
  ./bench/targets/qwen3_6_27b/sm75_long_context_quality.sh MODEL.ninfer
```

The harness loads `ninfer-serve` once, uses `/v1/messages/count_tokens` to calibrate each prompt to an observed token depth, places a unique retrieval needle at early/middle/late positions, and requires exact-code recall.

To validate a higher proven capacity:

```bash
MAX_CONTEXT=262144 \
QUALITY_CONTEXTS="32768 65536 131072 196608 262144" \
  ./bench/targets/qwen3_6_27b/sm75_long_context_quality.sh MODEL.ninfer
```

If an RK4V4E8 + MTP run fails, do not immediately attribute the failure to 4-bit KV. Run the same test without speculative decoding:

```bash
MAX_CONTEXT=262144 MTP_DRAFT=0 \
QUALITY_CONTEXTS="32768 65536 131072 196608 262144" \
  ./bench/targets/qwen3_6_27b/sm75_long_context_quality.sh MODEL.ninfer
```

Interpretation:

- RK4V4E8 MTP PASS + MTP0 PASS: long-context retrieval gate passes.
- RK4V4E8 MTP FAIL + MTP0 PASS: investigate speculative/MTP path before blaming KV compression.
- RK4V4E8 MTP0 FAIL + INT8 MTP0 PASS: compressed-KV quality/correctness is the leading suspect.
- both INT8 and RK4V4E8 fail at the same depth: investigate model/context/prompt or shared attention path first.

For an INT8 control, run the same harness with `KV_DTYPE=int8` at a capacity that INT8 actually fits.

## 5. Vision headroom gate

Vision has fixed and request-time allocations. A text-only context fit is not a Vision fit. Start from 64K or 128K and measure memory summary plus representative image/video requests before increasing context.

Do not claim `Vision + 256K + MTP3` from a text-only capacity result.

## 6. Release decision

A profile can be called validated on RTX 2080 Ti 22GB only when all applicable gates below are recorded from the same physical card:

- exact artifact hash and software/driver environment recorded;
- explicit capacity rung passes;
- benchmark has repeated measurements and no unexplained outlier selected as winner;
- MTP acceptance is recorded alongside output tok/s;
- long-context retrieval passes at the intended depth, with MTP0 control available for failures;
- Vision headroom is measured separately when Vision is part of the advertised profile.

Until those physical-card results exist, repository CI establishes build/contract correctness only; it does not establish the final 2080 Ti performance number or maximum usable context.
