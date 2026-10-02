# Native Windows production build — RTX 2080 Ti 22GB (SM75)

This branch provides the native Windows/MSVC product path for the Turing `sm_75` port.
The deliverable is a staged runtime plus a checksummed ZIP; WSL2 is not required.

## Runtime requirements

For the packaged Windows release:

- Windows 10/11 x64
- NVIDIA RTX 2080 Ti / TU102 (`sm_75`), including 22GB-mod cards
- at least 20,000 MiB VRAM reported by `nvidia-smi`
- NVIDIA driver branch **R580 or newer**
- Microsoft Visual C++ 2015-2022 x64 runtime

The Qwen3.8-only Windows product links `CUDA::cudart_static`, so a normal user does **not** need the CUDA Toolkit, Visual Studio, CMake, Ninja, Git, Python, or PowerShell 7.

## Supported build toolchain

Production builds are fail-closed against `config/windows-sm75-toolchain.json`. The qualified
package uses one explicit toolchain:

| Component | Version |
|---|---|
| MSVC v143 toolset | 14.44.35207 |
| cl.exe | 19.44.35229 |
| Windows SDK | 10.0.26100.0 |
| CUDA compiler | 13.1.80 |
| CMake | 3.31.6 |
| Ninja | 1.13.2 |
| vcpkg commit | b3ae22aef2b857af6e80d756c13f15db12be4e8a |
| CUDA architecture | sm_75 |

`scripts/assert-windows-sm75-toolchain.ps1` fails closed on compiler/SDK/CUDA/CMake/Ninja/vcpkg
drift and writes `BUILD-TOOLCHAIN.json`. Package verification cross-checks checked-out lock,
packaged lock, BUILD-TOOLCHAIN and BUILD-MANIFEST. A toolchain upgrade therefore requires an
explicit source change followed by hosted CI and physical RTX 2080 Ti re-qualification.

The production path does not use `-allow-unsupported-compiler`.

## One-click packaged installation

Extract the release ZIP and run:

```text
START-HERE.bat
```

The package installer performs full extracted-file SHA-256 coverage validation, validates the build manifest and embedded model-lock hash, checks the RTX 2080 Ti / CC 7.5 / VRAM / R580+ driver contract, installs VC++ runtime if needed, installs the runtime atomically, downloads and verifies the pinned model with resumable `curl.exe`, creates local configuration/key material, starts Base mode and runs readiness checks.

Full user guide: [INSTALL-WINDOWS-SM75.md](INSTALL-WINDOWS-SM75.md).

