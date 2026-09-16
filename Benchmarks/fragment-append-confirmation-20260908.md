# Fragment-append confirmation — September 8, 2026

This is a fresh confirmation of the published changes, not a replacement for the earlier study or a claim that its entire raw archive is reproduced here.

## Exact revisions

- Baseline: `79c79cc99249e45e51f36f574eab28241c40197c` (already contains the preceding DOM primitive optimizations).
- Upstream-ready candidate: `37f5f85d45e594b96b55fea279b90161a90968a0` on `perf/dom-primitives-upstream-20260908`.
- Fork integration: `0bd3cb4ad29d79820ffe6c2dbe9d0706359962dc` on `perf/dom-primitives-20260908`, PR #3.

The incremental runtime change is six additions and nine deletions across Attribute, TextNode and DataNode: append directly to the optional fragment array instead of making an additional array value, appending, and assigning it back. Cache invalidation, mutation tokens, accumulated lengths, and materialization order remain unchanged. The fork integration preserves the older runtime stack and upstream's escaped-ID fix. No parser option is changed; in particular, source-range tracking is not disabled by these optimizations.

## Portable A/B repeat

Swift 6.2.1, Linux x86_64; optimized standalone XCTest clients and release libraries (`-O -g -whole-module-optimization -enable-testing` for libraries). CPU affinity pinned to 0. Compilation, behavioral checks and timing were separate. Each operation uses the exact committed FragmentAppendBenchmarkTest source, 256 fragments, 1,000 timed iterations, three warmups, six balanced ABBA/BAAB blocks, and 12 fresh processes per revision. No outliers were removed.

Geometric-mean milliseconds per operation; positive percentages mean less time. Intervals are exploratory paired-block 95% t intervals on log time ratios, without multiple-comparison adjustment. They do not represent other machines or production traffic.

| Operation | Baseline ms | Candidate ms | Less time | 95% interval |
|---|---:|---:|---:|---:|
| attribute | 0.260973 | 0.025893 | +90.1% | +89.6 to +90.5% |
| data | 0.261975 | 0.021965 | +91.6% | +91.2 to +92.0% |
| parse-attribute | 0.101143 | 0.102085 | -0.9% | -5.7 to +3.7% |
| parse-coalesced | 0.701111 | 0.419226 | +40.2% | +37.7 to +42.6% |
| parse-discarded | 0.559111 | 0.553148 | +1.1% | -0.8 to +2.9% |
| parse-script | 0.212531 | 0.209720 | +1.3% | -4.2 to +6.6% |
| parse-text | 0.088264 | 0.081062 | +8.2% | +2.6 to +13.4% |
| text | 0.276857 | 0.029196 | +89.5% | +89.1 to +89.8% |

`text`, `data` and `attribute` measure construction, repeated accumulation and materialization, not a whole parser. `parse-coalesced` is a deliberately interrupted-text parser stress test with source ranges disabled. `parse-discarded` uses the same interrupted input with source ranges enabled. This is not a reason to disable source ranges in Manabi. The other parser cases use entity-rich text, an entity-rich attribute and script content respectively. These synthetic cases do not establish workload prevalence.

## Reader controls, including the negative results

The external deterministic Manabi-style replays exclude morphology, dictionary/Realm I/O, WebKit and UI. Publication uses proper deep copies rather than the application's previously identified shallow-copy behavior. The confirmation and independent control repeat use 12 and 24 fresh process runs per revision respectively.

| Pass | Operation | Baseline ms | Candidate ms | Less time | 95% interval |
|---|---|---:|---:|---:|---:|
| initial | manabi-parse | 8.3302 | 8.4541 | -1.5% | -6.1 to +2.9% |
| initial | manabi-injection-deep | 55.2623 | 54.7782 | +0.9% | -4.3 to +5.7% |
| initial | manabi-publish-deep | 7.1998 | 7.7678 | -7.9% | -18.0 to +1.4% |
| initial | manabi-highlight | 2.9011 | 2.7696 | +4.5% | +0.4 to +8.5% |
| initial | manabi-ruby | 11.0913 | 11.1444 | -0.5% | -2.5 to +1.5% |
| repeat | manabi-publish-deep | 7.4747 | 7.2548 | +2.9% | -0.2 to +6.0% |
| repeat | manabi-injection-deep | 57.0095 | 57.2986 | -0.5% | -3.4 to +2.3% |
| repeat | manabi-highlight | 2.8719 | 2.8845 | -0.4% | -2.9 to +2.0% |

The initial publication slowdown did not reproduce. The initial highlighting improvement also did not reproduce. The defensible conclusion remains **no established general reader-pipeline speedup** from this incremental patch. Both passes are retained rather than selecting whichever estimate looks best. All three unchanged A/A intervals include zero.

The repeat was interrupted by an execution-tool timeout after 80 completed records, exactly at a balanced-block boundary. It resumed with the same recorded iteration counts and remaining schedule. All 144 planned repeat records are retained; none were discarded or duplicated. Together there are 312 external timing/A/A processes plus 24 portable processes containing 192 individual operation measurements.

## Fresh behavioral verification

