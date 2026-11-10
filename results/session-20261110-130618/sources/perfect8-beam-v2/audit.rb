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
skipped.each do |round|
  folder = File.join(directory, round.fetch('round'))
  skipped_required.each do |name|
    issues << {round: round['round'], missing_or_empty: name} unless File.size?(File.join(folder, name))
  end
  unless File.size?(File.join(folder, 'abandoned.png')) || File.size?(File.join(folder, 'settlement.png'))
    issues << {round: round['round'], missing_or_empty: 'Abandonment confirmation evidence'}
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
           unverified_settlements: settled.reject { |round| round['fully_verified'] || round['intentional_abandon'] }.map do |round|
             {round: round['round'], score: round['settlement_score'], errors: round['errors']}
           end,
           empty_round_directories: empty_rounds, issues: issues, passed: issues.empty? && empty_rounds.empty?}
File.write(File.join(directory, 'artifact-audit.json'), JSON.pretty_generate(summary))
puts JSON.generate(summary)
exit(summary[:passed] ? 0 : 1)