## Reproducible build

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\build-windows-sm75.ps1 -Clean
```

The script:

1. activates the VS2022 x64 developer environment;
2. checks `git`, `cmake`, `ninja`, `cl`, and `nvcc`;
3. pins vcpkg to the repository-tested commit;
4. installs the Windows FFmpeg and libcurl dependencies;
5. configures CMake for `CMAKE_CUDA_ARCHITECTURES=75` and `NINFER_QWEN38_ONLY=ON`;
6. builds the Qwen3.8-27B production profile with a bounded compile-job count;
7. stages `ninfer.exe` and `ninfer-serve.exe` under `out\windows-sm75\bin` with required vcpkg runtime DLLs.

The production profile removes the Qwen3.6-35B-A3B target registration and replaces its heaviest
BF16 GDN CUDA template specializations with fail-fast stubs. Normal non-profile builds retain the
full target set. This avoids spending hours compiling kernels that the RTX 2080 Ti Qwen3.8 product
cannot load through the production registry.

For an already-provisioned dependency tree:

```powershell
.\scripts\build-windows-sm75.ps1 -SkipDependencies
```

## Pinned Qwen3.8 production artifact

Do **not** use an unpinned latest artifact. This branch implements the NInfer v2 artifact contract;
upstream artifact v3 is a different framing/schema migration and is rejected with a targeted error.

The production lock is `config/windows-sm75-artifacts.json`:

```text
repository  neroued/Qwen3.8-27B-NInfer
revision    3526913004b1cf552cb57b88d6a5c6f5e4a89a70
filename    qwen3_8_27b.ninfer
bytes       18,210,531,328
container   v2
sha256      eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e
```

Download and verify in one step:

```powershell
.\scripts\download-qwen38-windows-sm75.ps1 -ModelDir "D:\AI\models\qwen"
```

To verify an existing file without downloading:

```powershell
.\scripts\download-qwen38-windows-sm75.ps1 -ModelDir "D:\AI\models\qwen" -VerifyOnly
```

## Model-free binary verification

This check does not need a GPU or model artifact. It audits every packaged PE dependency, rejects
a dynamic CUDA runtime import, requires non-system DLLs to be present beside the executables, then
launches both programs with PATH reduced to the package bin directory plus Windows system paths.
CI and release validation require `dumpbin.exe` so the dependency audit cannot silently skip:

```powershell
.\scripts\verify-windows-sm75.ps1 -RequireDependencyAudit
```

## Release package

```powershell
.\scripts\package-windows-sm75.ps1
```

The package step emits:

```text
dist/
├─ ninfer-windows-sm75-<git-sha>.zip
├─ ninfer-windows-sm75-<git-sha>.zip.sha256
├─ ninfer-windows-sm75-<git-sha>.zip.sbom.cdx.json
└─ ninfer-windows-sm75-<git-sha>/
   ├─ bin/
   │  ├─ ninfer.exe
   │  ├─ ninfer-serve.exe
   │  └─ *.dll
   ├─ START-HERE.bat
   ├─ README-FIRST.txt
   ├─ docs/
   │  ├─ windows-sm75.md
   │  └─ INSTALL-WINDOWS-SM75.md
   ├─ scripts/
   │  ├─ run-server-windows-sm75.ps1
   │  ├─ manage-installed-server.ps1
   │  ├─ healthcheck-windows-sm75.ps1
   │  ├─ smoke-test-windows-sm75.ps1
   │  ├─ acceptance-windows-sm75.ps1
   │  ├─ download-qwen38-windows-sm75.ps1
   │  ├─ verify-acceptance-evidence.ps1
   │  └─ verify-windows-sm75.ps1
   ├─ install/
   │  ├─ install-ninfer-sm75.ps1
   │  ├─ first-run-wizard.ps1
   │  ├─ verify-installation.ps1
   │  ├─ repair-ninfer-sm75.ps1
   │  └─ uninstall-ninfer-sm75.ps1
   ├─ launchers/
   │  ├─ Start-NInfer.bat
   │  ├─ Start-NInfer-MTP.bat
   │  ├─ Start-NInfer-Vision.bat
   │  ├─ Stop-NInfer.bat
   │  └─ Configure-NInfer.bat
   ├─ config/
   │  ├─ windows-sm75-artifacts.json
   │  ├─ windows-sm75-toolchain.json
   │  └─ production-defaults.json
   ├─ BUILD-MANIFEST.json
   ├─ BUILD-TOOLCHAIN.json
   ├─ SBOM.cdx.json
   ├─ SHA256SUMS.txt
   ├─ README.md
   └─ LICENSE
```

## Qwen3.8-27B production baseline

Use the registered `groupwise-int` artifact. Turing does not execute the Blackwell NVFP4 route.
Start conservatively with INT8 KV, one active request, 16K context, no speculative decoding, and
no Vision. Enable MTP and Vision only after the base text path is stable on the actual card.

```powershell
$env:NINFER_API_KEY = "replace-with-a-local-secret"
.\scripts\run-server-windows-sm75.ps1 `
  -Model "D:\AI\models\qwen\qwen3_8_27b.ninfer"
```

The launcher defaults to:

```text
host             127.0.0.1
port             8080
max-context      16384
kv-capacity      auto
kv-dtype         int8
max-concurrency  1
CUDA Graph       enabled
prefix reuse     enabled
MTP              disabled
Vision           disabled
```

It refuses a non-loopback bind unless an API key is configured **and** `-AllowInsecureRemote` is
passed explicitly. NInfer's built-in listener is plain HTTP; for real remote access use a TLS
reverse proxy, VPN, or SSH tunnel instead of exposing it directly. The production launcher passes
the secret through the `NINFER_API_KEY` process environment rather than `--api-key`, so the
credential is not exposed in the child process command line. The CLI flag remains supported for
backwards compatibility.

After startup:

```powershell
.\scripts\healthcheck-windows-sm75.ps1
```

The health check validates `/health` and `/v1/models`. For an authenticated server it automatically
uses `NINFER_API_KEY`, or pass `-ApiKey` explicitly.

### Enable MTP after text validation

```powershell
.\scripts\run-server-windows-sm75.ps1 `
  -Model "D:\AI\models\qwen\qwen3_8_27b.ninfer" `
  -EnableMtp -DraftTokens 3
```

### Enable Vision after text/MTP validation

```powershell
.\scripts\run-server-windows-sm75.ps1 `
  -Model "D:\AI\models\qwen\qwen3_8_27b.ninfer" `
  -Vision
```

## Hardware acceptance sequence

Production acceptance is bound to a concrete release ZIP. Package first, then run:

