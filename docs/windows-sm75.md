# Native Windows production build — RTX 2080 Ti 22GB (SM75)

This branch provides the native Windows/MSVC product path for the Turing `sm_75` port.
The deliverable is a staged runtime plus a checksummed ZIP; WSL2 is not required.

## Supported production toolchain

- Windows 10/11 x64
- NVIDIA RTX 2080 Ti / TU102 (`sm_75`), including 22GB-mod cards
- Visual Studio 2022 Build Tools (v143) with Desktop development with C++ and Windows SDK
- CUDA Toolkit 12.8 or newer; CI validates CUDA 13.1 with VS2022
- CMake 3.28+, Ninja, Git
- Windows PowerShell 5.1+ or PowerShell 7 (both are CI-checked for packaged scripts)

The build script intentionally selects Visual Studio 2022. CUDA 13.1 rejects newer unsupported
MSVC toolsets; the production path does not use `-allow-unsupported-compiler`.

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
5. configures CMake for `CMAKE_CUDA_ARCHITECTURES=75`;
6. builds `ninfer.exe` and `ninfer-serve.exe`;
7. stages the product under `out\windows-sm75\bin` with required vcpkg runtime DLLs.

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

This check does not need a GPU or model artifact. It proves the packaged executables can load their
Windows DLL dependencies and reach their CLI parser:

```powershell
.\scripts\verify-windows-sm75.ps1
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
└─ ninfer-windows-sm75-<git-sha>/
   ├─ bin/
   │  ├─ ninfer.exe
   │  ├─ ninfer-serve.exe
   │  └─ *.dll
   ├─ docs/windows-sm75.md
   ├─ scripts/
   │  ├─ run-server-windows-sm75.ps1
   │  ├─ healthcheck-windows-sm75.ps1
   │  ├─ smoke-test-windows-sm75.ps1
   │  ├─ acceptance-windows-sm75.ps1
   │  ├─ download-qwen38-windows-sm75.ps1
   │  └─ verify-windows-sm75.ps1
   ├─ config/windows-sm75-artifacts.json
   ├─ BUILD-MANIFEST.json
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

Run the automated acceptance harness first:

```powershell
.\scripts\acceptance-windows-sm75.ps1 -Model "D:\AI\models\qwen\qwen3_8_27b.ninfer"
```

It performs the SM75/VRAM preflight, 8K smoke test, token-counted long-prefill probes at 8K/32K/64K,
OpenAI tool-call path validation, and deterministic MTP0/MTP3 parity. It writes a JSON evidence
record plus server diagnostics under `acceptance\`.

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
ZIP + SHA-256 package
          ↓
GitHub Actions artifact
```

CI deliberately performs no fake GPU inference. Runtime correctness and performance remain a
hardware acceptance item for the real RTX 2080 Ti.

## Publishing a release

The release workflow is intentionally manual. Run **Release Windows SM75** from GitHub Actions,
provide a semantic tag such as `windows-sm75-v0.1.0`, and confirm the hardware-validation checkbox.
The workflow rebuilds from source, verifies executable startup, regenerates checksums, and publishes
the ZIP only after that explicit physical-GPU acceptance gate. Compile-only CI never auto-publishes
a production release.
