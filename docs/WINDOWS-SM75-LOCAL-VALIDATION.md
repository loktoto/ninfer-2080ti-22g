# Native Windows SM75 local validation

Tests were run on **2026-10-12/13 (Asia/Hong_Kong)**. Native installation and short
Base-mode inference work on the machine below. **Production qualification failed**:
8K semantic retrieval, required tool calls and greedy MTP parity did not pass.
No production release or broad model-quality claim follows from this report.

## Machine and pinned inputs

| Item | Observed value |
| --- | --- |
| OS | Windows 11 Pro, 10.0.26200 |
| CPU / RAM | Ryzen 7 3700X, 8 cores / 16 threads, 15.9 GiB RAM |
| GPU | NVIDIA GeForce RTX 2080 Ti, 22,528 MiB VRAM, compute capability 7.5 |
| NVIDIA driver | 616.56 |
| MSVC / cl.exe | 14.44.35207 / 19.44.35229 |
| Windows SDK | 10.0.26100.0 |
| CUDA / CMake / Ninja | nvcc 13.1.80 / 3.31.6 / 1.13.2 |
| vcpkg | `b3ae22aef2b857af6e80d756c13f15db12be4e8a` |
| Runtime | Native x64, SM75, Qwen3.8-only, whole-program CUDA, static CUDA runtime |
| Local serving | Loopback port 8080, Base mode, context 8192, concurrency 1, INT8 KV |

The exact v2 model was downloaded and its byte count, magic and SHA-256 verified:

```text
repository  neroued/Qwen3.8-27B-NInfer
revision    3526913004b1cf552cb57b88d6a5c6f5e4a89a70
filename    qwen3_8_27b.ninfer
bytes       18210531328
sha256      eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e
model_id    qwen3.8-27b
weights_id  groupwise-int
```

The compiler was provisioned from NVIDIA's versioned CUDA 13.1.0 redistributables,
with SHA-256 checks for nvcc, libnvvm, CRT, cudart, CCCL, cuobjdump and NVTX.
The `Nvidia.CUDA` winget package labelled 13.1 resolved to 13.1.1 when inspected;
it was not used as a substitute for the locked compiler. Portable CMake and Ninja
were also verified. No WSL or global CUDA driver replacement was required.

## Problems found and fixed

| Problem | Resulting change |
| --- | --- |
| Windows CI reached LNK2019/LNK1120 for `SequencePlan`, `RequestBasePlan` and `RequestPlan` moves | Explicit ownership-transfer bodies emit the required MSVC symbols; both applications link |
| Developer bootstrap installed drifting CMake/Ninja/CUDA versions | Provision the locked portable tool versions and request the pinned VS/SDK components |
| `runtime/` ignored source runtime directories | Anchor the mutable-runtime ignore rule to `/runtime/` |
| Smoke could accept diagnostics or wrong/nonempty output | Separate stdout/stderr, require exit 0 and exact `SM75 OK`, and cover four verdict fixtures |
| Fresh PowerShell 5.1 packaging read unset `$LASTEXITCODE` after a PowerShell validator | Rely on the validator's terminating exceptions |
| SBOM interpolation treated `Version?feature` as a variable; generic-list array conversion failed | Brace version substitutions and use `ToArray()`; all 11 component versions verified |
| Compatible GPU selection reused automatic regex `$Matches` as its result array | Use `CompatibleGpus`; eight inventory fixtures cover selection and rejection |
| Compiled chat templates emitted ordinary `thinking`/`response` words instead of `<think>`/`</think>` | Restore the canonical generation/history markers and reasoning extraction |
| Thinking-toggle template received unsupported effort instructions and dropped an empty system turn | Match the canonical template semantics and capability restrictions |
| Template tests depended on private tokenizer paths and checkout line endings | Add an artifact-free template mode, normalize fixture CRLF, and run it in Windows build/CI |
| PowerShell 5.1 treats redirected native stderr as `NativeCommandError` under `Stop` | Capture parity CLI streams with hidden `Start-Process`, preserving quoted prompt/path arguments |

