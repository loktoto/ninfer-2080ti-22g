# RTX 2080 Ti 22GB: Qwen3.8-27B RK4V4E8 profile

This profile is specific to the SM75 port and the registered Qwen3.8-27B NInfer artifact.
It is intentionally conservative about context ceilings: a context size is considered supported on
22GB only after the included probe succeeds on the actual card.

## Build

Runtime-only build:

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=75
cmake --build build --parallel
```

For the preferred one-load-per-profile autotuner, include the production benchmark target:

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=75 \
  -DNINFER_BUILD_BENCHMARKS=ON
cmake --build build --parallel --target ninfer ninfer_bench
```

CUDA 12.8 or newer is required. CUDA 12.9 is the compile-gate baseline for this branch.

## Current Qwen3.8 artifact compatibility

The current registered Qwen3.8-27B NInfer container can include the optional `dflash2/*` payload in
addition to the text, MTP, Vision and draft-head objects. The SM75 target validates the complete
DFlash2 descriptor contract when the `dflash2/feature_projection` sentinel is present, but places all
66 DFlash2 tensors in `ValidateOnly` storage.

That distinction is important on a 22GB card: artifact file size is not the same thing as resident GPU
weight size. Validate-only DFlash2 objects consume neither the device weight arena nor H2D bandwidth.
They remain schema-checked, so an incomplete or shape/format-incompatible DFlash2 payload is rejected
instead of being silently ignored.

Full DFlash2 execution is intentionally out of scope for this SM75 RK4V4E8 profile. Enabling it would
materialize an additional backend and consume memory that is currently reserved for long-context KV;
it should be evaluated as a separate short-context throughput profile rather than silently enabled.

## Recommended interactive profile

Use 64K as the conservative daily starting point, then enable 128K when the workload needs it. Let
the allocator resolve the largest page-aligned KV capacity that fits while retaining runtime headroom:

```bash
./build/apps/ninfer MODEL.ninfer \
  --prompt "Hello" \
  --max-context 65536 \
  --kv-capacity auto \
  --prefill-chunk 1024 \
  --kv-dtype rk4v4-e8 \
  --spec mtp \
  --draft-tokens 3 \
  --lm-head-draft
```

Why this profile:

- `rk4v4-e8` halves the K/V code-plane width relative to INT8 while retaining FP16 group-64 scales.
- K and Q are Hadamard-rotated into the same domain; K is E8-projected and stored as packed signed
  4-bit codes. V is rotated and stored as packed signed 4-bit codes; output is inverse-rotated.
- Packed codes are expanded into the existing INT8 shared-memory tiles, so QK continues through
  Turing INT8 Tensor Cores rather than depending on Ada/Blackwell-only kernel mechanisms.
- The existing public 2080 Ti baseline found MTP3 to be a strong throughput point, but the best draft
  window is workload- and kernel-dependent. Treat MTP3 as a fallback, not a permanent tuning law.
- `--kv-capacity auto` is preferred on 22GB because driver/display allocations, CUDA Graph state,
  MTP state and optional Vision state change the actually available memory.

## Physical-card autotune

Do not copy the best MTP window or prefill tile from a 4090 profile. Turing has a different occupancy,
register and shared-memory balance. Run the included sweep on the physical 2080 Ti:

```bash
chmod +x bench/targets/qwen3_6_27b/sm75_autotune.sh
./bench/targets/qwen3_6_27b/sm75_autotune.sh MODEL.ninfer
```

When `./build/bench/ninfer_bench` exists, the script uses it by default. Each profile loads the model
once, performs the warmup and measured repetitions inside one Engine, and writes a structured JSON
report. This avoids repeatedly reading/uploading the roughly 19GiB artifact for every repetition.
If the benchmark binary is absent, the script falls back to the slower CLI-per-repetition path.

The default sweep compares:

- INT8 versus RK4V4E8 KV
- prefill chunks 512 and 1024
- ordinary autoregressive decode versus MTP2, MTP3, MTP4 and MTP5
- repeated greedy 256-token decode runs

It records mean/stddev decode throughput, MTP acceptance and GPU snapshots including clocks, power,
temperature and memory usage. `summary.tsv` prints the fastest measured profile on that card.
Override `PREFILL_CHUNKS`, `DRAFTS`, `KV_MODES`, `MAX_CONTEXT`, `MAX_NEW`, `BENCH_PROMPT`, `WARMUP` or
`REPS` when a wider sweep is required.

