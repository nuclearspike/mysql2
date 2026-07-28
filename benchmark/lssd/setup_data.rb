# Deterministic benchmark data generator — reference_set.mysql2.bench_tables 1.0.0
# Idempotent: skips tables whose row counts already match. Seed pinned to 42.
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'mysql2'
require 'yaml'

creds = YAML.load_file(File.expand_path('../../spec/configuration.yml', __dir__))['root']
client = Mysql2::Client.new(host: '127.0.0.1', username: creds['username'], password: creds['password'])
client.query 'CREATE DATABASE IF NOT EXISTS mysql2_bench'
client.query 'USE mysql2_bench'

DDL = {
  't_ints' => "CREATE TABLE t_ints (id BIGINT NOT NULL PRIMARY KEY, #{(1..10).map { |i| "c#{i} INT NOT NULL" }.join(', ')})",
  't_strings' => "CREATE TABLE t_strings (id BIGINT NOT NULL PRIMARY KEY, #{(1..10).map { |i| "s#{i} VARCHAR(64) NOT NULL" }.join(', ')}) CHARACTER SET utf8mb4",
  't_datetimes' => "CREATE TABLE t_datetimes (id BIGINT NOT NULL PRIMARY KEY, #{(1..6).map { |i| "d#{i} DATETIME(6) NOT NULL" }.join(', ')})",
  't_mixed' => 'CREATE TABLE t_mixed (id BIGINT NOT NULL PRIMARY KEY, name VARCHAR(64) NOT NULL, email VARCHAR(64) NOT NULL, city VARCHAR(64) NOT NULL, status VARCHAR(16) NOT NULL, age INT NOT NULL, score INT NOT NULL, created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL, flag TINYINT(1) NOT NULL, amount DECIMAL(10,2) NOT NULL, body VARCHAR(255) NOT NULL) CHARACTER SET utf8mb4',
  't_wide' => "CREATE TABLE t_wide (id BIGINT NOT NULL PRIMARY KEY, #{(1..13).map { |i| "i#{i} INT NOT NULL" }.join(', ')}, #{(1..13).map { |i| "v#{i} VARCHAR(32) NOT NULL" }.join(', ')}, #{(1..13).map { |i| "t#{i} DATETIME NOT NULL" }.join(', ')}) CHARACTER SET utf8mb4",
  't_big' => 'CREATE TABLE t_big (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, a INT NOT NULL, b VARCHAR(32) NOT NULL)',
}.freeze

EXPECTED_ROWS = { 't_ints' => 50_000, 't_strings' => 50_000, 't_datetimes' => 50_000,
                  't_mixed' => 50_000, 't_wide' => 5_000, 't_big' => 2_048_000 }.freeze

def row_count(client, table)
  client.query("SELECT COUNT(*) AS c FROM #{table}").first['c']
rescue Mysql2::Error
  -1
end

def dt(rng)
  t = Time.at(1_500_000_000 + rng.rand(500_000_000), rng.rand(1_000_000)).utc
  t.strftime('%Y-%m-%d %H:%M:%S.%6N')
end

WORDS = %w[alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa].freeze
def word(rng, n = 3)
  Array.new(n) { WORDS[rng.rand(WORDS.size)] }.join('-') + rng.rand(10_000).to_s
end

def insert_batches(client, table, total, batch = 1000)
  rng = Random.new(42)
  inserted = 0
  while inserted < total
    n = [batch, total - inserted].min
    rows = Array.new(n) do
      inserted += 1
      yield(rng, inserted)
    end
    client.query "INSERT INTO #{table} VALUES #{rows.join(',')}"
  end
end

DDL.each do |table, ddl|
  if row_count(client, table) == EXPECTED_ROWS[table]
    puts "#{table}: already populated"
    next
  end
  client.query "DROP TABLE IF EXISTS #{table}"
  client.query ddl
  case table
  when 't_ints'
    insert_batches(client, table, 50_000) { |rng, id| "(#{id},#{Array.new(10) { rng.rand(2_000_000_000) - 1_000_000_000 }.join(',')})" }
  when 't_strings'
    insert_batches(client, table, 50_000) { |rng, id| "(#{id},#{Array.new(10) { "'#{word(rng)}'" }.join(',')})" }
  when 't_datetimes'
    insert_batches(client, table, 50_000) { |rng, id| "(#{id},#{Array.new(6) { "'#{dt(rng)}'" }.join(',')})" }
  when 't_mixed'
    insert_batches(client, table, 50_000) do |rng, id|
      "(#{id},'#{word(rng, 2)}','u#{rng.rand(10**9)}@example.com','#{WORDS[rng.rand(16)]}','#{%w[active idle gone][rng.rand(3)]}',#{rng.rand(90)},#{rng.rand(10_000)},'#{dt(rng)}','#{dt(rng)}',#{rng.rand(2)},#{format('%.2f', rng.rand * 99_999)},'#{word(rng, 8)}')"
    end
  when 't_wide'
    insert_batches(client, table, 5_000) do |rng, id|
      "(#{id},#{Array.new(13) { rng.rand(1_000_000) }.join(',')},#{Array.new(13) { "'#{word(rng, 1)}'" }.join(',')},#{Array.new(13) { "'#{dt(rng)[0, 19]}'" }.join(',')})"
    end
  when 't_big'
    insert_batches(client, table, 1000) { |rng, _id| "(NULL,#{rng.rand(1_000_000)},'#{word(rng, 1)}')" }
    11.times { client.query 'INSERT INTO t_big (a, b) SELECT a, b FROM t_big' }
  end
  puts "#{table}: generated #{row_count(client, table)} rows"
end

puts '--- checksums (reference_set pin) ---'
DDL.each_key do |t|
  r = client.query("CHECKSUM TABLE #{t}").first
  puts "#{t}: rows=#{row_count(client, t)} checksum=#{r['Checksum']}"
end
