# Benchmarking & profiling protocol (SwiftSoup)

This repo’s current performance harness is the `BenchmarkProfileTest/testParseBenchmarkProfile` test. It is driven by
environment variables and runs in a release test build.

## Optional mise shortcuts (macOS/Linux)
The tasks use your existing Swift toolchain and do not install tools:
```
mise run test:release
mise run bench
SWIFTSOUP_BENCHMARK_ITERATIONS=100 mise run bench
SWIFTSOUP_BENCHMARK_SET=attribute-heavy mise run bench
```
`bench` defaults to `base,large`, two in-process warmups, and ten measured iterations.
Existing `SWIFTSOUP_BENCHMARK_*` environment overrides are preserved. Increase the
iteration count for measurements; these modest defaults are only a starting point.
The direct SwiftPM commands below remain supported without mise.

Compare the benchmark's elapsed-time line, not build or task wall time. The default
workload includes Data and String parsing plus selector/text operations; it is not a
parse-only measurement. Record `swift --version` and any local source changes with
results. Repeat runs with alternating baseline/candidate order, run an unchanged
A/A comparison to estimate noise, and validate behavior with regression tests before
interpreting an improvement. Keep profiling runs separate from timing runs.

## A/B comparison rules
- Always compare release builds on the same machine.
- If an optimization has a flag: run OFF vs ON.
- If no flag: compare HEAD to a baseline commit in a worktree.
- Test each optimization in isolation before any combined run.
- Record commit SHAs, flags, iterations, and the exact command lines used.

## Common benchmark knobs (env vars)
- `SWIFTSOUP_BENCHMARK=1` (enable the benchmark test)
- `SWIFTSOUP_BENCHMARK_SET=...` (comma-separated workload sets)
- `SWIFTSOUP_BENCHMARK_WARMUP=2`
- `SWIFTSOUP_BENCHMARK_ITERATIONS=500`
- `SWIFTSOUP_BENCHMARK_ITERATIONS_MULTIPLIER=1`
- `SWIFTSOUP_BENCHMARK_REPEAT=200` (base set)
- `SWIFTSOUP_BENCHMARK_LARGE_REPEAT=60` (large set)
- `SWIFTSOUP_BENCHMARK_SELECTOR_REPEAT=1`
- `SWIFTSOUP_BENCHMARK_SELECTOR_STRESS_REPEAT=1`
- `SWIFTSOUP_BENCHMARK_ATTRIBUTE_SELECTOR_STRESS_REPEAT=1`
- `SWIFTSOUP_BENCHMARK_SERIALIZER=source-patched|without-source-reuse|reuse-source-outside-body`
- `SWIFTSOUP_BENCHMARK_DENSE_BODY_MUTATIONS=1`

## Regression suite (broad coverage)
Run in both baseline and current (exact command line):
```
SWIFTSOUP_BENCHMARK=1 \
SWIFTSOUP_BENCHMARK_SET=base,large \
SWIFTSOUP_BENCHMARK_REPEAT=200 \
SWIFTSOUP_BENCHMARK_LARGE_REPEAT=60 \
SWIFTSOUP_BENCHMARK_WARMUP=2 \
SWIFTSOUP_BENCHMARK_ITERATIONS=500 \
SWIFTSOUP_BENCHMARK_ITERATIONS_MULTIPLIER=1 \
SWIFTSOUP_BENCHMARK_SELECTOR_REPEAT=1 \
SWIFTSOUP_BENCHMARK_SELECTOR_STRESS_REPEAT=1 \
SWIFTSOUP_BENCHMARK_ATTRIBUTE_SELECTOR_STRESS_REPEAT=1 \
swift test -c release --filter BenchmarkProfileTest/testParseBenchmarkProfile
```

## Targeted suite (optimization-specific)
Pick the workload set that stresses the change and run with the same flags:
```
SWIFTSOUP_BENCHMARK=1 \
SWIFTSOUP_BENCHMARK_SET=attribute-heavy,attribute-mega,attribute-storm,data-heavy,data-storm,tag-heavy,custom-tag,dense-text,querystring \
SWIFTSOUP_BENCHMARK_WARMUP=2 \
SWIFTSOUP_BENCHMARK_ITERATIONS=500 \
SWIFTSOUP_BENCHMARK_ITERATIONS_MULTIPLIER=1 \
SWIFTSOUP_BENCHMARK_SELECTOR_REPEAT=1 \
SWIFTSOUP_BENCHMARK_SELECTOR_STRESS_REPEAT=1 \
SWIFTSOUP_BENCHMARK_ATTRIBUTE_SELECTOR_STRESS_REPEAT=1 \
swift test -c release --filter BenchmarkProfileTest/testParseBenchmarkProfile
```

## Serializer A/B
For Reader-style dense body mutation, run the same release benchmark once per serializer:
```
for serializer in source-patched without-source-reuse reuse-source-outside-body; do
  SWIFTSOUP_BENCHMARK=1 \
  SWIFTSOUP_BENCHMARK_SET=manabi-reader \
  SWIFTSOUP_BENCHMARK_MANABI_REPEAT=40 \
  SWIFTSOUP_BENCHMARK_WARMUP=2 \
  SWIFTSOUP_BENCHMARK_ITERATIONS=30 \
  SWIFTSOUP_BENCHMARK_ITERATIONS_MULTIPLIER=1 \
  SWIFTSOUP_BENCHMARK_SKIP_SELECTORS=1 \
  SWIFTSOUP_BENCHMARK_SKIP_TEXT=1 \
  SWIFTSOUP_BENCHMARK_DENSE_BODY_MUTATIONS=1 \
  SWIFTSOUP_BENCHMARK_SERIALIZER="$serializer" \
  swift test -c release --filter BenchmarkProfileTest/testParseBenchmarkProfile
done
```

## Baseline worktree helper
- `git worktree add ../SwiftSoup-bench-base <baseline-commit>`
- Run the same commands in both trees; compare the “Benchmark elapsed: … ms over N iterations” line.
- Use `git rev-parse HEAD` to log the commit for each side.

## Profiling
- Use Instruments (Time Profiler) on the `SwiftSoupPackageTests.xctest` process while running the same benchmark test
  filter and env vars.
- Always profile release builds and keep the workload set identical to the benchmark run you are comparing against.
