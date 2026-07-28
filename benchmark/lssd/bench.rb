# benchmark.mysql2.row_materialization — timing + allocation runner (LSSD lab harness)
# Usage: ruby benchmark/lssd/bench.rb <variant-name> [run-index]
# rubocop:disable Naming/MethodParameterName, Style/FormatStringToken
$LOAD_PATH.unshift(ENV['MYSQL2_LIB'] || File.expand_path('../../lib', __dir__))
require 'mysql2'
require 'yaml'
require 'json'
require 'time'

variant = ARGV[0] or abort 'usage: bench.rb <variant> [run-index]'
run_idx = (ARGV[1] || '1').to_i

creds = YAML.load_file(File.expand_path('../../spec/configuration.yml', __dir__))['root']
client = Mysql2::Client.new(host: '127.0.0.1', username: creds['username'], password: creds['password'], database: 'mysql2_bench')

WARMUP = 3
REPS = 15

def time_ms
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
end

def median(a)
  s = a.sort
  n = s.size
  n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
end

def mad(a)
  m = median(a)
  median(a.map { |x| (x - m).abs })
end

WORKLOADS = {}.freeze

def workload(name, &blk)
  WORKLOADS[name] = blk
end

workload('ints_q')      { |c| c.query('SELECT * FROM t_ints').to_a }
workload('strings_q')   { |c| c.query('SELECT * FROM t_strings').to_a }
workload('datetimes_q') { |c| c.query('SELECT * FROM t_datetimes').to_a }
workload('mixed_q')     { |c| c.query('SELECT * FROM t_mixed').to_a }
workload('wide_q')      { |c| c.query('SELECT * FROM t_wide').to_a }
workload('mixed_array_q') { |c| c.query('SELECT * FROM t_mixed', as: :array).to_a }
workload('mixed_nocast_q') { |c| c.query('SELECT * FROM t_mixed', cast: false).to_a }
workload('mixed_symbolized_q') { |c| c.query('SELECT * FROM t_mixed', symbolize_keys: true).to_a }
# benchmark 1.1.0: database_timezone :utc variants (the Rails/production default;
# the gem default :local exercises Time.local instead)
workload('datetimes_utc_q') { |c| c.query('SELECT * FROM t_datetimes', database_timezone: :utc).to_a }
workload('mixed_utc_q')     { |c| c.query('SELECT * FROM t_mixed', database_timezone: :utc).to_a }

STMTS = {}.freeze
workload('ints_stmt')      { |c| (STMTS['ints'] ||= c.prepare('SELECT * FROM t_ints')).execute.to_a }
workload('datetimes_stmt') { |c| (STMTS['datetimes'] ||= c.prepare('SELECT * FROM t_datetimes')).execute.to_a }
workload('mixed_stmt')     { |c| (STMTS['mixed'] ||= c.prepare('SELECT * FROM t_mixed')).execute.to_a }
workload('datetimes_utc_stmt') { |c| (STMTS['datetimes'] ||= c.prepare('SELECT * FROM t_datetimes')).execute(database_timezone: :utc).to_a }

results = {}
WORKLOADS.each do |name, blk|
  WARMUP.times { blk.call(client) }
  reps = Array.new(REPS) { time_ms { blk.call(client) } }
  allocs = Array.new(3) do
    before = GC.stat(:total_allocated_objects)
    blk.call(client)
    GC.stat(:total_allocated_objects) - before
  end.min
  results[name] = { median_ms: median(reps).round(3), mad_ms: mad(reps).round(3), allocs: allocs, reps_ms: reps.map { |r| r.round(3) } }
  warn format('%-20s median=%9.3fms mad=%7.3fms allocs=%d', name, results[name][:median_ms], results[name][:mad_ms], allocs)
end

out = {
  meta: {
    variant: variant, run: run_idx, ts: Time.now.utc.iso8601,
    ruby: RUBY_DESCRIPTION, mysql2: Mysql2::VERSION, server: client.server_info[:version],
    rev: `git -C #{File.expand_path('../..', __dir__)} rev-parse --short HEAD 2>/dev/null`.strip,
    dirty: !`git -C #{File.expand_path('../..', __dir__)} status --porcelain -- ext lib 2>/dev/null`.strip.empty?,
    cpu: `sysctl -n machdep.cpu.brand_string`.strip,
  },
  results: results,
}
dir = File.expand_path('../../experiments/artifacts', __dir__)
Dir.mkdir(dir) unless Dir.exist?(dir)
path = File.join(dir, "bench-#{variant}-#{run_idx}.json")
File.write(path, JSON.pretty_generate(out))
puts path

# rubocop:enable Naming/MethodParameterName, Style/FormatStringToken
