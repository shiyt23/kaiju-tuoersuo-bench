#!/usr/bin/ruby
require 'json'
require 'time'

directory = File.expand_path(ARGV.fetch(0))
def read_json(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT, JSON::ParserError
  {}
end
rounds = Dir.glob(File.join(directory, 'round-*')).sort.map do |path|
  result = read_json(File.join(path, 'result.json'))
  plan = read_json(File.join(path, 'plan.json'))
  checkpoint = read_json(File.join(path, 'checkpoint.json'))
  provenance = read_json(File.join(path, 'provenance.json'))
  values = checkpoint.dig('board', 'values')
  verified = values && values.count(0)
  log = File.exist?(File.join(path, 'execution.log')) ? File.read(File.join(path, 'execution.log')) : ''
  {round: File.basename(path), started_at: provenance['started_at'],
   strategy: plan['strategy'] || provenance['strategy'] || 'baseline', seed: plan['seed'] || provenance['seed'],
   search_seconds: plan['seconds'], planned_score: plan['score'], verified_score: verified,
   verified_moves: checkpoint['verifiedMoves'], plan_completed: checkpoint['completed'] == true,
   settlement_score: result['settlement_score'], settled_at: result['settled_at'],
   fully_verified: checkpoint['completed'] == true && result['settlement_score'] == verified,
   errors: log.lines.select { |line| line.start_with?('Error:') }.map(&:strip),
   evidence: File.join(File.basename(path), 'settlement.png')}
end
verified_rounds = rounds.select { |row| row[:fully_verified] }
scores = verified_rounds.map { |row| row[:settlement_score] }
summary = {updated_at: Time.now.utc.iso8601, rounds_started: rounds.size,
           rounds_settled: rounds.count { |row| !row[:settlement_score].nil? },
           fully_verified_rounds: scores.size, best_fully_verified_score: scores.max,
           mean_fully_verified_score: scores.empty? ? nil : (scores.sum.to_f / scores.size).round(2),
           current_state: read_json(File.join(directory, 'state.json')), rounds: rounds}
File.write(File.join(directory, 'report.json.tmp'), JSON.pretty_generate(summary))
File.rename(File.join(directory, 'report.json.tmp'), File.join(directory, 'report.json'))
puts JSON.generate(summary.reject { |key, _| key == :rounds }.merge(recent: rounds.last(3)))
