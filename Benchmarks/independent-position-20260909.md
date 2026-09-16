# Element sibling-position lookup

## Scope

Independent master-based change on `5d593583469c49d3c84449f28251b4cf201042a8`. Only `Sources/Element.swift` changes at runtime: 19 additions and one deletion in `elementSiblingIndex()`. This is distinct from the existing adjacent-sibling navigation and sibling reindexing work. No cache, persistent state, public API, parser default, dependency pin, or other worker's branch changes.

Built-in parents previously materialized the complete filtered `Elements` list before finding one element's index. Count directly through their child nodes and stop at the target instead. Exact Element, Document and FormElement parents take this path. Custom parent/children/array projections keep the old path. The original two parent() calls, nil-second-result error, zero for absent membership, and independence from stale public siblingIndex values are preserved.

This remains O(n) for one lookup and O(n²) for all positions in a wide parent. It removes unnecessary allocations and scanning, not the asymptotic cost of every structural selector.

## Isolated release confirmation

Reference: already-optimized PR #3 source `c9c37c80eb571aabba59a1f3ef31af9b072af4a8`. Candidate: that exact source plus only this runtime change. These first-table numbers are not measurements against master.

Linux x86_64, Swift 6.2.1, shipping libraries built with `-O -g -whole-module-optimization`, without `-enable-testing`. One identical separately compiled public client per comparison pair. CPU affinity 0, three warmups, fresh processes, randomized workload order, eight balanced ABBA/BAAB blocks: 16 processes per revision per workload, targeting 250 ms of work in the faster revision with equal iteration counts. No compilation, tests, or profiling during timing. Geometric-mean milliseconds per operation; exploratory paired-block 95% t intervals on log ratios, without multiple-comparison adjustment. No observations discarded.

| Public workload | Reference ms | Candidate ms | Less time | 95% interval |
|---|---:|---:|---:|---:|
| All positions of 256 sibling elements | 1.996053 | 0.103813 | 94.80% | 94.49–95.09% |
| Positions with intervening text/comments | 2.279398 | 0.297094 | 86.97% | 86.51–87.40% |
| Uncached nth-child selection, 256 paragraphs | 2.452187 | 0.409174 | 83.31% | 82.62–83.98% |
| Parse 128 paragraphs plus nth-child selection | 1.685411 | 1.153848 | 31.54% | 29.58–33.44% |
| Custom-parent fallback control | 0.927815 | 0.916840 | 1.18% | -5.01–7.01% |
| Parse/text control | 1.141513 | 1.128082 | 1.18% | -3.26–5.42% |

An earlier independent four-block, 120 ms screening run is retained separately, not pooled into this confirmation. Selection uses public Collector/evaluator traversal, not warmed string-query results. The parsing row includes parsing, selection and normal lifetime costs; it is not a parser-only gain.

## Confirmation against newly advanced master

Reference: `5d593583469c49d3c84449f28251b4cf201042a8`. Candidate: that exact source plus BOTH this patch and the separate slash-free CSS cleaning patch. This is a combined confirmation, not an isolated attribution. A new public client was compiled once against the current baseline, then held identical across this pair. Same eight-block/250 ms protocol.

| Workload | Reference ms | Combined ms | Less time | 95% interval |
|---|---:|---:|---:|---:|
| All positions of 256 sibling elements | 2.111733 | 0.110034 | 94.79% | 93.99–95.49% |
| Mixed sibling positions | 2.252929 | 0.306312 | 86.40% | 86.07–86.73% |
| Uncached nth-child selection | 2.375669 | 0.392831 | 83.46% | 82.98–83.93% |
| Parse plus nth-child selection | 1.794774 | 1.276510 | 28.88% | 25.83–31.80% |
| Custom-parent fallback control | 0.922212 | 0.913415 | 0.95% | -0.86–2.74% |
| Parse/text control | 1.240496 | 1.219517 | 1.69% | -3.12–6.28% |

