# Security policy · NInfer SM75

Maintained by [loktoto](https://github.com/loktoto). This is an independently maintained NInfer derivative; it is not an official upstream NInfer or Qwen security advisory channel.

## Supported versions

The Windows SM75 product is **under development** and has no hardware-qualified production release as of **2026-10-08**. No currently published production-version support window is claimed.

## Report a vulnerability

**Do not publish working exploits, user API keys or private tokens in a public issue.** If GitHub's private vulnerability reporting is enabled for this repository, use the repository's **Security → Report a vulnerability** flow. Otherwise, report minimal non-sensitive details in an issue asking the maintainer to establish a private disclosure channel first.

Provide the affected commit, OS, GPU, reproduction environment, expected/actual security behavior and a sanitized reproducer. Never attach real model credentials or another user's private logs.

## Safe deployment defaults

- Bind to **127.0.0.1** only unless the deployment has an independently secured TLS proxy, SSH tunnel or VPN.
- Do not expose the built-in plain-HTTP inference listener directly on the public Internet.
- Keep the generated API key in its protected local file; never commit it or pass it via a public command line.
- Verify release checksums and the exact artifact lock before running unknown packages.
- Restrict access to the Windows install directory and machine; a local API is not a multi-tenant authorization boundary.
- Treat remotely supplied images, prompts, tool calls and downloaded model artifacts as untrusted inputs where applicable.

## Upstream dependencies

The upstream [NInfer project](https://github.com/Neroued/ninfer), NVIDIA software, FFmpeg, libcurl, Qwen model authors and package managers have their own security reporting processes. This fork's maintainer can address issues in its own code and packaging, but cannot issue upstream security guarantees.
