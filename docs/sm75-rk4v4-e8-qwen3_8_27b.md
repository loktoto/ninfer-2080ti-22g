# RTX 2080 Ti 22GB: Qwen3.8-27B RK4V4E8 profile

This profile is specific to the SM75 port and the registered Qwen3.8-27B NInfer artifact.
It is intentionally conservative about context ceilings: a context size is considered supported on
22GB only after the included probe succeeds on the actual card.

## Build

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=75
cmake --build build --parallel
```

CUDA 12.8 or newer is required. CUDA 12.9 is the compile-gate baseline for this branch.

## Recommended interactive profile

Start with 128K and let the allocator resolve the largest page-aligned KV capacity that fits while
retaining runtime headroom:

```bash
./build/apps/ninfer MODEL.ninfer \
  --prompt "Hello" \
  --max-context 131072 \
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
- SM75 does not require native INT4 MMA. Packed codes are unpacked into the existing INT8 shared
  tile, so QK continues through Turing INT8 Tensor Cores.
- MTP3 is the existing 2080 Ti throughput sweet-spot baseline. It costs additional state, so a
  context that fits in eager mode can fail after CUDA-graph/MTP reservations are enabled.
- `--kv-capacity auto` is preferred on 22GB because driver/display/WDDM and optional Vision state can
  change the actually available memory.

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
that `--max-context`. The highest eager-fitting size is then retried with MTP3 + CUDA graph.

Do not publish 192K or 256K as a 2080 Ti 22GB ceiling unless that row passes on the physical card.

## Vision

Vision adds fixed and request-time GPU allocations. Re-run the capacity probe or lower
`--max-context` before enabling Vision on a profile that already leaves little allocator slack.
For mixed text/Vision use, 64K or 128K is the safer starting point until memory summary and real
requests confirm sufficient headroom.

## Performance measurement

For comparisons, hold all of the following fixed:

- artifact and weight format
- CUDA driver/toolkit
- GPU power/clock policy
- `prefill_chunk`
- context depth
- MTP draft window and proposal head
- CUDA graph enabled/disabled state

Measure at least:

- cold prefill tokens/s at 2K, 8K, 32K and the intended long-context depth
- decode tokens/s at 2K, 32K, 64K, 128K and the highest validated context
- MTP acceptance rate and output tokens/s
- resolved KV capacity, KV payload bytes, allocator slack and peak workspace

Compare RK4V4E8 against INT8 rather than against a differently configured baseline. The expected
benefit at long context is lower KV bandwidth and a larger capacity envelope; short-context speed can
be neutral or slightly worse because packed-code unpack and rotations add ALU work.

## Correctness gates

Before treating a new tuning change as production-ready:

1. SM75 compile gate must pass.
2. Runtime layout and serve-option contract tests must pass.
3. BF16/INT8 existing paths must remain unchanged in dispatch.
4. RK4V4E8 cache append and cached-attention results must be checked against a quantized reference
   envelope on a CUDA-capable runner.
5. Long-context retrieval and generation must be checked on the physical 2080 Ti 22GB.

The E8 implementation follows the upstream RK4V4E8 lineage: the nearest E8 point is projected before
integer nibble storage. Half-integral coset coordinates cannot be represented exactly without an
extra coset bit, so this storage format collapses them to the signed-I4 representation; it should be
evaluated as a quantized approximation, not bit-exact E8 reconstruction.
