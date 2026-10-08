# NInfer SM75 · loktoto Edition

**Local Qwen inference for RTX 2080 Ti 22GB — maintained by [loktoto](https://github.com/loktoto).**

A community-maintained, performance-oriented [NInfer](https://github.com/Neroued/ninfer) derivative focused on making a modified **NVIDIA RTX 2080 Ti 22GB** useful for local **Qwen3.8-27B** inference on Windows. The project's priorities are reliable installation, verifiable CUDA SM75 correctness, memory efficiency, and practical OpenAI-compatible local serving.

> **繁體中文：** 呢個係我哋維護嘅 RTX 2080 Ti 22GB / Qwen3.8-27B 本機 AI 專案。目標係 Windows 解壓即用、支援 API / MTP / Vision，並以真實 GPU 測試驗證效能。未完成硬件驗收前，唔會當佢係已推出嘅正式版。

[Windows development PR](https://github.com/loktoto/ninfer-2080ti-22g/pull/2) · [SM75 KV feature PR](https://github.com/loktoto/ninfer-2080ti-22g/pull/14) · [Project status](docs/PROJECT-STATUS.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## Release status — please read first

**There is no hardware-qualified Windows production release published as of 8 October 2026.** The default `master` branch contains the source baseline; the native Windows installer, pinned Qwen3.8 artifact and release workflow are being developed on [`windows-native-sm75`](https://github.com/loktoto/ninfer-2080ti-22g/tree/windows-native-sm75).

| Path | Availability | What it means |
| --- | --- | --- |
| Linux / WSL2 source build | Source available on `master` | Developer build; CUDA and toolchain required |
| Native Windows 10/11 x64 | [PR #2 — in development](https://github.com/loktoto/ninfer-2080ti-22g/pull/2) | Build and installer are not yet a verified production release |
| RK4V4E8 compressed KV cache | [PR #14 — opt-in, unmerged](https://github.com/loktoto/ninfer-2080ti-22g/pull/14) | Experimental branch feature, not a default |
| One-click Windows ZIP | [Releases](https://github.com/loktoto/ninfer-2080ti-22g/releases) | Use only an exact-SHA, physically qualified release when available |

Do **not** infer hardware support, model quality, 64K/128K context reliability, or tok/s from a successful hosted CI compile. [Qualification criteria](docs/PROJECT-STATUS.md) require the exact packaged binaries on a physical 22GB SM75 device.

## What we're building

- **Turing-first CUDA:** work on SM75 launch bounds, GEMM, GDN, paged attention and VRAM-aware execution.
- **27B on one modified card:** focus on Qwen3.8-27B `groupwise-int` artifacts and INT8/BF16 KV capacity planning.
- **Useful local API:** OpenAI- and Anthropic-compatible serving, local-only defaults, tool calls and request handling.
- **Optional MTP / Vision:** feature paths are qualified separately from a conservative Base text mode.
- **Simple Windows setup:** extracted ZIP → `START-HERE.bat` → integrity and GPU checks → pinned model verification → local server, once released.
- **Reproducible evidence:** exact model artifact lock, source/build provenance, SHA-256, package audit and real-card acceptance.

A modded 22GB card is **not** equivalent to a stock 11GB RTX 2080 Ti. The Windows profile targets **compute capability 7.5**, **at least 20,000 MiB of detected VRAM**, and a compatible NVIDIA driver; stock cards are not supported by that one-click profile.

## Getting started

### 1. Windows users — intended end-user path

**Not yet released.** When a qualified ZIP appears on the [Releases page](https://github.com/loktoto/ninfer-2080ti-22g/releases):

1. Download the matching Windows ZIP and its `.sha256` checksum.
2. Verify the ZIP checksum and extract **the complete archive**.
3. Double-click `START-HERE.bat` inside the extracted package.
4. Let the installer check the GPU, package and runtime prerequisites, and download/verify the exact pinned model.
5. Start with `launchers\Start-NInfer.bat`. Enable MTP or Vision only after Base works.

The planned native Windows runtime does **not** require Python, PowerShell 7, Visual Studio or a CUDA Toolkit on the end-user computer. Developer builds do need a pinned toolchain.

[Detailed Windows installation guide (development branch)](https://github.com/loktoto/ninfer-2080ti-22g/blob/windows-native-sm75/docs/INSTALL-WINDOWS-SM75.md) · [Native build/release runbook](https://github.com/loktoto/ninfer-2080ti-22g/blob/windows-native-sm75/docs/windows-sm75.md)

### 2. Linux / WSL2 — build from source

This is a **developer path**, not the one-click Windows product.

```bash
git clone https://github.com/loktoto/ninfer-2080ti-22g.git
cd ninfer-2080ti-22g
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=75
cmake --build build -j
```

You need a compatible NVIDIA CUDA toolchain, CMake 3.28+, Ninja, a C++20 compiler, and FFmpeg/libcurl development dependencies. Check the target and flags against the current source tree before building. Do not assume the Windows v2-only artifact lock applies automatically to other branches.

### 3. Local API integration

On the planned Windows package, Base mode binds to **`127.0.0.1:8080`** by default and generates a local API key in the installed application's protected secrets directory.

```text
OpenAI-compatible base URL: http://127.0.0.1:8080/v1
Health endpoint:           http://127.0.0.1:8080/health
Model discovery:           http://127.0.0.1:8080/v1/models
```

For Hermes, DeepSeek Harness and other OpenAI-compatible clients, use the actual model identifier returned by `/v1/models`, not a guessed alias. Keep the API key out of committed settings. The built-in listener uses plain HTTP: **never expose it directly to the public Internet**. See [Security](SECURITY.md) and [Serving](docs/serving.md).

## Model and artifact policy

The Windows development channel pins **Qwen3.8-27B, groupwise-int**, to one explicit NInfer **container-v2** model:

| Field | Windows development contract |
| --- | --- |
| Model repository | [neroued/Qwen3.8-27B-NInfer](https://huggingface.co/neroued/Qwen3.8-27B-NInfer) |
| Exact revision | `3526913004b1cf552cb57b88d6a5c6f5e4a89a70` |
| File | `qwen3_8_27b.ninfer` |
| Size | `18,210,531,328` bytes |
| SHA-256 | `eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e` |

These values come from the tracked [Windows artifact lock](https://github.com/loktoto/ninfer-2080ti-22g/blob/windows-native-sm75/config/windows-sm75-artifacts.json). Do **not** substitute the upstream “latest” artifact: newer container formats may not be compatible with this pinned Windows path. **Model files are downloaded separately** and are not included in the installer ZIP.

## Engineering and verification

| Gate | Required evidence |
| --- | --- |
| Source / CI | SM75 build, host-safe contracts and resource/compatibility checks |
| Windows distributable | Windows x64 build, package/DLL checks, PowerShell 5.1 installer checks, ZIP integrity and SBOM |
| Actual GPU | RTX 2080 Ti 22GB, pinned model, 8K smoke test, semantic 8K/32K/64K retrieval, tool calls and MTP parity |
| Public production release | Exact release SHA **and** the actual hardware-qualified ZIP, with machine-verifiable evidence |

The 8K/32K/64K figures are **test targets**, not published service-level guarantees. **128K remains experimental.** Earlier tuning measurements must not be represented as validated performance of the native Windows package. See [Project status](docs/PROJECT-STATUS.md) for the live PR/workflow links and release criteria.

## Documentation

- [Documentation index](docs/README.md)
- [Project status and release gates](docs/PROJECT-STATUS.md)
- [CLI guide](docs/cli.md) and [Serving/API guide](docs/serving.md)
- [Tests](tests/README.md) and [Benchmarks](bench/README.md)
- [Windows user guide on the feature branch](https://github.com/loktoto/ninfer-2080ti-22g/blob/windows-native-sm75/docs/INSTALL-WINDOWS-SM75.md)
- [Security and responsible disclosure](SECURITY.md)
- [Contributor guide](CONTRIBUTING.md)

## Maintainers, upstream credit and licensing

**This repository and its SM75/Windows integration work are maintained under [loktoto](https://github.com/loktoto).** It is a derivative of **[NInfer by Neroued](https://github.com/Neroued/ninfer)**, not the upstream project's official Windows release and not a claim of authorship over upstream source code.

We preserve existing [Apache License 2.0](LICENSE) terms, applicable original notices and attribution. [NOTICE](NOTICE.md) records the project relationship. Models and checkpoints remain the work of their respective creators and are subject to their own license terms. Modifications here are maintained by this fork's contributors.

**Project contact:** use [GitHub Issues](https://github.com/loktoto/ninfer-2080ti-22g/issues) for reproducible bugs and [Pull Requests](https://github.com/loktoto/ninfer-2080ti-22g/pulls) for code changes; use the [security policy](SECURITY.md) for vulnerabilities.
