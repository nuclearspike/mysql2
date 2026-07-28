# mysql2 — Experiments Registry

LSSD perf-lab experiments for the mysql2 Ruby gem (C extension). Lab context:
`popular-repos` README (benchmark-first ground rules). Upstream: brianmario/mysql2,
baseline clone at d4f8c13 (2026-07-27).

```lssd
reference_set reference_set.mysql2.bench_tables {
  label: "Deterministic seeded benchmark tables in local MySQL 9.6"
  version: "1.0.0"
  semantic: {
    purpose: "Stable row-materialization workloads for comparing mysql2 C-extension variants"
    members: [
      { id: "t_ints", role: "integer-heavy: 50000 rows x (id BIGINT PK + 10 INT cols)", generator: "benchmark/lssd/setup_data.rb seed=42" }
      { id: "t_strings", role: "string-heavy: 50000 rows x (id + 10 VARCHAR(64) utf8mb4 cols)", generator: "benchmark/lssd/setup_data.rb seed=42" }
      { id: "t_datetimes", role: "datetime-heavy: 50000 rows x (id + 6 DATETIME(6) cols)", generator: "benchmark/lssd/setup_data.rb seed=42" }
      { id: "t_mixed", role: "rails-like: 50000 rows x (id BIGINT, 4 VARCHAR, 2 INT, created_at/updated_at DATETIME(6), flag TINYINT(1), amount DECIMAL(10,2), body VARCHAR(255))", generator: "benchmark/lssd/setup_data.rb seed=42" }
      { id: "t_wide", role: "wide-row: 5000 rows x 40 mixed cols (hash growth stress)", generator: "benchmark/lssd/setup_data.rb seed=42" }
      { id: "t_big", role: "memory: 2000000 rows x (id BIGINT, a INT, b VARCHAR(32)) for cache_rows:false RSS", generator: "benchmark/lssd/setup_data.rb seed=42" }
    ]
    inclusionCriteria: ["Generated only by the pinned seeded generator; verified by MySQL CHECKSUM TABLE recorded at creation"]
    exclusionCriteria: ["No production data; no external corpora"]
    coverage: ["integer cast", "string+encoding cast", "datetime cast", "mixed rails-like", "wide row", "large-result memory"]
    provenance: ["Synthetic, Random.new(42), generator committed alongside this registry", "Pinned 2026-07-28 on MySQL 9.6.0: CHECKSUM TABLE t_ints=1436295408 t_strings=396335508 t_datetimes=1867018609 t_mixed=1583461254 t_wide=3715186487 t_big=2636729332; rows 50000/50000/50000/50000/5000/2048000"]
    usageConstraints: ["Local benchmarking only"]
    visibility: [internal]
    immutable: true
  }
  status: confirmed
  confidence: 1.0
}

benchmark benchmark.mysql2.row_materialization {
  label: "mysql2 row materialization wall-time + allocation benchmark"
  version: "1.1.0"
  changeNote: "1.0.0 plus additive :utc workloads (datetimes_utc_q, mixed_utc_q, datetimes_utc_stmt); deviation recorded in trial.mysql2.rowmat.v1_to_v8_steps"
  maturity: active
  semantic: {
    question: "How do mysql2 C-extension variants compare on full-result materialization time, object allocations, and peak memory?"
    referenceSet: @reference_set.mysql2.bench_tables
    referenceSetVersion: "1.0.0"
    referenceSetFingerprint: "sha256:babe8f1754a5e350bf719c1959f8b14238bc40509d83ededbd3bf46c25b84387"
    thresholds: { significance: "delta > 3x pooled MAD and > 3 percent", spec_suite: "must pass" }
    metrics: ["median_ms per workload (15 reps after 3 warmups)", "MAD_ms", "total_allocated_objects delta per materialization", "RSS delta KB for t_big cache_rows:false full iteration"]
    protocol: [
      "benchmark/lssd/bench.rb: per workload run SELECT * ... .to_a (query path, cast:true, hash rows); also as:array for t_mixed; also prepared-statement path for t_ints/t_mixed/t_datetimes",
      "3 warmup reps then 15 timed reps per workload, Process.clock_gettime(MONOTONIC), GC enabled (real-world timing), median + MAD reported",
      "allocations measured separately via GC.stat(:total_allocated_objects) delta, 3 reps, min taken",
      "benchmark/lssd/membench.rb: RSS via ps -o rss before/after t_big each(cache_rows:false)",
      "JSON artifact per run written under experiments/artifacts/ and sha256-hashed"
    ]
    aggregation: { time: "median of reps; variant comparison on medians; significant if delta > 3x pooled MAD and > 3%", allocations: "min of reps (deterministic lower bound)" }
    environmentControls: ["same machine (Apple M5 Max, AC), same local MySQL 9.6.0 server over TCP localhost, same Ruby 3.3.11 arm64, rake compile between variants, server warm (warmup reps touch all pages)"]
    comparability: ["Compare only runs pinned to reference_set 1.0.0 checksums and this protocol version"]
  }
  status: confirmed
  confidence: 1.0
}

experiment experiment.mysql2.rowmat_hotpath {
  label: "mysql2 row-materialization hot-path optimization study"
  version: "1.0.0"
  maturity: running
  semantic: {
    question: "Can targeted C-level changes to mysql2 result materialization deliver >=15% wall-time improvement on a rails-like workload and >=10% allocation reduction, with the full spec suite green?"
    hypothesis: "CONFIRMATORY, declared before any benchmark ran. H1: replacing rb_funcall(Time.utc,...7 args) with C civil->epoch + rb_time_timespec_new for :utc db_timezone cuts datetime-workload time >=25%. H2: caching per-column encoding (resolve charsetnr->rb_enc index once per column instead of rb_enc_find_index per cell) cuts string-workload time >=5%. H3: hoisting field-name VALUE lookup out of the per-cell path (snapshot per iteration) gives a small broad win >=2% on all workloads. H4: rb_hash_new_capa pre-sizing helps wide rows >=3%. H5: binding stmt result buffers once per result instead of per row improves stmt paths >=3%. H6: skipping rows-array capacity preallocation when cache_rows:false removes an O(rows) dead allocation (~8 bytes/row RSS) with no time regression. H7: strtoll fast path for <=18-digit ints beats rb_cstr2inum on int workload >=3%."
    scope: ["mysql2 @ d4f8c13 + local patches", "Ruby 3.3.11 arm64-darwin25", "MySQL server 9.6.0 + libmysqlclient 9.6.0 (homebrew)", "Apple M5 Max, macOS Darwin 25.5.0", "reference_set.mysql2.bench_tables 1.0.0"]
    variables: {
      independent: ["code variant (cumulative patch stack, one optimization added per step)"]
      dependent: ["median_ms per workload", "allocated objects per materialization", "RSS delta on t_big", "spec suite pass/fail"]
      confounders: ["thermal state", "MySQL server cache state", "background load", "GC timing"]
    }
    controls: ["same seeded tables (checksummed)", "same server process", "warmups before timing", "median-of-15 with MAD", "variants differ by exactly one optimization vs predecessor", "full spec suite must pass for a variant to count"]
    variants: [
      { key: v0_baseline, desc: "pristine upstream d4f8c13" }
      { key: v1_bugfixes, desc: "v0 + correctness fixes (symbolize_keys regression, field_types-after-free, stmt zero-date divergence); expected perf-neutral +-2%" }
      { key: v2_field_hoist, desc: "v1 + H3 per-cell field lookup hoisting" }
      { key: v3_enc_cache, desc: "v2 + H2 per-column encoding cache" }
      { key: v4_dt_fastpath, desc: "v3 + H1 UTC datetime fast path" }
      { key: v5_hash_capa, desc: "v4 + H4 hash pre-sizing" }
      { key: v6_int_fastpath, desc: "v5 + H7 integer strtoll fast path" }
      { key: v7_stmt_bind_once, desc: "v6 + H5 stmt bind once per result" }
      { key: v8_lazy_rows_alloc, desc: "v7 + H6 no rows-capacity prealloc when cache_rows:false" }
    ]
    protocol: [
      { id: setup, action: "Generate reference tables once, record CHECKSUM TABLE values into the registry" }
      { id: baseline, action: "Run benchmark.mysql2.row_materialization x3 on v0_baseline" }
      { id: step, action: "For each variant in order: implement, rake compile, full rspec, run benchmark x3, record trial + evidence; keep opt if >=3% on its target workload with no >1.5% regression elsewhere and specs green, else revert and record negative finding" }
      { id: memory, action: "membench.rb on v0 and on the variant containing H6" }
      { id: conclude, action: "Findings per hypothesis, decision record draft for which patches to keep/propose upstream" }
    ]
    measures: ["median_ms", "MAD_ms", "allocs_per_materialization", "rss_delta_kb", "spec_pass"]
    successCriteria: ["Cumulative final variant >=15% faster median on t_mixed query path vs v0", "t_datetimes >=25% faster", "allocs on t_mixed reduced >=10%", "353/353 specs pass on final variant (after bug fixes land)", "no workload regresses >1.5% in the final variant"]
    failureCriteria: ["Any kept optimization breaks a spec", "Final cumulative win on t_mixed < 5% (hypotheses substantially wrong)"]
    stopConditions: ["All variants trialed with >=3 valid runs each, or session budget exhausted"]
    budget: { maximum_trials: 40, maximum_elapsed_minutes: 240 }
    risks: ["Thermal drift on laptop (mitigate: interleave, median-of-15)", "Time.local DST semantics make H1 unsafe for :local timezone (mitigate: fast path :utc only, fall back to rb_funcall for :local)", "rb_hash_new_capa availability (Ruby >=3.2 only; guard with #ifdef)"]
    humanGates: ["Paul authorizes any upstream PR and the final decision record"]
  }
  trials: []
  findings: []
  decisions: []
  status: asserted
  confidence: 0.75
}
```

