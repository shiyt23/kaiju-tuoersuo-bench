#!/usr/bin/ruby
require 'json'
require 'time'

directory = File.expand_path(ARGV.fetch(0))
report = JSON.parse(File.read(File.join(directory, 'report.json')))
required = %w[initial-board.txt initial.png plan.json checkpoint.json execution.log settlement.png result.json]
issues = []
verified = report.fetch('rounds').select { |round| round['fully_verified'] }
verified.each do |round|
  folder = File.join(directory, round.fetch('round'))
  required.each do |name|
    issues << {round: round['round'], missing_or_empty: name} unless File.size?(File.join(folder, name))
  end
  unless round['planned_score'] == round['verified_score'] && round['verified_score'] == round['settlement_score']
    issues << {round: round['round'], error: 'Planned, executed, and settlement scores differ'}
  end
end
empty_rounds = Dir.glob(File.join(directory, 'round-*')).select { |folder| Dir.children(folder).empty? }
summary = {checked_at: Time.now.utc.iso8601, rounds_seen: report.fetch('rounds').size,
           fully_verified_rounds_checked: verified.size, required_files_per_verified_round: required,
           empty_round_directories: empty_rounds, issues: issues, passed: issues.empty? && empty_rounds.empty?}
File.write(File.join(directory, 'artifact-audit.json'), JSON.pretty_generate(summary))
puts JSON.generate(summary)
exit(summary[:passed] ? 0 : 1)
