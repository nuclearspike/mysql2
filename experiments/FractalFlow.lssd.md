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
  version: "1.0.0"
  maturity: active
  semantic: {
    question: "How do mysql2 C-extension variants compare on full-result materialization time, object allocations, and peak memory?"
    referenceSet: @reference_set.mysql2.bench_tables
    referenceSetVersion: "1.0.0"
    referenceSetFingerprint: "sha256:795bc5db6b3f4ae7d4a3c6f0bafdb0fb5ba1cc01f2fc1d4d5b9b095df3998120"
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