## Trials

```lssd
experiment_trial trial.mysql2.rowmat.v0_baseline of @experiment.mysql2.rowmat_hotpath {
  experimentVersion: "1.0.0"
  experimentFingerprint: "sha256:7d6de9ae6af62328a6fc16d722d70876debc041f2c28abe7fec731ad9c59964c"
  trialOutcome: completed
  occurredAt: "2026-07-28T07:05:00Z"
  variant: v0_baseline
  executions: ["bench runs 1-3", "membench run 1"]
  inputs: [{ role: workload, reference_set: @reference_set.mysql2.bench_tables }]
  resolvedParameters: { warmup: 3, reps: 15, alloc_reps: 3 }
  environment: { mysql2_rev: "d4f8c13 (clean)", ruby: "3.3.11 arm64-darwin25", server: "MySQL 9.6.0 localhost TCP", libmysqlclient: "mysql-client 9.6.0 homebrew", cpu: "Apple M5 Max", os: "Darwin 25.5.0" }
  outputs: ["experiments/artifacts/bench-v0_baseline-{1,2,3}.json sha256 833fbea5/e7bfb949/c2f6324d", "experiments/artifacts/membench-v0_baseline.json sha256 07f8f6b2"]
  evidence: [@evidence.mysql2.rowmat.v0_baseline.metrics]
  verdicts: { execution: passed, integrity: passed, spec_suite: "353 examples, 2 failures - both pre-existing upstream bugs at d4f8c13 (symbolize_keys regression, field_types-after-free), see finding nodes" }
  deviations: []
  status: observed
  confidence: 1.0
}

evidence evidence.mysql2.rowmat.v0_baseline.metrics {
  kind: measurement
  occurredAt: "2026-07-28T07:05:00Z"
  subject: @trial.mysql2.rowmat.v0_baseline
  method: "benchmark/lssd/bench.rb x3 + membench.rb per benchmark.mysql2.row_materialization 1.0.0"
  value: {
    medians_ms_run123: {
      ints_q: [61.013, 60.487, 62.274], strings_q: [84.179, 82.287, 84.263],
      datetimes_q: [370.294, 371.802, 376.395], mixed_q: [185.816, 183.384, 185.112],
      wide_q: [82.959, 85.584, 81.758], mixed_array_q: [163.722, 165.055, 161.024],
      mixed_nocast_q: [84.862, 89.979, 82.411], mixed_symbolized_q: [178.132, 174.651, 174.271],
      ints_stmt: [58.535, 58.446, 67.156], datetimes_stmt: [328.155, 334.031, 326.221],
      mixed_stmt: [188.197, 189.951, 180.807]
    }
    allocs: { ints_q: 50011, strings_q: 550011, datetimes_q: 650011, mixed_q: 650011, wide_q: 200011, mixed_stmt: 650011 }
    membench: { rows_array_memsize_bytes: 16384040, rss_base_kb: 26592, rss_peak_kb: 193696 }
  }
  provenance: { artifacts: "experiments/artifacts/bench-v0_baseline-*.json, membench-v0_baseline.json" }
  integrity: { sha256: "833fbea5/e7bfb949/c2f6324d/07f8f6b2 (per file, first 8 hex)", verification: "reference-set checksums matched before runs" }
  scope: ["mysql2 d4f8c13", "reference_set 1.0.0", "Apple M5 Max / Ruby 3.3.11 / MySQL 9.6.0"]
  status: observed
  confidence: 1.0
}
```

