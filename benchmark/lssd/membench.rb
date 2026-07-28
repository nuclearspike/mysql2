# Memory scenario: rows-array capacity preallocation under cache_rows: false (H6)
# Usage: ruby benchmark/lssd/membench.rb <variant-name>
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'mysql2'
require 'yaml'
require 'json'
require 'time'
require 'objspace'

variant = ARGV[0] or abort 'usage: membench.rb <variant>'
creds = YAML.load_file(File.expand_path('../../spec/configuration.yml', __dir__))['root']
client = Mysql2::Client.new(host: '127.0.0.1', username: creds['username'], password: creds['password'], database: 'mysql2_bench')

def rss_kb
  `ps -o rss= -p #{Process.pid}`.to_i
end

GC.start
base = rss_kb

result = client.query('SELECT * FROM t_big', cache_rows: false)
rows_return = result.each { |_| }
rows_memsize = ObjectSpace.memsize_of(rows_return)
peak = rss_kb
result.free
result = nil # rubocop:disable Lint/UselessAssignment
rows_return = nil # rubocop:disable Lint/UselessAssignment
GC.start
after_free = rss_kb

out = { variant: variant, ts: Time.now.utc.iso8601,
        rows_array_memsize_bytes: rows_memsize,
        rss_base_kb: base, rss_peak_kb: peak, rss_after_free_kb: after_free, }
puts JSON.pretty_generate(out)
dir = File.expand_path('../../experiments/artifacts', __dir__)
Dir.mkdir(dir) unless Dir.exist?(dir)
File.write(File.join(dir, "membench-#{variant}.json"), JSON.pretty_generate(out))