Every interval in both six-block, 200 ms position A/A matrices spans zero. The companion CSS study did have a false-positive identical-binary control; its longer recheck spans zero. This is a noisy shared host. Do not infer device-level precision, a universal parser speedup, or whole-Manabi performance. Fixtures are synthetic, not measured production traffic; no Apple/iPhone performance was measured.

## Correctness and publication

Nine new regression methods cover mixed nodes/widths, stale indexes, detached and missing membership, built-in document/form parents, custom children and array projections, stateful parent callbacks, reparenting/deep copies, and warmed selectors after mutation. They pass against unchanged production as compatibility guards. No existing tests were weakened.

- Original PR #3 release: 806 cases, 17 optional benchmarks skipped, zero failures.
- Unchanged PR #3 plus both new test files: 821 cases, 17 skipped, zero failures. Combined candidate: the same in local debug and release.
- Newly advanced master plus both test files but unchanged production: native Swift 6.1.3 release, 1,080 cases, 17 skipped, zero failures.
- This independent master-based production/test tree: native Swift 6.1.3 release, 1,074 cases, 17 skipped, zero failures (1,057 passed).
- Master plus both runtime patches: local Swift 6.2.1 full DEBUG AddressSanitizer suite, 1,080 cases, 17 skipped, zero failures. `ASAN_OPTIONS=detect_leaks=0`; not leak checking and not a release-ASan claim.

Native publication run: https://github.com/lake-of-fire/SwiftSoup/actions/runs/34335351288 . Its first attempt stopped before testing because Python was missing from the container; the successful retry installed it. Source preparation verified exact runtime/test SHA-256 values before tests and non-force publication. All 217 files in this initial published tree were independently checked against local inputs and Git blob hashes. Subsequent additions are only this report and the two already-used benchmark tools.

The old reference, its two isolated candidates, its combined candidate, current master and current combined candidate all match 2,108 complete public-observation records byte-for-byte: positions, selections, later mutation, HTML/text, CSS filtering and cleaned-document outputs. SHA-256: `204a9bfdfa9f50a4789b7ce2f0946be5ae482269a6ec9abec7ec2b7ab853c775`. These are records, not 2,108 independent bugs or a claim of browser equivalence.

The full two-candidate study retains 1,760 timed fresh processes across 11 stages, excluding calibration and correctness launches. Every checksum and aggregate was independently recomputed. Aggregate JSON SHA-256: `067a43e72434b422f505444267777a594bb8aa9b66e18f259a798d920915218b`.

## Reproduction

Run native project tests with `swift test -c release`. For the isolated timing study, apply only this runtime diff to the PR #3 reference above. For the current-master confirmation, apply both runtime diffs to the stated current master. Keep source revisions and clients matched within each pair.

Example Linux shipping-library build, executed separately in each source directory:

```sh
mkdir -p shipping
swiftc -swift-version 6 -O -g -whole-module-optimization \
  -emit-library -emit-module -module-name SwiftSoup \
  -emit-module-path shipping/SwiftSoup.swiftmodule \
  -o shipping/libSwiftSoup.so Sources/*.swift
```

Compile one client against the reference library, then compare:

```sh
swiftc -swift-version 6 -O -I /reference/shipping -L /reference/shipping \
  -lSwiftSoup Tools/benchmark_independent_hotspots.swift -o /tmp/hotspots
python3 Tools/compare_independent_hotspots.py --client /tmp/hotspots \
  --baseline-library /reference/shipping --candidate-library /candidate/shipping \
  --suite position --output /tmp/new-position-results --blocks 8 --ms 250
```

Python requires NumPy and SciPy. Repeat with `--aa` and a different output directory. The runner verifies complete nonempty outputs before timing, controls Linux library loading/CPU affinity, checks all timed checksums, and retains calibration, every trial, binary identities and intervals. Never build or profile concurrently. Raw evidence, exact source snapshots, patches and complete test logs accompany the delivery archive.