Baseline reading (informal): datetime casting dominates (370ms vs 61ms for the same 50k rows;
~1.2us per DATETIME cell through rb_funcall Time.utc). H6 confirmed pre-patch: rows array holds a
16,384,040-byte capacity buffer with 0 elements under cache_rows:false on t_big.

```lssd
experiment_trial trial.mysql2.rowmat.v1_to_v8_steps of @experiment.mysql2.rowmat_hotpath {
  experimentVersion: "1.0.0"
  experimentFingerprint: "sha256:7d6de9ae6af62328a6fc16d722d70876debc041f2c28abe7fec731ad9c59964c"
  trialOutcome: completed
  occurredAt: "2026-07-28T07:10:00Z/09:40:00Z"
  variant: "v1_bugfixes through v8_lazy_rows_alloc, cumulative stack, one optimization per step"
  executions: ["bench-v1_bugfixes-{1..3}", "bench-v2_field_hoist-{1..3}", "bench-v3_enc_cache-{1..3}", "bench-v4_dt_fastpath-{1..4}", "bench-v5_hash_capa-{1..3}", "bench-v6_int_fastpath-{1..3}", "bench-v7_stmt_bind_once-{1..3}", "bench-v8_lazy_rows_alloc-1", "membench-v8_lazy_rows_alloc", "bench-v0_baseline-{4..6} (pristine worktree, adds :utc workloads)"]
  inputs: [{ role: workload, reference_set: @reference_set.mysql2.bench_tables }]
  resolvedParameters: { warmup: 3, reps: 15, alloc_reps: 3 }
  environment: { base: "same as trial.mysql2.rowmat.v0_baseline", branch: "lssd/perf", bugfix_commit: "2d2d680", perf_commit: "33f8239" }
  outputs: ["experiments/artifacts/bench-v{1..8}_*.json + membench-v8_lazy_rows_alloc.json, sha256 prefixes 06a296eb 9955d8d3 1cf04071 1ca6b66d 5c4269a0 9bc29ef4 ffafff1f 6fc63d5b f564af07 cc4cb805 d706ece5 a06ce717 11195f3b 0c2ee1cd 797bc11d 9e20731f 75f2f2db b8174f0c 18093bb7 94d429b8 787f00fc b1eb5781 84d5a153 94be1b3d"]
  evidence: [@evidence.mysql2.rowmat.final_ab.metrics]
  verdicts: {
    execution: passed, integrity: passed,
    spec_suite: "green at every step (355 -> 358 examples as regression specs were added), 0 failures",
    v1_bugfixes: "perf-neutral within +-3.5pct as predicted",
    v2_field_hoist: "ints -6.4pct, stmt ints -3.2pct; noise elsewhere",
    v3_enc_cache: "strings -12.3pct, cast:false -12pct; no regression",
    v4_dt_fastpath: "datetimes_utc text 117.4->92.9ms (-20.9pct), stmt 81.0->60.6ms (-25.2pct) vs pristine-worktree baseline; :local untouched by design",
    v5_hash_capa: "ints -7pct, strings -3.5pct, wide -4pct vs v4",
    v6_int_fastpath: "ints -15.1pct vs v5",
    v7_stmt_bind_once: "stmt workloads improved (share overlaps v5); no regression",
    v8_lazy_rows_alloc: "rows_array_memsize 16384040 -> 40 bytes on 2M-row cache_rows:false; timing neutral"
  }
  deviations: ["Benchmark protocol extended mid-experiment to 1.1.0: database_timezone :utc workloads (datetimes_utc_q, mixed_utc_q, datetimes_utc_stmt) added at v4 when it emerged that the gem default :local exercises Time.local, not the fast path target; pristine-worktree v0 runs 4-6 provided the missing :utc baselines", "Registry trial entries batched after implementation instead of per-step; all per-step artifacts were written and hashed at execution time", "v8 timing captured with 1 run instead of 3 (its timing surface is identical to v7; the final interleaved A/B provides 4 more full-stack runs)"]
  status: observed
  confidence: 0.95
}

experiment_trial trial.mysql2.rowmat.final_ab of @experiment.mysql2.rowmat_hotpath {
  experimentVersion: "1.0.0"
  experimentFingerprint: "sha256:7d6de9ae6af62328a6fc16d722d70876debc041f2c28abe7fec731ad9c59964c"
  trialOutcome: completed
  occurredAt: "2026-07-28T09:45:00Z"
  variant: "v0_baseline (pristine worktree at d4f8c13) vs v8 full stack (33f8239), interleaved A/B"
  executions: ["4 interleaved run-pairs: bench-v0_final_ab-{11..14} / bench-v8_final_ab-{11..14}"]
  inputs: [{ role: workload, reference_set: @reference_set.mysql2.bench_tables }]
  resolvedParameters: { warmup: 3, reps: 15, pairs: 4, order: "ABABABAB to neutralize thermal drift" }
  environment: { same as baseline trial; v0 lib from git worktree ../mysql2-v0 }
  outputs: ["sha256 prefixes: v0 22bfb858 a34207da 0b91477b 6f2a61f4; v8 caac7bfb 882163a3 f9494ea0 09e5bbc2"]
  evidence: [@evidence.mysql2.rowmat.final_ab.metrics]
  verdicts: { execution: passed, integrity: passed, timing: passed, allocation_reduction: failed, memory_bytes: passed, spec_suite: passed }
  deviations: []
  status: observed
  confidence: 1.0
}

evidence evidence.mysql2.rowmat.final_ab.metrics {
  kind: measurement
  occurredAt: "2026-07-28T09:45:00Z"
  subject: @trial.mysql2.rowmat.final_ab
  method: "median of 4 interleaved runs per side, each run = median of 15 reps after 3 warmups"
  value: {
    medians_ms_v0_vs_v8: {
      ints_q: [63.3, 49.1], strings_q: [84.1, 74.9], datetimes_q: [388.3, 387.9],
      mixed_q: [193.7, 175.2], wide_q: [86.0, 82.3], mixed_array_q: [166.3, 160.0],
      mixed_nocast_q: [88.4, 76.6], mixed_symbolized_q: [180.2, 170.8],
      datetimes_utc_q: [122.9, 97.6], mixed_utc_q: [120.0, 98.4],
      ints_stmt: [66.0, 48.8], datetimes_stmt: [348.5, 337.5], mixed_stmt: [190.8, 179.0],
      datetimes_utc_stmt: [90.7, 64.6]
    }
    deltas_pct: { ints_q: -22.5, strings_q: -10.9, datetimes_q: -0.1, mixed_q: -9.5, wide_q: -4.3, mixed_array_q: -3.8, mixed_nocast_q: -13.4, mixed_symbolized_q: -5.2, datetimes_utc_q: -20.6, mixed_utc_q: -18.0, ints_stmt: -26.1, datetimes_stmt: -3.1, mixed_stmt: -6.2, datetimes_utc_stmt: -28.8 }
    allocs_delta: "0 across all workloads (object counts unchanged; wins are CPU-per-cell)"
    membench_v8: { rows_array_memsize_bytes: 40, was: 16384040 }
  }
  provenance: { artifacts: "experiments/artifacts/bench-v{0,8}_final_ab-{11..14}.json" }
  integrity: { sha256: "prefixes recorded in the trial outputs", verification: "reference-set row counts + checksums matched; both sides ran identical harness rev" }
  scope: ["mysql2 d4f8c13 vs 33f8239", "reference_set 1.0.0", "Apple M5 Max / Ruby 3.3.11 / MySQL 9.6.0 / macOS Darwin 25.5.0"]
  status: observed
  confidence: 1.0
}
```

