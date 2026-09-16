# Batch pass-through Unicode runs during entity escaping

The UTF escaping helper used to invoke the internal buffer writer for every non-ASCII sequence. It now copies adjacent pass-through sequences together. ASCII replacements, NBSP replacements, custom public replacement callbacks and their order are unchanged. It stops at the same byte boundaries and retains the historical permissive lead-byte stepping for malformed/truncated bytes; it does not silently replace that with a validating UTF-8 decoder. No new cache, state, public API, or normalization policy.

Six new regression methods include an independent byte oracle, 2,048 seeded malformed byte strings, every byte lead at truncation boundaries, combining marks and emoji, base/extended/XHTML, UTF-8/UTF-16 output settings, attribute/text contexts, array/offset-array/Data/nonzero-index-Data/pointer storage, builder aliases and retained snapshots, custom append callbacks, normalization controls, and source-less regenerated HTML.

### Independent confirmation

Target 500 ms timed work per process, fixture size 128. `escape-japanese` contains long continuous Japanese runs plus a required escape. `escape-mixed` interleaves Japanese, ASCII, emoji, combining marks, NBSP and markup. `serialize-japanese` regenerates a source-less 128-paragraph document with text and title attributes; it does not reuse original HTML source. These synthetic inputs expose the helper, not a measured traffic distribution.

| Workload | Reference ms | Candidate ms | Less time | 95% interval |
| --- | ---: | ---: | ---: | ---: |
| escape-japanese | 0.020657 | 0.011167 | +45.94% | +44.59 to +47.26% |
| escape-mixed | 0.036759 | 0.030078 | +18.17% | +14.68 to +21.52% |
| serialize-japanese | 0.242221 | 0.150415 | +37.90% | +36.56 to +39.22% |
| escape-plain | 0.004125 | 0.004108 | +0.41% | -2.43 to +3.17% |

### Small/ASCII control confirmation

Twelve blocks at target 500 ms; an initial median suggested a small ASCII slowdown, but neither the longer repeat nor its A/A control establishes one. Already-safe strings keep their pre-existing no-escaping fast path.

| Workload | Reference ms | Candidate ms | Less time | 95% interval |
| --- | ---: | ---: | ---: | ---: |
| escape-ascii | 0.015277 | 0.015022 | +1.67% | -0.75 to +4.02% |
| escape-short | 0.000313 | 0.000310 | +1.10% | -0.85 to +3.01% |

## Scope and exact reference

Independent change on fork master `cb57c9e160da093c7dd87eb91d335b6891d0efb7`. The numerical study instead compares the already-optimized PR #3 at `c9c37c80eb571aabba59a1f3ef31af9b072af4a8` with that exact production tree plus only this change. The reference Sources Git tree is `98e22c134afa5144fe64565f448260239545f90f`. Both revisions have identical original `Entities.swift`, blob `9a8e292e58323cedb86e834cc24c8bf14af89739`.

PRs #1–#7 were audited by scope and changed-file lists; none changes Entities. A later recheck included the new regex PR #8, which changes Pattern, not Entities. No existing PR head, master, dependency pin, source-range setting, or parser default was changed. This does not incorporate or supersede the selector/ownership correctness stack.

The two entity PRs change different helpers and are independently reviewable against master. Their two Tools files are intentionally byte-identical, so they share one portable harness after merging either order.

## Measurement protocol

Swift 6.2.1, Linux x86_64, CPU 0 affinity, `-O -g -whole-module-optimization -swift-version 6` shipping libraries **without `-enable-testing`**. One identical optimized public client dynamically loads each library. Fixture setup, compilation, full-output verification, sanitizer tests and profiling are outside timed intervals. Three in-process warmups precede each timed loop. Hashing is randomized normally; it is not made deterministic for timing.

Confirmation uses 12 balanced ABBA/BAAB blocks: **24 fresh processes per revision per workload**. Each block averages the two log times per revision; the table reports geometric-mean milliseconds per operation and a paired-block Student t 95% interval for the log time ratio, transformed to percent less time. Positive means faster. These are exploratory intervals without multiple-comparison correction, not predictions for another machine or production traffic. Wall and process CPU values, calibrations, all raw process records and exact command/library/client/source hashes are retained. No sample/outlier is deleted.

The initial screen (six blocks, 12 processes per revision per workload) is retained separately rather than pooled selectively into confirmation. Targeted and ASCII A/A controls use eight blocks; Reader A/A uses six. All wall-clock A/A intervals include zero; the multipoint-entity A/A interval is especially wide because randomized dictionary ordering affects the baseline linear scan. This uncertainty is not hidden.

## Reader controls: no general application claim

Both entity changes together were also compared with unchanged PR #3 in eight balanced blocks, 16 fresh processes per revision per workload, target 400 ms per process, retained medium/byte-input Reader fixtures. Proper deep-copy injection is measured; shallow-copy paths are only equality sentinels. These SwiftSoup-side replays exclude morphology, Realm/dictionary I/O, WebKit, and UI.

| Workload | Reference ms | Candidate ms | Less time | 95% interval |
| --- | ---: | ---: | ---: | ---: |
| manabi-parse | 3.745240 | 3.801148 | -1.49% | -4.53 to +1.46% |
| manabi-injection-deep | 23.271460 | 22.932565 | +1.46% | -1.36 to +4.19% |
| manabi-ruby | 5.326387 | 5.349208 | -0.43% | -1.70 to +0.83% |
| manabi-inner | 0.018072 | 0.017880 | +1.07% | -0.89 to +2.98% |