MTP draft windows above five are deliberately not enabled in this PR. Newer Ada-targeted NInfer
branches experiment with wider verification tiles, but the SM75 target needs a separately scoped
kernel/graph qualification before increasing its target maximum. The autotuner only selects among
profiles that this branch fully supports.

The autotune sweep is a throughput test, not a long-context capacity proof.

## Context validation

The model's native target envelope is 262,144 tokens. This is an architectural maximum, not a claim
that every 22GB card can allocate it with every runtime feature enabled.

Run:

```bash
chmod +x bench/targets/qwen3_6_27b/sm75_rk4v4e8_probe.sh
./bench/targets/qwen3_6_27b/sm75_rk4v4e8_probe.sh MODEL.ninfer
```

Default fit ladder:

1. 65,536
2. 131,072
3. 196,608
4. 262,144

Each eager row is marked PASS only after the model loads and generates one token with RK4V4E8 at
that `--max-context`. The highest eager-fitting size is then retried with MTP3 + CUDA Graph so the
extra speculative and graph reservations are included in the fit check.

Do not publish 192K or 256K as a 2080 Ti 22GB ceiling unless that row passes on the physical card.
A capacity allocation pass also does not replace long-context retrieval/quality validation.

## Vision

Vision adds fixed and request-time GPU allocations. Re-run the capacity probe or lower
`--max-context` before enabling Vision on a profile that already leaves little allocator slack.
For mixed text/Vision use, 64K or 128K is the safer starting point until memory summary and real
requests confirm sufficient headroom.

## Performance measurement

For comparisons, hold all of the following fixed:

- exact artifact identity and weight format
- CUDA driver/toolkit
- GPU power/clock policy and thermal state
- `prefill_chunk`
- context depth
- MTP draft window and proposal head
- CUDA Graph enabled/disabled state
- sampling mode and generated-token count

Measure at least:

- cold prefill tokens/s at 2K, 8K, 32K and the intended long-context depth
- decode tokens/s at 2K, 32K, 64K, 128K and the highest validated context
- MTP acceptance rate, output tokens/s and engine tokens/s
- resolved KV capacity, KV payload bytes, allocator slack and peak workspace
- GPU clocks, power and temperature during each comparable run

`ninfer_bench` accepts `--kv-dtype rk4v4-e8`, so structured table/JSON/CSV benchmark output can label
the compressed format correctly. Compare RK4V4E8 against INT8 under otherwise identical settings.
The expected long-context benefit is lower KV bandwidth and a larger capacity envelope; short-context
speed can be neutral or slightly worse because packed-code unpack and rotations add ALU work.

## SM75 resource constraints

Turing compute capability 7.5 has a strict per-block shared-memory ceiling. The current SM75 prefill
path deliberately uses a 32x32 tile with 8 warps and 44,288 bytes of shared scratch, keeping its
static allocation below the conventional 48KiB threshold.

The decode launcher also contains SM75-specific guards. The inherited TokenTile=6 / roughly 2K-8K
INT8 route previously selected a KeyBlock=64 dynamic arena whose 64KiB arena alone exhausted the
Turing per-block ceiling before the kernel's static scratch was counted. On SM75 that route now uses
the established KeyBlock=32 static profile instead. Compile-time assertions reject any SM75 decode
specialization whose static allocation exceeds 48KiB or whose static+dynamic allocation exceeds
64KiB. SM86/SM120 scheduling is unchanged.

Do not widen tiles merely because a newer GPU profile uses more shared memory: change tile geometry
only after physical-card register/occupancy and throughput measurements show a net win.

## Correctness gates

Before treating a new tuning change as production-ready:

1. SM75 CUDA compile gate must pass.
2. Runtime layout, serve-option, request-log and benchmark parser contract tests must pass.
3. BF16/INT8 existing paths must remain unchanged in dispatch.
4. Optional DFlash2 payload must remain validate-only on this SM75 profile unless a separately scoped
   implementation deliberately enables that backend.
5. RK4V4E8 cache append and cached-attention results must be checked against a quantized reference
   envelope on a CUDA-capable runner.
6. Long-context retrieval and generation must be checked on the physical RTX 2080 Ti 22GB.
7. A claimed best MTP/prefill profile must come from the physical-card autotune results, not a 4090
   benchmark copied across architectures.

The E8 implementation follows the upstream RK4V4E8 lineage: the nearest E8 point is projected before
integer nibble storage. Half-integral coset coordinates cannot be represented exactly without an
extra coset bit, so this storage format collapses them to the signed-I4 representation; it should be
evaluated as a quantized approximation, not bit-exact E8 reconstruction.
