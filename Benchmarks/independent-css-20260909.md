# Slash-free inline CSS cleaning

## Scope

Independent master-based change on `5d593583469c49d3c84449f28251b4cf201042a8`. Only `Sources/Whitelist.swift` changes at runtime: three added lines at the start of private stripCSSComments. Existing regex compilation, entity escaping, and whitespace-normalization work is not duplicated. No public API, cache, persistent state, sanitizer policy, dependency pin, or other worker's branch changes.

A CSS comment cannot start without an ASCII slash. When the UTF-8 view contains none, return the existing String rather than rebuilding it Character by Character. Any slash, including a quoted slash or a late slash that is not a comment, retains the entire original quote/escape-aware scanner. Property filtering and unsafe-value checks still run. Unicode slash lookalikes do not become comment delimiters.

Tradeoff: slash-containing input incurs an additional scan up to its first slash. A long late-slash control is included explicitly. This is not a claim that all CSS or all cleaning becomes faster.

## Isolated release confirmation

Reference: already-optimized PR #3 source `c9c37c80eb571aabba59a1f3ef31af9b072af4a8`. Candidate: that exact source plus only this runtime change. These first-table numbers are not measurements against master.

Linux x86_64, Swift 6.2.1; shipping `-O -g -whole-module-optimization` libraries without `-enable-testing`; one identical separately compiled public client per comparison pair. CPU affinity 0, three warmups, fresh processes, randomized workload order, eight balanced ABBA/BAAB blocks: 16 processes per revision per workload. Target 250 ms in the faster revision, using equal iteration counts. Compilation, tests and profiling were excluded from timing. Geometric-mean milliseconds per operation; exploratory paired-block 95% t intervals on log ratios, without multiple-comparison correction. Every observation retained.

| Public workload | Reference ms | Candidate ms | Less time | 95% interval |
|---|---:|---:|---:|---:|
| Sanitize 64 short style values | 3.117449 | 2.844915 | 8.74% | 6.59–10.84% |
| Sanitize 64 long Unicode style values | 18.401358 | 13.572643 | 26.24% | 24.77–27.69% |
| Long values with a late slash | 12.041063 | 12.105335 | -0.53% | -2.55–1.44% |
| Actual-comment control | 2.460368 | 2.431834 | 1.16% | -4.63–6.63% |
| Clean and regenerate 64 styled paragraphs | 4.050292 | 3.720846 | 8.13% | 5.71–10.50% |
| Parse, clean and regenerate styled document | 4.643244 | 4.359176 | 6.12% | 0.51–11.41% |
| Clean document without styles | 0.615912 | 0.596120 | 3.21% | -2.34–8.47% |

The earlier independent four-block, 120 ms screen is retained separately, not pooled. Long Unicode strings deliberately expose reconstruction work; their prevalence in production traffic was not measured. Cleanup uses public Cleaner and regenerated HTML, not a private helper-only benchmark or shallow-copy substitution.

## Confirmation against newly advanced master

Reference: `5d593583469c49d3c84449f28251b4cf201042a8`. Candidate: that exact source plus BOTH this patch and the independent sibling-position patch. This is a combined confirmation, not isolated attribution. A new client was compiled once against the current reference, then kept identical for the pair. Same eight-block/250 ms protocol.

| Public workload | Reference ms | Combined ms | Less time | 95% interval |
|---|---:|---:|---:|---:|
| Short styles | 3.064962 | 2.827195 | 7.76% | 5.24–10.21% |
| Long Unicode styles | 18.382911 | 13.342432 | 27.42% | 26.83–28.00% |
| Late-slash control | 11.672791 | 11.894930 | -1.90% | -6.30–2.31% |
| Actual-comment control | 2.402561 | 2.392114 | 0.43% | -1.34–2.17% |
| Clean styled document | 4.004747 | 3.718265 | 7.15% | 5.20–9.06% |
| Parse and clean styled document | 4.604337 | 4.281462 | 7.01% | 3.88–10.05% |
| Clean document without styles | 0.633303 | 0.623906 | 1.48% | -3.42–6.16% |

## Noise and limits

