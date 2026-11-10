#!/usr/bin/ruby
require 'json'

directory = File.expand_path(ARGV.fetch(0))
rows = File.readlines(File.join(directory, 'results.jsonl')).map { |line| JSON.parse(line) }
baseline = ARGV[1] || rows.first.fetch('strategy')
candidate = ARGV[2] || (rows.map { |row| row.fetch('strategy') }.uniq - [baseline]).first
abort 'Specify baseline and candidate strategies' unless candidate
pairs = rows.group_by { |row| [row.fetch('board_sha256'), row.fetch('seed')] }.values.map do |group|
  first = group.find { |row| row['strategy'] == baseline }
  second = group.find { |row| row['strategy'] == candidate }
  next unless first && second
  raise 'Invalid comparison result' unless [first, second].all? { |row| row['independently_validated'] && row['score'].is_a?(Integer) }
  {board: first['board'], seed: first['seed'], baseline: first['score'], candidate: second['score'],
   delta: second['score'] - first['score'], baseline_seconds: first['seconds'], candidate_seconds: second['seconds'],
   trials_ratio: second['trials'].to_f / [first['trials'], 1].max}
end.compact
abort 'No complete paired comparisons yet' if pairs.empty?
summary = {baseline: baseline, candidate: candidate, paired_boards: pairs.size,
           baseline_mean: pairs.sum { |pair| pair[:baseline] }.to_f / pairs.size,
           candidate_mean: pairs.sum { |pair| pair[:candidate] }.to_f / pairs.size,
           improved: pairs.count { |pair| pair[:delta] > 0 }, tied: pairs.count { |pair| pair[:delta] == 0 },
           regressed: pairs.count { |pair| pair[:delta] < 0 },
           max_candidate_seconds: pairs.map { |pair| pair[:candidate_seconds] }.max,
           mean_trials_ratio: pairs.sum { |pair| pair[:trials_ratio] } / pairs.size, pairs: pairs}
File.write(File.join(directory, 'comparison.json'), JSON.pretty_generate(summary))
puts JSON.generate(summary.reject { |key, _| key == :pairs })