## Findings

```lssd
finding finding.mysql2.rowmat.h1_utc_fastpath {
  claim: "Replacing rb_funcall(Time.utc, 7 args) with C civil-to-epoch + rb_time_timespec_new cuts :utc datetime materialization 20.6pct (text) and 25-29pct (binary/stmt); it does not reach the hypothesized 25pct on the text path because sscanf parsing and row overhead remain."
  strength: supported
  basedOn: [@evidence.mysql2.rowmat.v0_baseline.metrics, @evidence.mysql2.rowmat.final_ab.metrics]
  scope: ["database_timezone :utc only; :local deliberately untouched", "reference_set 1.0.0", "Apple M5 Max / Ruby 3.3.11 / MySQL 9.6"]
  supports: ["H1 partially: stmt exceeded target, text fell short of 25pct at -20.6pct"]
  contradicts: []
  limitations: ["Single machine, single MySQL version", "Time.utc equivalence verified by spec across range edges but not exhaustively fuzzed"]
  invalidatedBy: ["Ruby changing rb_time_timespec_new semantics", "reference-set change"]
  status: inferred
  confidence: 0.9
}

finding finding.mysql2.rowmat.local_tz_dominates {
  claim: "With the gem-default database_timezone :local, Time.local conversion dominates datetime casting (~370ms vs ~117ms for :utc on identical baseline data, 3.2x): the biggest remaining optimization surface in mysql2 datetime handling is the :local path, not funcall overhead."
  strength: supported
  basedOn: [@evidence.mysql2.rowmat.v0_baseline.metrics, @evidence.mysql2.rowmat.final_ab.metrics]
  scope: ["reference_set 1.0.0", "Apple M5 Max / Ruby 3.3.11"]
  supports: ["Prioritizing a :local fast path as follow-up work"]
  contradicts: ["The tacit assumption that funcall overhead was the datetime bottleneck for all timezone configs"]
  limitations: ["A C fast path for :local must reproduce Ruby's own DST-gap and TZ-env semantics exactly; risk documented, not attempted"]
  invalidatedBy: ["Ruby Time.local implementation changes"]
  status: inferred
  confidence: 0.92
}

finding finding.mysql2.rowmat.percell_overhead {
  claim: "Per-cell fixed overhead (field-name lookup chain, per-cell encoding table lookup, per-row hash growth, per-row stmt rebind, per-value rb_cstr2inum) is 22-26pct of integer-workload wall time; eliminating it (H2+H3+H4+H5+H7 combined) yields ints -22.5pct (text) and -26.1pct (stmt) with zero object-allocation change."
  strength: supported
  basedOn: [@evidence.mysql2.rowmat.final_ab.metrics]
  scope: ["reference_set 1.0.0", "cumulative stack; per-step shares recorded in trial.mysql2.rowmat.v1_to_v8_steps verdicts"]
  supports: ["H2 (strings -10.9 to -12.3pct)", "H3 (small, broad)", "H4 (broad, biggest single step on ints at -7pct)", "H5 (stmt share)", "H7 (ints -15.1pct step)"]
  contradicts: ["H-alloc expectation: the successCriteria line 'allocs on t_mixed reduced >=10pct' FAILED - allocation counts are driven entirely by value objects and did not move; the wins are CPU per cell, not fewer objects"]
  limitations: ["Attribution between H4 and H5 on stmt workloads overlaps; not isolated further"]
  invalidatedBy: ["Ruby hash/string internals changes", "reference-set change"]
  status: inferred
  confidence: 0.9
}

finding finding.mysql2.rowmat.h6_dead_capacity {
  claim: "With cache_rows: false, mysql2 reserved full-result rows-array capacity it never used (8 bytes/row: 16,384,040 bytes on a 2M-row iteration); allocating lazily removes it entirely (40 bytes) with no timing regression."
  strength: supported
  basedOn: [@evidence.mysql2.rowmat.v0_baseline.metrics, @evidence.mysql2.rowmat.final_ab.metrics]
  scope: ["reference_set 1.0.0 t_big", "any result iterated with cache_rows: false"]
  supports: ["H6 fully"]
  contradicts: []
  limitations: ["RSS-level effect is masked by libmysqlclient's own store_result buffer (~167MB for t_big), which dwarfs the Ruby-side saving; the win is real but secondary to the C-library buffering for total memory"]
  invalidatedBy: ["Semantics change to rows caching"]
  status: inferred
  confidence: 0.95
}

finding finding.mysql2.rowmat.upstream_bugs {
  claim: "Upstream HEAD d4f8c13 ships four result.c bugs: (A) each(symbolize_keys: true) silently ignored when query options did not set it (regression from #1427's eager field fetch); (B) field_types raises after free on exhausted empty results despite #1427 intending otherwise - its own spec fails; (C) binary-protocol zero dates raise Date::Error where text protocol returns nil; (D) wrapper->fieldTypes never GC-marked/compacted - latent use-after-free reachable via GC.compact or any GC between field_types calls; plus (E) each() after manual free() dereferences the freed MYSQL_RES (returned 0 rows from freed memory in repro)."
  strength: supported
  basedOn: [@evidence.mysql2.rowmat.v0_baseline.metrics]
  scope: ["mysql2 d4f8c13, MySQL 9.6, Ruby 3.3.11; A and B reproduced by upstream's own spec suite, C and E by targeted repro scripts in-session"]
  supports: ["All five fixed in commit 2d2d680 (A-D) and 33f8239-adjacent guard (E), suite 358/358 green"]
  contradicts: []
  limitations: ["D verified by code inspection (missing mark) rather than a crash repro; the class of defect is deterministic from the GC contract"]
  invalidatedBy: ["Upstream fixing these independently"]
  status: inferred
  confidence: 0.95
}
```

