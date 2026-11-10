#!/usr/bin/ruby
require 'json'
require 'time'

directory = File.expand_path(ARGV.fetch(0))
report = JSON.parse(File.read(File.join(directory, 'report.json')))
required = %w[initial-board.txt initial.png plan.json checkpoint.json execution.log settlement.png result.json]
settled_required = %w[execution.log settlement.png settlement.ocr.json result.json]
issues = []
settled = report.fetch('rounds').select { |round| !round['settlement_score'].nil? }
settled.each do |round|
  folder = File.join(directory, round.fetch('round'))
  settled_required.each do |name|
    issues << {round: round['round'], missing_or_empty: name} unless File.size?(File.join(folder, name))
  end
end
verified = report.fetch('rounds').select { |round| round['fully_verified'] }
skipped = report.fetch('rounds').select { |round| round['intentional_abandon'] }
skipped_required = %w[initial.png initial-board.txt eligibility.json skip-request.json execution.log result.json]
skip_obstructions = Hash.new(0)
search_budget_restarts_checked = 0
def full_clear_obstructions(values)
  c = Array.new(10, 0)
  values.each { |v| c[v] += 1 if v > 0 }
  reasons = []
  reasons << 'digit_sum_not_divisible_by_ten' unless values.sum % 10 == 0
  reasons << 'digit_sum_exceeds_pair_capacity' if values.sum > 5 * values.count { |v| v > 0 }
  reasons << 'not_enough_ones_for_nines' if c[9] > c[1]
  return reasons unless reasons.empty?
  c[1] -= c[9]; c[9] = 0
  reasons << 'not_enough_complements_for_eights' if c[8] > c[2] + c[1] / 2
  reasons << 'not_enough_complements_for_sevens' if c[7] > c[3] + c[1]
  (2..4).each do |limit|
    available = (1..limit).sum { |v| v * c[v] }
    required = ((10 - limit)..8).sum { |v| (10 - v) * c[v] }
    reasons << "insufficient_small_digit_sum_#{limit}" if available < required
  end
  if c[5].odd?
    reachable = 1
    (1..4).each { |v| [c[v], 5 / v].min.times { reachable |= reachable << v } }
    reasons << 'unpaired_five_has_no_complement' if reachable & (1 << 5) == 0
  end
  (1..4).each do |v|
    pairs = [c[v], c[10 - v]].min
    c[v] -= pairs; c[10 - v] -= pairs
  end
  c[5] %= 2
  residual_sum = (1..9).sum { |v| v * c[v] }
  reasons << 'too_few_tiles_after_pair_cancellation' if c.sum < 3 * (residual_sum / 10)
  reasons
end
skipped.each do |round|
  folder = File.join(directory, round.fetch('round'))
  skipped_required.each do |name|
    issues << {round: round['round'], missing_or_empty: name} unless File.size?(File.join(folder, name))
  end
  unless File.size?(File.join(folder, 'abandoned.png')) || File.size?(File.join(folder, 'settlement.png'))
    issues << {round: round['round'], missing_or_empty: 'Abandonment confirmation evidence'}
  end
  begin
    numbers = File.read(File.join(folder, 'initial-board.txt')).split.map { |v| Integer(v) }
    values = numbers.drop(2)
    eligibility = JSON.parse(File.read(File.join(folder, 'eligibility.json')))
    request = JSON.parse(File.read(File.join(folder, 'skip-request.json')))
    if request['reason'] == 'no_full_clear_plan_within_budget'
      plan = JSON.parse(File.read(File.join(folder, 'plan.json')))
      replay = values.dup
      valid = numbers[0] * numbers[1] == values.size && eligibility['fullClearEligible'] == true
      plan.fetch('moves').each do |move|
        valid &&= move['top'] >= 0 && move['left'] >= 0 && move['bottom'] < numbers[0] && move['right'] < numbers[1]
        indices = (move['top']..move['bottom']).flat_map { |row| (move['left']..move['right']).map { |col| row * numbers[1] + col } }
        valid &&= indices.sum { |i| replay[i].to_i } == 10 && indices.count { |i| replay[i].to_i > 0 } == move['count']
        indices.each { |i| replay[i] = 0 }
      end
      score = values.count { |v| v > 0 } - replay.count { |v| v > 0 }
      valid &&= score == plan['score'] && score < values.count { |v| v > 0 }
      if valid
        search_budget_restarts_checked += 1
      else
        issues << {round: round['round'], error: 'Search-budget restart plan did not independently verify'}
      end
    else
      reasons = full_clear_obstructions(values)
      if numbers[0] * numbers[1] != values.size || eligibility['fullClearEligible'] != false || reasons.empty?
        issues << {round: round['round'], error: 'Full-clear impossibility proof did not independently verify'}
      else
        reasons.each { |reason| skip_obstructions[reason] += 1 }
      end
    end
  rescue Errno::ENOENT, JSON::ParserError, ArgumentError => error
    issues << {round: round['round'], error: error.message}
  end
end
verified.each do |round|
  folder = File.join(directory, round.fetch('round'))
  (required - settled_required).each do |name|
    issues << {round: round['round'], missing_or_empty: name} unless File.size?(File.join(folder, name))
  end
  unless round['planned_score'] == round['verified_score'] && round['verified_score'] == round['settlement_score']
    issues << {round: round['round'], error: 'Planned, executed, and settlement scores differ'}
  end
end
empty_rounds = Dir.glob(File.join(directory, 'round-*')).select { |folder| Dir.children(folder).empty? }
summary = {checked_at: Time.now.utc.iso8601, rounds_seen: report.fetch('rounds').size,
           settled_rounds_checked: settled.size, required_files_per_settled_round: settled_required,
           fully_verified_rounds_checked: verified.size, required_files_per_verified_round: required,
           intentionally_skipped_rounds_checked: skipped.size,
           independently_verified_skip_obstructions: skip_obstructions,
           search_budget_restart_plans_checked: search_budget_restarts_checked,
           unverified_settlements: settled.reject { |round| round['fully_verified'] || round['intentional_abandon'] }.map do |round|
             {round: round['round'], score: round['settlement_score'], errors: round['errors']}
           end,
           empty_round_directories: empty_rounds, issues: issues, passed: issues.empty? && empty_rounds.empty?}
File.write(File.join(directory, 'artifact-audit.json'), JSON.pretty_generate(summary))
puts JSON.generate(summary)
exit(summary[:passed] ? 0 : 1)
