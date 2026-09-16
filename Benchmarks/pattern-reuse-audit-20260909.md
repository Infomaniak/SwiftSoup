# Pattern reuse: reconciled-source confirmation, September 9, 2026

## Source and scope

Baseline is reviewed master `7d2d58c6cb6dd1d2251eb9563a844b3d01718afe`, not the older optimization baseline. Candidate `9ee782e56aa9cfae51b24c3e0a3da02f8a8832ed` (tree `b4d6f44665f69fef3f4b8104304d96dc59bf0678`) merges the unchanged Pattern runtime/test change with that master. Only Pattern.swift changes at runtime. Portable Swift/Python tools are committed. Original PR #8 ancestry is retained; no forced update.

Pattern construction now compiles and retains its immutable regex/result. Reused matchers and repeated validation avoid recompilation. Invalid patterns still have nonthrowing construction, throwing validation and the old invalid-matcher diagnostic. Every Matcher retains independent eager matches and its own cursor. Ignored legacy options and capture-string semantics are unchanged.

## Native correctness

The source/test-identical predecessor `925a8e2b3848dbfd7ad024807acb8f697ae02b90` passed **1,065 total XCTest cases: 1,048 passed, 17 opt-in benchmarks skipped, zero failures**, in each of debug, release and AddressSanitizer on both Ubuntu and macOS, in run [34330228389](https://github.com/lake-of-fire/SwiftSoup/actions/runs/34330228389). ASan used `detect_leaks=0`; this is not leak checking. The later candidate changes only the benchmark runner, and the corrected workflow explicitly verifies Sources/Tests are identical.

The first run's overall status is red because its benchmark used an invalid library/client pairing. Do not call the whole first run green. Its test logs and failed benchmark are retained.

## Corrected measurement protocol

[Run 34331467924](https://github.com/lake-of-fire/SwiftSoup/actions/runs/34331467924) completed on both runners. Ubuntu uses Swift 6.3.3/x86_64; macOS uses Swift 6.1.2/arm64. Shipping libraries and public clients use optimization; libraries do not enable testing or library evolution. The exact same public client source is compiled **separately against each matching module/library**. Pattern's non-resilient struct layout changed, so loading the new library underneath an old-layout client was invalid. That first harness mistake was fixed, not represented as a product crash or accepted timing.

Each operation covers 256 inputs/patterns, except the parse control (64 paragraphs). Three in-process warmups. For each workload/host: eight alternating same-binary A/A pairs and twelve alternating A/B pairs in fresh processes. Common iteration counts are calibrated using both arms, targeting approximately 150 ms for the faster arm, capped at 4,096 iterations. Unused construction uses eight fixed iterations because its baseline is extremely short. Compilation and correctness suites finish before timing. Linux pins one available CPU; macOS has no affinity. No samples are discarded or pooled across hosts.

Percentages below are medians of within-pair ratios, not ratios of separate duration medians. Negative means less time. Checksums must match every pair. The benchmark checksum checks are narrower than the native behavioral suites and do not replace them.

| Workload | Ubuntu paired change | Faster pairs | macOS paired change | Faster pairs |
|---|---:|---:|---:|---:|
| Reused Pattern | -77.01% | 12/12 | -71.56% | 12/12 |
| Reused Pattern plus repeated validate | -86.64% | 12/12 | -84.28% | 12/12 |
| Fresh Pattern with one match | +0.46% | 2/12 | -0.17% | 6/12 |
| Parse/text control | +1.96% | 4/12 | +0.37% | 5/12 |

No general parse, Reader or one-use speedup is established. A/A reused-Pattern medians were +0.32% on Ubuntu and **+7.40% on macOS, 0/8 faster**. Other A/A medians range from -1.75% to +2.25%. The macOS control shows measurable host/order drift; the large reuse improvements exceed it, but these are not precision device estimates or confidence intervals.

### Real construction tradeoff

For 256 patterns constructed only to read their original string, baseline/candidate separate median durations were **0.0142/0.9541 ms on Ubuntu** and **0.0242/0.9759 ms on macOS**. Eager compilation is materially more expensive when never used. These very short baseline timings are not suitable for a precise multiplier claim. The compiled expression also remains alive with its Pattern. This tradeoff is intentional, not a universal optimization guarantee.

## Evidence integrity

Each host retains 210 process records: 200 A/A and A/B records plus ten calibrations; warmup operations are inside each process and excluded from elapsed timing. Across both hosts: 420 retained records. Library and both client SHA-256 values appear in each summary; raw records retain logical A/A role and actual loaded variant separately.

Downloaded artifact ZIP hashes, independently checked:

- `audit-pattern-matched-ubuntu-22.04`: `850f8ca61879faa4482f1836945734e869726b53e0bf647d818ced8de5d144f3`.
- `audit-pattern-matched-macos-15`: `c9d7d3ab18432c912bd8272238aef8f9552fc8e9fe54362df946a9e6ccd87666`.

Reproduce by building matching baseline/candidate libraries and matching clients from Tools/benchmark_pattern_reuse.swift, then invoking Tools/compare_pattern_reuse.py with --baseline-library, --candidate-library, --baseline-client, --candidate-client and a new --output directory. The driver refuses an existing output directory. Run normal SwiftPM tests separately. Final PR CI is a separate exact-head gate. No iOS device, full Reader, allocation-count or leak-freedom claim.
