#!/usr/bin/ruby
require 'json'
require 'open3'
require 'fileutils'
require 'digest'
require 'time'

root = File.expand_path('..', __dir__)
output = File.expand_path(ARGV.fetch(0), root)
FileUtils.mkdir_p(output)
seconds = Float(ENV.fetch('GAME_BENCH_SECONDS', '32'))
abort 'Search seconds must be in (0, 60]' unless seconds.finite? && seconds > 0 && seconds <= 60
boards = ARGV.drop(1)
abort 'Provide output directory and board files' if boards.empty?
$stdout.sync = true
boards.each_with_index do |board, index|
  board = File.expand_path(board, root)
  seed = Integer(ENV.fetch('GAME_BENCH_SEED_BASE', '501')) + index
  strategies = ENV.fetch('GAME_BENCH_STRATEGIES', 'baseline,repair').split(',')
  strategies.reverse! if index.odd?
  strategies.each do |strategy|
    name = format('%02d-%s', index + 1, strategy)
    plan = File.join(output, name + '.json')
    command = [File.join(root, 'GameAssistant'), 'solve', '--board-file', board,
               '--target', '160', '--best-effort', '--search-seconds', seconds.to_s,
               '--seed', seed.to_s, '--strategy', strategy, '--out', plan]
    command.concat(['--solver-executable', ENV['GAME_BENCH_SOLVER']]) if ENV['GAME_BENCH_SOLVER']
    started = Time.now.utc
    stdout, stderr, status = Open3.capture3(*command, chdir: root)
    File.write(File.join(output, name + '.log'), stdout + stderr)
    row = {board: board, board_sha256: Digest::SHA256.file(board).hexdigest,
           strategy: strategy, seed: seed, started_at: started.iso8601,
           exit_code: status.exitstatus, independently_validated: status.success?,
           solver_sha256: Digest::SHA256.file(ENV.fetch('GAME_BENCH_SOLVER', File.join(root, 'Solver'))).hexdigest}
    if status.success?
      result = JSON.parse(File.read(plan))
      row.merge!(score: result.fetch('score'), seconds: result.fetch('seconds'),
                 trials: result.fetch('trials'), moves: result.fetch('moves').size,
                 workers: result['workers'], worker_scores: result['workerScores'])
    end
    File.open(File.join(output, 'results.jsonl'), 'a') { |file| file.puts(JSON.generate(row)) }
    puts JSON.generate(row)
    abort 'Benchmark failed independent validation' unless status.success?
  end
end
