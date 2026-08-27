# Structured resource tests and benchmarks

`run_tests.sh` exercises the supported ITM, SPL, and EFF schemas. In
addition to ordinary field edits, it covers nested iteration, cross-collection
effect cloning, deep ability cloning, stable insertion anchors, deletion while
iterating, preservation of trailing bytes, and rollback of a multi-step graph
rewrite. The generated ITM fixture demonstrates a practical upper-end rewrite;
the paired SPL fixtures prove that a late error restores every byte of the
original resource.

Run the regression suite from the repository root:

```sh
make test-structured-resources
```

## Performance benchmark

`benchmark.sh` compares byte-identical outputs from the structured editor and
ad hoc functions. It has two workloads:

- `field` changes four ability headers and all 36 embedded effects. It compares
  `PATCH_RESOURCE`, a purpose-built direct-offset function, and WeiDU's bundled
  `ALTER_ITEM_HEADER` plus `ALTER_ITEM_EFFECT` helpers.
- `structural` deep-clones four abilities and their 32 owned effects, changes
  each clone, appends an effect to each clone, relocates the effect table, and
  rebuilds ownership indices. It compares `PATCH_RESOURCE` with a purpose-built
  direct-offset implementation of the same graph rewrite.

The default matrix uses 1,000, 10,000, and 100,000 physical input files. It
runs one unrecorded warm-up per method, then respectively records seven, five,
and three repetitions. Method order is reversed on alternating repetitions to
reduce order bias. Input generation is outside the timed region. After every
scale, SHA-256 manifests must show byte-for-byte equivalence between all
implementations of a workload or the benchmark fails.

Run the complete Linux benchmark with:

```sh
make benchmark-structured-resources
```

For a short developer run, or to select a persistent results directory:

```sh
BENCH_COUNTS="100 1000" BENCH_REPETITIONS=3 \
BENCH_RESULT_DIR=/tmp/weidu-structured-results \
make benchmark-structured-resources
```

`BENCH_JOBS` controls only parallel fixture generation, never the measured
WeiDU process. Results comprise:

- `raw.tsv`: external wall, user and system time, maximum resident memory, and
  WeiDU's internal `PATCH_TIME` CPU measurement for every recorded run;
- `summary.md`: medians, observed wall-time ranges, throughput, and ratios to
  the purpose-built direct function;
- `environment.txt`: the timestamp, host characteristics, binary digest,
  source revision, scale, and repetition settings.

Wall time is the appropriate installation-impact measure because it includes
file discovery, reads, patching, and writes. `PATCH_TIME` isolates the patch
body's user-CPU cost. Neither metric is a language guarantee: results depend on
the host, filesystem, cache state, compiler, resource shape, and operation mix.
Commit the benchmark and methodology, but publish measured numbers as CI
artifacts or pull-request evidence rather than as permanent documentation.