Every Reader interval spans zero. No overall Reader speedup, universal parser gain, Apple-device performance result, or iPhone result is claimed. The two successful helper-specific results do not change that conclusion.

## Behavioral verification

On the exact PR #3 build inputs, the unchanged reference plus both new test files passes the native release suite: **818 cases, 801 passed, 17 opt-in benchmarks skipped, zero failures**. Each isolated candidate plus its own six new tests passes **812 cases, 795 passed, 17 skipped, zero failures**. The new tests also pass against unchanged production source: these are behavior-preserving optimizations, not correctness fixes. No existing test was removed or weakened.

All four shipping variants (reference, escaping only, lookup only, both) match **9,408 full DOM records**, **4,608 contextual-fragment records**, and **72 nonempty Reader output sets** byte-for-byte. DOM output SHA-256: `c243b0307f2fbfaeb781bd5786ac51e9e66f659c165b9f33f1590345416b6ca1`; fragment output SHA-256: `1c582c7608ddef757b25c57b270e4e63460a21a871025db35dcb60edf5585a98`.

The inherited Reader parse-only observer emitted an empty array, so six of its nominal 72 sets did not observe a parsed result. A separate verification-only client now records regenerated HTML and text for parse-only (and ruby-parse), rejects empty output, and was run across all variants. **The timed Reader client was not changed.** This correction is evidence tooling, not a change to another worker's production PR or retrospective validation of its historical results.

The combined production candidate also passes the complete native AddressSanitizer release suite: **818 cases, 801 passed, 17 skipped, zero failures**, with `ASAN_OPTIONS=detect_leaks=0`. This is not a leak check.

Native CI for the master-based PR is a separate check, not the source of the above PR #3 integration counts. See the PR's checks for the exact published head. ASan results, when reported, use `detect_leaks=0` and do not establish leak freedom.

## Portable reproduction

The committed public client is the exact source used for final entity confirmation. The committed Python runner applies the same comparison protocol with configurable paths; it is not a copy of the study's machine-specific orchestration paths.

To repeat the exact measured reference, make two detached worktrees at `c9c37c80eb571aabba59a1f3ef31af9b072af4a8`, then apply **only this PR's `Sources/Entities.swift` diff from master** to the candidate. Do not include the other entity change in an isolated comparison. To measure master itself instead, use two master-based worktrees and label that a new experiment.

With `BASE` and `CANDIDATE` pointing to those worktrees, and `OUT` an absolute new build directory:

```sh
mkdir -p "$OUT/base" "$OUT/candidate"
ext=so
[ "$(uname -s)" = Darwin ] && ext=dylib
for variant in base candidate; do
  root="$BASE"
  [ "$variant" = candidate ] && root="$CANDIDATE"
  swiftc -swift-version 6 -O -g -whole-module-optimization \
    -emit-library -emit-module -module-name SwiftSoup "$root"/Sources/*.swift \
    -emit-module-path "$OUT/$variant/SwiftSoup.swiftmodule" \
    -o "$OUT/$variant/libSwiftSoup.$ext"
done
swiftc -O -g -I "$OUT/base" -L "$OUT/base" -lSwiftSoup \
  Tools/benchmark_entities.swift -o "$OUT/benchmark-entities"
```

Run the command below, then repeat with `--aa` and a **different** output prefix. The runner pins an allowed CPU on Linux and records lack of affinity on macOS. It compares complete public outputs before timing, checks timed checksums, and refuses to overwrite an existing run. Never time concurrently with compilation, sanitizer runs or a profiler. Host-specific path/binary hashes will necessarily differ from this study.

```sh
python3 Tools/compare_entity_benchmarks.py \
  --baseline-library "$OUT/base" --candidate-library "$OUT/candidate" \
  --client "$OUT/benchmark-entities" --blocks 12 --ms 500 --size 128 \
  --workloads escape-japanese escape-mixed serialize-japanese escape-plain escape-ascii escape-short \
  --output "$OUT/escape-ab"
# Repeat with --aa and --output "$OUT/escape-aa".
```

Normal project correctness checks remain `swift test -c release` and, where supported, `ASAN_OPTIONS=detect_leaks=0 swift test -c release --sanitize address`. The benchmark does not change Package.swift or add dependencies.

## Measured artifact identities

- Reference library SHA-256: `97486712c374feabf95d22d9ae8564ee427e80e210388bee7bf963231ada16f9`
- Candidate library SHA-256: `8224610433f55df4fa9d408d02a750dcbc5de43f8e0cc503d3826e42aa06c99f`
- Identical final client SHA-256: `22672ec15224612f36814f41a8ac792c7d24c550f903f66da8c2b15cb9e51154`
- Candidate Entities Git blob: `8dc30c59cabd7d9156a5bab3e92539e0682ec93d`
- Runtime patch SHA-256: `e7d0ee7f5df9441a37397ed089ee0bcbc54504b8f061a17a2f519b2c27928e71`

Complete raw screen/confirmation/A/A records, CPU results, calibration records, fixture and source manifests, failed/neutral observations, exact source snapshots, test logs and complete output sets are retained in the companion delivery bundle. Do not substitute an earlier other-worker report for this experiment.