The original [Windows CI run](https://github.com/loktoto/ninfer-2080ti-22g/actions/runs/38121854032)
provides the linker failure. Before the template fix, a fresh CLI and the API both
returned `4\n</think>\n\n4` for the arithmetic prompt with thinking disabled; a
literal digit prompt returned empty output. The corrected installed API returns
exactly `4` for both prompts and for arithmetic with thinking enabled.

## Exact tested package and results

```text
source commit  94c0484de2e41dc3683ee60234c49e66dc08476d
package        ninfer-windows-sm75-94c0484de2e4.zip
package bytes  659173081
package sha256 95384bf59708a405bc8dc33731ccfe65e39eb6233f6680ec5e9a86322c25790b
ninfer.exe     c63039aaa595e19edd71ea641c3c68f3564dce59f81df497dc385fff020d18e8
ninfer-serve   4ee0f593d4fab8ffd9fbc65b4f7bc0ad7381c0c7e7df9eb79b29c89484d83980
```

| Check | Result |
| --- | --- |
| Exact toolchain assertion, native build and link | PASS; two compile jobs |
| Canonical template, instruction ordering, effort and rewrite-boundary checks | PASS in artifact-free C++ test mode |
| Physical W8_A16 LinearPair numerical conformance | PASS |
| PowerShell 5.1 distribution contract | PASS; 46 required files, 11 launchers |
| Host smoke verdict / GPU inventory / upgrade-rollback fixtures | PASS; 4 / 8 / 2 cases; these are not GPU inference evidence |
| ZIP hashes, embedded manifests/SBOM, extracted PE dependency closure and isolated-PATH startup | PASS |
| Clean-ZIP native install, retained pinned model, protected key, shortcuts and Base readiness | PASS |
| Installed API exact smoke, arithmetic thinking off/on, literal digit, SSE content plus DONE, unauthenticated 401 | PASS; six checks, healthy model `qwen3.8-27b` |
| 8K-capacity short smoke | PASS; exact `SM75 OK` |
| Semantic retrieval near 8K | **FAIL**; 7936 input tokens, 32 generated tokens, output limit reached without the needle |
| Required tool call | **FAIL**; no structured call with thinking off / 128 tokens, or on / 256 tokens |
| Greedy MTP0/MTP3 token-ID and raw-output parity | **FAIL**; first divergent generated token at position 11 |

The 8K retrieval expected `SM75-8192-ZEBRA-42-QUARTZ-7719`. It returned analysis
beginning “To determine the correct answer…” instead. The request took about
104 seconds, including about 102 seconds to first token. Raising the token budget
was not used to relabel the original acceptance case as a pass.

In the independent MTP check (context 8192, INT8 KV, greedy, no thinking,
raw output, maximum 64 tokens), Base produced:

```text
Deterministic parity ensures consistent, reproducible results by eliminating random variation in data processing.<|endoftext|>
```

MTP3 with `--lm-head-draft` produced:

```text
Deterministic parity ensures consistent, reproducible results by guaranteeing that identical inputs always produce identical outputs.<|endoftext|>
```

The first ten token IDs matched; then Base selected `38192` and MTP selected
`14988`. MTP reported 11 rounds, 33 drafted tokens, 9 accepted tokens (27.27%).
Meaning similarity does not satisfy exact greedy parity. These tests do not
establish the root cause of the remaining semantic/numerical discrepancies.

Observed Base GPU weights use was 15.92 GiB, with approximately 16.71 GiB planned
device allocation at 8K and a 264 MiB INT8 cache payload. Free memory varied with
the desktop workload. Small-prompt measurements are not a throughput benchmark.

## Reproduction and daily use

Follow [the pinned developer setup](windows-sm75.md#provisioning-a-fresh-developer-pc), then:

```powershell
.\scripts\build-windows-sm75.ps1 -WholeProgramCuda -RunFrontendRegression -RunW8Regression
.\scripts\verify-windows-sm75.ps1 -RequireDependencyAudit
.\scripts\package-windows-sm75.ps1
.\scripts\verify-package-windows-sm75.ps1
```

Use a **clean** extraction of the checksummed ZIP for installation. Running
acceptance writes logs under the extracted tree; attempting to install that
modified tree correctly fails the unchecksummed-file check. Extract the ZIP again
for installation rather than weakening its integrity check.

For installed Base serving, use `launchers\Start-NInfer.bat`,
`launchers\Status-NInfer.bat` and `launchers\Stop-NInfer.bat`. Read the protected
API key locally; do not put it in Git, logs or shared requests:

```powershell
$Root = [Environment]::GetEnvironmentVariable('NINFER_SM75_HOME','User')
$Key = (Get-Content (Join-Path $Root 'secrets\api-key.txt') -Raw).Trim()
$Headers = @{ Authorization = 'Bearer ' + $Key }
$Body = @{ model='qwen3.8-27b'; messages=@(@{role='user';content='What is 2 + 2? Reply with only the digit.'}); temperature=0; enable_thinking=$false; max_tokens=32 } | ConvertTo-Json -Depth 8
Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -Headers $Headers -ContentType 'application/json' -Body $Body
```

**Use Base mode for this installation.** MTP and tool calling are unqualified.
32K/64K/128K, Vision, RK4V4E8, other GPUs/OSes, the full private-reference
frontend/media suite and production release publication were not qualified by
this run. The [release gates](PROJECT-STATUS.md#acceptance-and-release-contract)
remain in force. The PR's later documentation commit does not change the tested
package's source SHA or its qualification status.
