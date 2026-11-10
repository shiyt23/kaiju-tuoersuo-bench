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
   finished: !result.empty?, intentional_abandon: result['intentional_abandon'] == true,
   abandoned_at: result['abandoned_at'],
   skip_reason: result['reason'],
   fully_verified: checkpoint['completed'] == true && result['settlement_score'] == verified,
   errors: log.lines.select { |line| line.start_with?('Error:') }.map(&:strip),
   evidence: File.join(File.basename(path), File.exist?(File.join(path, 'abandoned.png')) ? 'abandoned.png' : 'settlement.png')}
end
verified_rounds = rounds.select { |row| row[:fully_verified] }
scores = verified_rounds.map { |row| row[:settlement_score] }
session = read_json(File.join(directory, 'session.json'))
state = read_json(File.join(directory, 'state.json'))
events_path = File.join(directory, 'events.jsonl')
events = File.exist?(events_path) ? File.readlines(events_path).map do |line|
  JSON.parse(line) rescue nil
end.compact : []
finished = events.reverse.find { |event| event['event'] == 'session_finished' }
started_at = Time.parse(session['started_at']) rescue nil
observed_end = finished ? Time.parse(finished['time']) : Time.now.utc
best_rounds = verified_rounds.select { |row| row[:settlement_score] == scores.max }.map { |row| row[:round] }
summary = {updated_at: Time.now.utc.iso8601, rounds_started: rounds.size,
           rounds_finished: rounds.count { |row| row[:finished] },
           intentionally_skipped_rounds: rounds.count { |row| row[:intentional_abandon] },
           search_budget_restarts: rounds.count { |row| row[:intentional_abandon] && row[:skip_reason] == 'no_full_clear_plan_within_budget' },
           rounds_settled: rounds.count { |row| !row[:settlement_score].nil? },
           fully_verified_rounds: scores.size, best_fully_verified_score: scores.max,
           best_rounds: best_rounds, scores_above_123: scores.count { |score| score > 123 },
           requested_duration_seconds: session['minimum_duration_seconds'],
           observed_duration_seconds: started_at && (observed_end - started_at).round,
           minimum_end_at: session['minimum_end_at'], finished_at: finished && finished['time'],
           completed_rewarded_ads: events.count { |event| event['event'] == 'ad_closed_after_reward' },
           unlimited_renewals: events.select { |event| event['event'] == 'unlimited_renewed' },
           mean_fully_verified_score: scores.empty? ? nil : (scores.sum.to_f / scores.size).round(2),
           current_state: state, rounds: rounds}
File.write(File.join(directory, 'report.json.tmp'), JSON.pretty_generate(summary))
File.rename(File.join(directory, 'report.json.tmp'), File.join(directory, 'report.json'))
puts JSON.generate(summary.reject { |key, _| key == :rounds }.merge(recent: rounds.last(3)))