The initial six-block, 200 ms A/A matrix had one false positive: identical binaries made style-free cleaning appear 2.89% faster, interval 1.23–4.52%. The independent 12-block, 400 ms recheck gives -0.40%, interval -2.64–1.80%; its late-slash control is -0.83%, interval -2.49–0.80%. All intervals in the separate current-master A/A matrix span zero. All initial and repeat records are retained.

Do not interpret small control differences as speedups. This shared host is noisy and the intervals do not establish device-level precision. No overall Manabi, universal parser, Apple-device, or iPhone performance claim. No allocation counts or profiler-derived timing claim.

## Correctness and publication

Six new regression methods cover unchanged property filtering/normalization, byte-preserved Japanese/combining/emoji/quoted content, slash-free unsafe values, comments and unterminated comments, 512 seeded cases compared with the original scanner forced by a removable comment prefix, and repeated rule changes without input mutation. No existing tests were weakened.

- Original PR #3 release: 806 cases, 17 optional benchmarks skipped, zero failures.
- Unchanged PR #3 plus both new test files: 821 cases, 17 skipped, zero failures. Combined candidate: the same in local debug and release.
- Current master plus both test files but unchanged production: native Swift 6.1.3 release, 1,080 cases, 17 skipped, zero failures.
- This independent master-based production/test tree: native Swift 6.1.3 release, 1,071 cases, 17 skipped, zero failures (1,054 passed).
- Master plus both runtime patches: local Swift 6.2.1 full DEBUG AddressSanitizer suite, 1,080 cases, 17 skipped, zero failures. `ASAN_OPTIONS=detect_leaks=0`; not leak checking or a release-ASan claim.

Native publication run: https://github.com/lake-of-fire/SwiftSoup/actions/runs/34335351288 . An earlier attempt stopped before testing because the container lacked Python; the successful retry installed it. Runtime/test SHA-256 values were checked before testing and non-force branch publication. All 217 files in the initial published tree were independently checked against local inputs and Git blob hashes. Subsequent additions are only this report and the two already-used benchmark tools.

The old reference, both isolated candidates, old combined candidate, current master and current combined candidate all match 2,108 complete public-observation records byte-for-byte, including CSS results, unchanged inputs, cleaned documents, structural selectors, mutation and regenerated HTML/text. SHA-256: `204a9bfdfa9f50a4789b7ce2f0946be5ae482269a6ec9abec7ec2b7ab853c775`. These records are not independent bugs or browser-equivalence checks.

The complete two-candidate study retains 1,760 timed fresh processes across 11 stages, excluding calibration/correctness launches. Every timed checksum and aggregate was independently recomputed. Aggregate JSON SHA-256: `067a43e72434b422f505444267777a594bb8aa9b66e18f259a798d920915218b`.

## Reproduction

Use `swift test -c release` for native tests. For isolated timing, apply only this runtime diff to the stated PR #3 reference; for current-master confirmation, apply both runtime diffs to the stated master. Keep clients and source revisions matched within each comparison pair.

Example Linux shipping-library build in each separate source directory:

```sh
mkdir -p shipping
swiftc -swift-version 6 -O -g -whole-module-optimization \
  -emit-library -emit-module -module-name SwiftSoup \
  -emit-module-path shipping/SwiftSoup.swiftmodule \
  -o shipping/libSwiftSoup.so Sources/*.swift
```

Compile one client against the reference and compare:

```sh
swiftc -swift-version 6 -O -I /reference/shipping -L /reference/shipping \
  -lSwiftSoup Tools/benchmark_independent_hotspots.swift -o /tmp/hotspots
python3 Tools/compare_independent_hotspots.py --client /tmp/hotspots \
  --baseline-library /reference/shipping --candidate-library /candidate/shipping \
  --suite css --output /tmp/new-css-results --blocks 8 --ms 250
```

Python requires NumPy/SciPy. Repeat with `--aa` into another fresh directory. The runner compares complete nonempty outputs before timing, checks every checksum, controls Linux affinity/library loading, and saves calibration, raw trials, binary identities and intervals. Never compile or profile during timing. Exact sources, patches, raw timing records and test logs accompany the delivery archive.