## Multi-model review conference (2026-07-28, post-conclusion)

```lssd
experiment_trial trial.mysql2.rowmat.review_conference of @experiment.mysql2.rowmat_hotpath {
  experimentVersion: "1.0.0"
  experimentFingerprint: "sha256:7d6de9ae6af62328a6fc16d722d70876debc041f2c28abe7fec731ad9c59964c"
  trialOutcome: completed
  occurredAt: "2026-07-28T14:30:00Z"
  variant: "adversarial multi-model review of the full diff (not a perf variant)"
  executions: ["12 units x 3 passes (cloud-reasoning prioritized, cloud adversarial, local qwen3-coder-30b direct) + qwen3.6-35b-a3b whole-diff integration pass; 37 completed reviews; artifacts in session scratchpad conference/ (U*-P*.md, P4-integration.md)"]
  inputs: [{ role: package, description: "complete d4f8c13..HEAD diff of ext/ and spec/ plus commit messages, 1008 lines, untruncated per standing rule" }]
  resolvedParameters: { units: 12, passes_per_unit: 3, integration_passes: 1 }
  environment: { hub: "127.0.0.1:4200 (cloud lanes)", local: "LM Studio 127.0.0.1:1234 direct - hub local lane misroutes qwen pins to deprecated OpenAI codex models (defect filed as spawned task)", models: "cloud reasoning lane, qwen3-coder-30b (32k ctx), qwen3.6-35b-a3b (262k ctx)" }
  outputs: ["commit aca4472 (fixes + 9 regression specs)", "suite 366 examples 0 failures", "bench sanity within noise: ints 46.1ms, mixed_utc 87.0ms, datetimes_utc_stmt 62.9ms"]
  evidence: []
  verdicts: {
    real_findings_fixed: "5: (1) streaming .fields before iteration returned nil [cloud-prioritized U1]; (2) freed-replay nil-rows hole - predicate needed rows-length check, also latent at upstream HEAD [cloud-prioritized U5]; (3) freed incomplete-streaming iteration could deref freed MYSQL_RES [cloud-prioritized U5]; (4) as: :array starved #fields after streaming iteration [cloud-prioritized U6]; (5) free() inside the iteration block caused next-row UAF, pre-existing upstream [qwen3.6-35b integration pass]",
    hardening_adopted: "month/day/usec fast-path bounds, <time.h>, %.*s int casts, per-row default_internal restoration (parity), fail-fast meta guard",
    dismissed_with_reason: "~40 claims incl. two mutually-contradictory rb_time_timespec_new sentinel claims (settled empirically: INT_MAX-1 is UTC, proven by range-edge spec on a UTC-6 host), GC compaction fears (conservative stack marking pins C-local VALUEs; TypedData payloads do not move), xcalloc NULL/overflow claims (Ruby xcalloc raises, checked multiply), streaming as: :array empty-rows claim (flawed repro - blockless each returns the rows array, not an Enumerator; correct-block repro verified fine)",
    lane_quality: "cloud prioritized passes found 4 of 5 real bugs and produced 3 verified-SOUND verdicts; cloud adversarial passes contributed corroboration and the F2 length-check shape; qwen3-coder passes were verbose, self-contradictory, zero unique real findings; qwen3.6-35b burned 3000-then-9000 token budgets entirely on hidden reasoning (empty visible output twice) but its extracted reasoning contained the one finding every other lane missed"
  }
  deviations: ["Hub local lane down (stale codex aliases): 12 local passes + integration pass ran direct against LM Studio, bypassing hub logging - stated, not silent", "P3/P4 rerun after initial failures; 6 adversarial passes rerun on the reasoning lane after the code lane 404'd"]
  status: observed
  confidence: 0.95
}
```

