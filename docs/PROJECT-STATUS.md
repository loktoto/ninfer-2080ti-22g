# Project status · NInfer SM75 by loktoto

> Snapshot documented **2026-10-08**. This file is a roadmap and release-gate reference, not a live CI report. Check the linked GitHub pages for the latest actual status.

## Maintained product

- Owner / maintainer: [loktoto](https://github.com/loktoto).
- Source lineage: [NInfer by Neroued](https://github.com/Neroued/ninfer), modified under Apache-2.0.
- Target: modified NVIDIA RTX 2080 Ti with **22GB VRAM**, compute capability **7.5**, Windows 10/11 x64.
- Intended default workload: locally served Qwen3.8-27B, `groupwise-int`, with a pinned **v2** artifact in the Windows channel.
- Delivery: signed-off archive integrity, a simple installer, local-only API, optional MTP and Vision after Base-mode testing.

## Development map

| Workstream | Source of truth | Current release implication |
| --- | --- | --- |
| Native Windows runtime, installer, build and package | [PR #2](https://github.com/loktoto/ninfer-2080ti-22g/pull/2) · [Windows workflow](https://github.com/loktoto/ninfer-2080ti-22g/actions/workflows/windows-sm75.yml) | Needs full hosted package CI **and** physical-device qualification |
| Optional RK4V4E8 compressed KV path | [PR #14](https://github.com/loktoto/ninfer-2080ti-22g/pull/14) | Not part of the default Windows product; requires its own conformance gate |
| SM75 correctness / stacked integration | [PR #40](https://github.com/loktoto/ninfer-2080ti-22g/pull/40), [PR #41](https://github.com/loktoto/ninfer-2080ti-22g/pull/41) | Stacked merges must actually reach their root branch before a master merge |
| Windows installer regressions | [PR #42](https://github.com/loktoto/ninfer-2080ti-22g/pull/42), [PR #43](https://github.com/loktoto/ninfer-2080ti-22g/pull/43) | Fast PowerShell 5.1 and upgrade/rollback checks; do not replace full package testing |
| Published builds | [Releases](https://github.com/loktoto/ninfer-2080ti-22g/releases) | **No production release claimed until hardware evidence exists** |

## Acceptance and release contract

1. Complete native Windows `windows-2022` build against the exact source SHA; confirm `ninfer.exe`, `ninfer-serve.exe` and non-system runtime dependencies load.
2. Build a ZIP containing `START-HERE.bat`, launchers, scripts, pinned artifact lock, checksum manifest and SBOM; verify the **extracted** ZIP and PowerShell 5.1 path.
3. Run the package's binaries on a real **RTX 2080 Ti 22GB / SM75** with the exact pinned model: 8K smoke; semantic retrieval near 8K, 32K and 64K; required tool call; MTP0/MTP3 token-ID parity; observe memory and correctness.
4. Record machine-verifiable results tied to the **same commit and exact package SHA**. Treat benchmarks, long-context or quality claims as unqualified unless this evidence explicitly supports them.
5. Publish a production GitHub Release only after the self-hosted hardware workflow succeeds and the release workflow rechecks its artifact and evidence. Hosted Windows CI alone is insufficient.

**128K context is experimental.** GPU-less hosted compilation can validate syntax/build/link/package shape, not real-world inference, performance or quality.

## Supported paths and caution

- **Stock 11GB RTX 2080 Ti** is not the 22GB product target.
- Other GPUs, operating systems, checkpoint formats and model variants should not be advertised as verified by this Windows release process.
- `NINFER_QWEN38_ONLY=ON` intentionally excludes unrelated large model instantiations from the Windows release profile.
- Keep MTP, Vision, compressed KV and long-context extensions behind the supported baseline until each is independently qualified.
- Keep all published downloads checksum-verifiable and retain the upstream attribution and license.

## Where to start

- [Repository home](../README.md)
- [Windows install guide on active branch](https://github.com/loktoto/ninfer-2080ti-22g/blob/windows-native-sm75/docs/INSTALL-WINDOWS-SM75.md)
- [Windows build/release runbook on active branch](https://github.com/loktoto/ninfer-2080ti-22g/blob/windows-native-sm75/docs/windows-sm75.md)
- [Current Actions runs](https://github.com/loktoto/ninfer-2080ti-22g/actions)
- [Open pull requests](https://github.com/loktoto/ninfer-2080ti-22g/pulls)
