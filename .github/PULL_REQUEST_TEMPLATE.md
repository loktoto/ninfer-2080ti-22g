## Scope

Explain the concrete problem and the user-visible behavior changed. State the intended branch (e.g., `master`, `windows-native-sm75`, or an explicitly stacked SM75 branch) and any dependencies.

## Design and compatibility

Explain the selected approach, affected model/artifact/API contracts, and why existing behavior remains correct. Maintain upstream Apache-2.0 notices and credit.

## Validation performed

| Check / command | Environment (OS, GPU, CUDA) | Result |
| --- | --- | --- |
| | | |

List any required but **not run** checks, with reasons. Never describe hosted CI as proof of physical RTX 2080 Ti numerical correctness.

## Release implications

- [ ] No unqualified performance, long-context or hardware support claims
- [ ] Relevant tests, documentation and installer/distribution contract are consistent
- [ ] No secrets, model binaries or private paths committed
- [ ] For Windows changes: PowerShell 5.1, package integrity and exact-model lock reviewed
- [ ] For publication: exact-SHA physical GPU acceptance and package evidence provided