## Post-conclusion hardening (2026-07-28)

Portability defect found while reviewing version constraints, after the final A/B:
`mysql2_utc_time` cast an int64 epoch into `timespec.tv_sec` (time_t) unchecked. On
32-bit time_t platforms (legacy mingw32, 32-bit Linux/musl without 64-bit time), dates
outside 1901-2038 would silently truncate to wrong Time values where the generic
Time.utc path was correct. Fixed with a narrowing round-trip check that returns Qnil
and falls back to the funcall path; on 64-bit time_t the check constant-folds away.
Sanity evidence: bench-v8_timet_guard-1.json (datetimes_utc_q 98.571ms,
datetimes_utc_stmt 54.272ms, ints_q 44.880ms - all within noise of the final A/B
medians), suite 358/358 green, 0 compiler warnings. Scope note: the defect was
unreachable in this lab's measured environment (Apple Silicon, 64-bit time_t), so no
recorded evidence is affected; it mattered only for the upstream-contribution path.

## Decision record (draft - authorization gate: Paul)

```lssd
decision_record decision_record.mysql2.rowmat.keep_stack {
  decision: "Keep the full v8 optimization stack + bug fixes on branch lssd/perf as the lab result; candidate upstream contribution as two PRs (bug fixes; optimizations) remains UNDECIDED pending Paul's authorization."
  state: active
  authority: { mode: human, owner: "Paul Ericksen", note: "drafted by session agent; lab-result scope only - upstream submission explicitly NOT authorized by this record" }
  decidedAt: "2026-07-28"
  basedOn: [@finding.mysql2.rowmat.h1_utc_fastpath, @finding.mysql2.rowmat.percell_overhead, @finding.mysql2.rowmat.h6_dead_capacity, @finding.mysql2.rowmat.upstream_bugs]
  alternatives: ["Cherry-pick only the datetime fast path (largest single win) - rejected: the other wins are independent, spec-clean and additive", "Fast-path :local timezone too - rejected for now: DST/TZ-env semantic risk documented in finding.mysql2.rowmat.local_tz_dominates"]
  consequences: ["Lab narrative gains a Ruby/C exhibit: 10-29pct on a 16-year-old, heavily-optimized driver", "Upstream PRs require hub double-review per standing rule before submission"]
  revisitWhen: ["Paul reviews the session report", "Upstream review feedback arrives", "Ruby 3.4+ hash/time internals change", "MariaDB-client verification runs (mariadb_field_attr path only compile-tested here)"]
  supersedes: []
  status: confirmed
  confidence: 0.85
}
```

