# Native Windows build — RTX 2080 Ti 22GB (SM75)

This branch adds a native Windows/MSVC build path for the existing Turing SM75 port.

## Requirements

- Windows 10/11 x64
- NVIDIA driver supporting the installed CUDA Toolkit
- CUDA Toolkit 12.8 or newer
- Visual Studio 2022 Build Tools with Desktop development with C++, MSVC v143, and Windows SDK
- CMake 3.28+
- Ninja
- Git
- RTX 2080 Ti / TU102 (`sm_75`); the 22GB mod is recommended for Qwen3.8-27B residency

The build script bootstraps vcpkg automatically if `VCPKG_ROOT` is not set, then installs FFmpeg, libcurl, and pkgconf.

## Build

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\build-windows-sm75.ps1
```

Clean rebuild:

```powershell
.\scripts\build-windows-sm75.ps1 -Clean
```

If dependencies are already installed:

```powershell
.\scripts\build-windows-sm75.ps1 -SkipDependencies
```

The script configures `CMAKE_CUDA_ARCHITECTURES=75`, builds `ninfer.exe` and `ninfer-serve.exe`, and copies vcpkg runtime DLLs beside the executables.

## Qwen3.8 smoke test

Use a groupwise-int Qwen3.8 artifact. Turing does not support the NVFP4 execution path.

```powershell
.\build-windows-sm75\apps\ninfer.exe `
  D:\path\to\qwen3_8_27b.ninfer `
  --prompt "Reply with exactly: SM75 OK" `
  --max-context 8192 `
  --max-new 32 `
  --kv-dtype int8
```

Server:

```powershell
.\build-windows-sm75\apps\ninfer-serve.exe `
  D:\path\to\qwen3_8_27b.ninfer `
  --host 127.0.0.1 `
  --port 8080 `
  --max-context 16384 `
  --kv-dtype int8 `
  --kv-capacity auto `
  --max-concurrency 1
```

Then query `http://127.0.0.1:8080/v1/models` or the OpenAI-compatible `/v1/chat/completions` endpoint.

## Native-Windows portability changes

- WinSock headers and `ws2_32` linking for the media URL safety resolver.
- `localtime_s` on MSVC instead of POSIX `localtime_r`.
- `_getpid` instead of POSIX `getpid`.
- `_isatty(_fileno(stderr))` instead of POSIX `isatty(STDERR_FILENO)`.
- Platform-independent filesystem root-escape checking for Windows wide native paths.
- `NOMINMAX` and `WIN32_LEAN_AND_MEAN` are defined for Windows compilation.

## Validation sequence

The SM75 CUDA kernels already exist on `master`, including Turing-specific GDN/prefill fixes. Native Windows acceptance should be performed on a real RTX 2080 Ti in this order:

1. model load + 8K text smoke test;
2. INT8 KV cache test;
3. 32K and 64K context tests;
4. MTP0 token-parity test against the Linux/WSL2 build;
5. MTP3 acceptance-rate and throughput benchmark;
6. vision test after text stability is confirmed.

A compile-only machine can validate the MSVC/CUDA toolchain and host portability, but cannot prove kernel correctness or throughput without a Turing GPU.
