root = File.expand_path('../../..', __dir__)
session = 'runs/session-20261110-005453'
jobs = [
  ['tailbound-v1', 'comparison', 'portfolio,boundedportfolio', 2101, [33, 36, 39, 41, 43, 47]],
  ['mixed-v1', 'comparison', 'portfolio,portfolio8,mixedportfolio', 2201, [59, 56, 55, 53, 52, 49]]
]
$stdout.sync = true
Dir.chdir(root) do
  jobs.each do |experiment, batch, strategies, seed, rounds|
    output = File.join(session, 'benchmarks', experiment, batch)
    abort "Refusing duplicate benchmark: #{output}" if File.exist?(File.join(output, 'results.jsonl'))
    environment = {'GAME_BENCH_STRATEGIES' => strategies, 'GAME_BENCH_SEED_BASE' => seed.to_s,
                   'GAME_BENCH_SOLVER' => File.join(root, session, 'benchmarks', experiment, 'Solver')}
    boards = rounds.map { |index| File.join(session, format('round-%03d', index), 'initial-board.txt') }
    abort 'Benchmark failed' unless system(environment, '/usr/bin/ruby', 'benchmark.rb', output, *boards)
    names = strategies.split(',')
    names.drop(1).each do |candidate|
      abort 'Comparison failed' unless system('/usr/bin/ruby', 'benchmark_report.rb', output, names.first, candidate, "comparison-#{candidate}.json")
    end
    if names.size == 3
      abort 'Comparison failed' unless system('/usr/bin/ruby', 'benchmark_report.rb', output, names[1], names[2], 'comparison-eight-workers.json')
    end
  end
end