```powershell
$zip = Get-ChildItem .\dist -Filter "ninfer-windows-sm75-*.zip" | Select-Object -First 1
.\scripts\acceptance-windows-sm75.ps1 `
  -Model "D:\AI\models\qwen\qwen3_8_27b.ninfer" `
  -PackagePath $zip.FullName
```

The self-hosted workflow goes one step further: it expands that ZIP and runs the full acceptance
suite against the binaries extracted from the qualified package. The harness performs the
SM75/VRAM preflight, 8K smoke test, **needle-in-a-haystack semantic retrieval** near 8K/32K/64K,
OpenAI tool-call path validation, and deterministic **MTP0/MTP3 generated-token-ID parity**. The
evidence records the source Git SHA, pinned model SHA-256 and exact qualified ZIP filename/size/SHA-256.

Validate an evidence file independently with:

```powershell
.\scripts\verify-acceptance-evidence.ps1 `
  -EvidencePath .\acceptance\windows-sm75-<timestamp>.json `
  -ExpectedGitSha <exact-git-sha> `
  -PackagePath $zip.FullName `
  -LockPath .\config\windows-sm75-artifacts.json
```

The verifier requires RTX 2080 Ti / compute capability 7.5, at least 20,000 MiB reported VRAM,
NVIDIA driver branch R580+, the pinned model SHA-256, 8K/32K/64K semantic retrieval, MTP token parity,
and the tool-call path.

Native compile success is not proof of CUDA-kernel correctness. Final acceptance on the physical
RTX 2080 Ti should proceed in this order:

1. load Qwen3.8-27B and complete an 8K text generation;
2. verify INT8 KV cache and deterministic greedy output;
3. repeat at 32K and 64K context ceilings;
4. compare MTP0 output against the known-good route;
5. enable MTP3 and record acceptance rate, committed tok/s, TTFT, and VRAM;
6. validate OpenAI tool calls through `/v1/chat/completions`;
7. validate Vision last.

Do not claim 128K production support until the exact Windows package completes a representative
long-context run on the 22GB card without OOM, numerical failure, or unacceptable latency. The
production baseline remains 8K; 32K and 64K become supported only after the acceptance evidence
exists for the physical card.

## CI contract

`.github/workflows/windows-sm75.yml` runs on `windows-2022` and gates:

```text
VS2022 + CUDA 13.1 + sm_75
          ↓
build + install stage
          ↓
ninfer.exe --help / ninfer-serve.exe --help
          ↓
ZIP + SHA-256 + CycloneDX SBOM
          ↓
GitHub Actions artifact
```

CI deliberately performs no fake GPU inference. The hosted build has a 360-minute ceiling and uses
two compile jobs; the Qwen3.8-only profile avoids the previous multi-hour 35B GDN template
instantiations. Runtime correctness remains a hardware-acceptance item for the physical RTX 2080 Ti.

## Self-hosted RTX 2080 Ti acceptance workflow

After the workflow exists on the repository's default branch, register the physical Windows machine
as a GitHub self-hosted runner and add the custom runner label `sm75`. The runner must expose the
22GB RTX 2080 Ti and have the same VS2022/CUDA/CMake/Ninja prerequisites as the local build.

Run **RTX 2080 Ti SM75 hardware acceptance**. The workflow performs a clean production build,
packages and verifies it, expands that exact ZIP, runs the full semantic/MTP/tool-call acceptance
suite against the extracted binaries, independently verifies the ZIP-bound evidence, and uploads a
`ninfer-windows-sm75-qualified-<git-sha>` artifact containing the ZIP, SHA-256, CycloneDX SBOM and
hardware evidence. The qualification artifact is retained for 90 days.

## Publishing a release

The release workflow is intentionally manual and no longer accepts a human-only validation
checkbox. Run **Release Windows SM75** and provide:

- a semantic tag such as `windows-sm75-v0.1.0`; and
- the numeric run ID of a successful **RTX 2080 Ti SM75 hardware acceptance** workflow for the
  exact same Git commit.

The release workflow does **not** rebuild the runtime. It downloads the exact qualified artifact from
that run, machine-verifies the commit SHA, pinned model SHA-256, ZIP SHA-256, GPU identity, VRAM,
8K/32K/64K NIAH results, MTP token-ID parity and tool-call result, then re-runs package/dependency
verification on the same ZIP. It creates GitHub build-provenance and CycloneDX SBOM attestations
for that exact binary before publishing the ZIP, checksum, SBOM and hardware evidence.

Compile-only CI can never auto-publish a production release, and a different rebuild cannot be
substituted for the hardware-qualified bytes.
