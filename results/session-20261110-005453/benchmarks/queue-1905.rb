require 'fileutils'

root = File.expand_path('../../..', __dir__)
session = 'runs/session-20261110-005453'
jobs = [
  ['cooperative-v1', 'holdout', 'portfolio,cooperative', 1801, [17, 21, 28, 34, 48, 51]],
  ['scarcity-v1', 'holdout', 'portfolio,scarcityportfolio', 1901, [17, 21, 28, 34, 48, 51]],
  ['portfolio8-v1', 'comparison', 'portfolio,portfolio8', 2001, [33, 43, 47, 48, 50, 54]]
]
$stdout.sync = true
Dir.chdir(root) do
  jobs.each do |experiment, batch, strategies, seed, rounds|
    output = File.join(session, 'benchmarks', experiment, batch)
    abort "Refusing to append duplicate benchmark: #{output}" if File.exist?(File.join(output, 'results.jsonl'))
    environment = {'GAME_BENCH_STRATEGIES' => strategies, 'GAME_BENCH_SEED_BASE' => seed.to_s,
                   'GAME_BENCH_SOLVER' => File.join(root, session, 'benchmarks', experiment, 'Solver')}
    boards = rounds.map { |index| File.join(session, format('round-%03d', index), 'initial-board.txt') }
    abort 'Benchmark failed' unless system(environment, '/usr/bin/ruby', 'benchmark.rb', output, *boards)
    abort 'Comparison failed' unless system('/usr/bin/ruby', 'benchmark_report.rb', output, *strategies.split(','))
  end
end