## Leave-behinds

```lssd
heuristic heuristic.mysql2.bench_tz_config {
  version: "1.0.0"
  maturity: active
  semantic: {
    statement: "When benchmarking or optimizing mysql2 datetime paths, pin database_timezone explicitly and measure :utc and :local separately."
    appliesWhen: ["Any mysql2 datetime-casting benchmark or optimization work"]
    avoidWhen: ["Workloads with no temporal columns"]
    rationale: ["The gem default (:local) and the Rails default (:utc) differ 3.2x in baseline cost and take entirely different code paths (Time.local conversion vs Time.utc construction)"]
    examples: ["This experiment's mid-flight benchmark 1.1.0 correction after :local defaults masked the fast-path target"]
    counterexamples: []
    confidenceBoundary: ["Measured on Apple Silicon / Ruby 3.3; ratio may shift across Ruby versions"]
    verification: [@benchmark.mysql2.row_materialization]
    promotionCriteria: ["Fold into the lab's standard benchmark checklist if it recurs on another driver"]
  }
  knowledge: {
    scope: ["mysql2 datetime casting, any platform"]
    evidence: [@finding.mysql2.rowmat.local_tz_dominates]
    owner: "popular-repos lab"
    learnedAt: "2026-07-28"
    invalidatedBy: ["Ruby Time.local cost profile changes materially"]
    supersedes: []
  }
  status: inferred
  confidence: 0.9
}

opportunity opportunity.mysql2.local_tz_fastpath {
  opportunityState: proposed
  outcome: "A :local-timezone datetime fast path bringing :local casting toward :utc cost (~3.2x headroom)"
  actors: ["popular-repos lab", "mysql2 upstream maintainers"]
  problemEvidence: [@finding.mysql2.rowmat.local_tz_dominates]
  expectedValue: ["Up to ~70pct reduction in datetime casting cost for the gem-default :local configuration, the single largest remaining surface"]
  dependencies: ["Exact parity with Ruby Time.local across DST gaps/overlaps, runtime TZ env changes, and historic offsets"]
  risks: ["A semantic divergence from Time.local silently corrupts timestamps - worst-case failure mode for a database driver"]
  nextDecision: "Decide whether to prototype behind an opt-in flag with a DST-transition differential fuzz harness (Time.local vs fast path over full tzdata transition tables)"
  knowledge: {
    scope: ["mysql2 text and binary datetime casting, database_timezone :local"]
    evidence: [@finding.mysql2.rowmat.local_tz_dominates]
    owner: "popular-repos lab (unassigned)"
    learnedAt: "2026-07-28"
    invalidatedBy: ["Problem disappears via Ruby-side Time.local optimization", "Risk assessed as exceeding value"]
    supersedes: []
  }
  status: inferred
  confidence: 0.85
}
```