- All three exact source variants passed the archived standalone suite: 708 passed, 14 opt-in benchmarks skipped, zero failures per variant (722 total). The archived suite does not contain all current upstream/fork tests and is not a full SwiftPM/Xcode run.
- All 11 newly committed fragment regression tests pass on all three variants. All eight portable fragment benchmarks also pass enabled on baseline and upstream-ready candidate.
- All 9,408 complete DOM-observation records match across the three variants (1,344 cases × seven parsing configurations).
- All 72 complete reader replay output sets match across the three variants.
- The production source trees and both new test-file blob hashes were checked against the published objects. This confirmation did not repeat the previously recorded AddressSanitizer checks. No Apple-device or Instruments measurement is claimed.

Complete DOM-output SHA-256: `c243b0307f2fbfaeb781bd5786ac51e9e66f659c165b9f33f1590345416b6ca1`.

Sources Git tree hashes:

```
baseline       697f0424d5df9ee2a674c6cfb65c65ec534715ee
candidate      324d663ff0b1f4451fcaeb812a833dd2ffff78e8
fork integrated 10b7b422369c40a5679ae9590ec15826975eb329
```

## Contributor reproduction

Place the identical committed benchmark file in each revision and use the same release toolchain, count and iteration settings. Alternate execution order and run A/A controls. The standard SwiftPM entry point is:

```sh
SWIFTSOUP_FRAGMENT_BENCHMARK=1 \
SWIFTSOUP_FRAGMENT_COUNT=256 \
SWIFTSOUP_FRAGMENT_ITERATIONS=1000 \
swift test -c release --filter FragmentAppendBenchmarkTest
```

The reported measurements used standalone XCTest clients, not that full SwiftPM invocation. The companion confirmation bundle includes the actual build/test scripts, source snapshots, fixture data, complete raw timings and commands, test logs and observation manifests. It does not include the unrecovered original 1,196-run raw archive mentioned in the earlier PR description.

## Raw portable batches

Each numeric entry below is the total timed elapsed milliseconds for 1,000 operations. Warmups are excluded. The CSV retains every portable result, including neutral and negative estimates.

```csv
block,position,variant,attribute,data,parse-attribute,parse-coalesced,parse-discarded,parse-script,parse-text,text
0,0,baseline,255.411678,275.178052,107.175217,728.168826,560.229020,208.627683,82.587664,262.206516
0,1,published,25.579163,21.365444,101.130164,413.614961,556.322533,203.740599,79.057976,28.301915
0,2,published,25.644611,20.979342,96.723614,406.059186,565.558030,214.578360,77.157391,29.627253
0,3,baseline,289.042623,246.126677,101.098971,658.845932,543.085952,208.748039,81.293368,279.905957
1,0,published,24.883302,21.160754,100.450664,399.310970,534.994820,206.467113,77.740345,29.729945
1,1,baseline,251.566747,258.307253,97.242089,703.919597,571.169321,232.412511,85.424644,294.300435
1,2,baseline,268.804440,261.395035,100.629603,672.653627,558.200816,233.519556,105.852963,280.200172
1,3,published,26.441173,21.566988,97.776195,434.288291,585.710713,209.278208,85.207817,29.266781
2,0,baseline,264.216566,255.137535,107.969436,787.111024,580.278386,200.133102,92.523179,280.276366
2,1,published,25.137188,23.336245,105.524856,460.846221,557.167632,206.959538,85.258122,28.968211
2,2,published,25.255797,21.607769,102.604941,418.373179,561.411036,209.794466,83.369706,29.363366
2,3,baseline,267.514963,265.354769,98.689241,684.140524,540.209326,202.845952,81.171710,276.012317
3,0,published,27.143916,23.656504,104.258134,451.549749,533.544661,211.159182,76.863917,28.390149
3,1,baseline,255.839353,256.408821,98.505994,673.736603,542.258787,206.778982,79.286809,262.138950
3,2,baseline,256.300924,250.297928,102.714925,689.346923,579.523664,208.207956,81.701791,280.083016
3,3,published,26.415296,22.209248,97.398262,422.525679,555.234212,210.426538,78.624652,28.875083
4,0,baseline,265.393020,267.721289,103.903555,698.540515,549.591108,207.191875,82.143195,271.288905
4,1,published,25.831877,22.073273,101.341915,404.993149,548.581006,211.146804,80.607280,30.409425
4,2,published,25.841071,21.943026,99.314581,408.470259,552.156854,210.552480,78.400084,29.967669
4,3,baseline,250.405694,268.493969,95.348208,698.641974,565.410751,217.872818,101.259105,270.276685
5,0,published,25.482749,21.348690,99.822770,411.785482,541.486304,207.406126,79.989474,28.336279
5,1,baseline,252.938428,264.736596,101.550344,710.588512,568.305538,208.021643,101.830145,303.943747
5,2,baseline,256.615419,276.373265,99.654738,716.039535,552.997105,218.940135,89.365609,264.718292
5,3,published,27.179504,22.507033,120.702768,403.784745,547.587184,215.412720,91.747703,29.199427
```
