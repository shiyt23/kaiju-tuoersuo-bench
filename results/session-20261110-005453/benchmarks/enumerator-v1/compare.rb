require 'json'
require 'open3'
require 'time'

$stdout.sync = true
root = File.expand_path('../../../..', __dir__)
variants = {'original' => File.join(root, 'Solver'), 'optimized' => File.join(__dir__, 'Solver')}
boards = %w[015 017 018 024]
boards.each_with_index do |number, index|
  path = File.join(root, 'runs/session-20261110-005453', "round-#{number}", 'initial-board.txt')
  %w[repair fastrepair].each do |strategy|
    results = {}
    variants.each do |name, executable|
      stdout, stderr, status = Open3.capture3(executable, '--board', path, '--strategy', strategy,
                                             '--seconds', '32', '--trials', '100000', '--seed', (1001 + index).to_s,
                                             '--full-search', '--target', '160')
      abort stderr unless status.success?
      plan = JSON.parse(stdout)
      raise 'Budget exhausted before equal trial count' unless plan.fetch('trials') == 100000
      values = File.read(path).split.map(&:to_i)
      rows, cols = values.shift(2)
      before = values.count { |value| value > 0 }
      plan.fetch('moves').each do |move|
        indices = (move.fetch('top')..move.fetch('bottom')).flat_map do |r|
          (move.fetch('left')..move.fetch('right')).map { |c| r * cols + c }
        end
        raise 'Invalid bounds' unless indices.all? { |cell| cell >= 0 && cell < rows * cols }
        raise 'Invalid sum' unless indices.sum { |cell| values[cell] } == 10
        raise 'Invalid count' unless indices.count { |cell| values[cell] > 0 } == move.fetch('count')
        indices.each { |cell| values[cell] = 0 }
      end
      raise 'Invalid score' unless before - values.count { |value| value > 0 } == plan.fetch('score')
      File.write(File.join(__dir__, "#{number}-#{strategy}-#{name}.json"), stdout)
      results[name] = plan
    end
    identical = results['original']['moves'] == results['optimized']['moves']
    row = {board: number, strategy: strategy, trials: 100000, identical_path: identical,
           original_seconds: results['original']['seconds'], optimized_seconds: results['optimized']['seconds'],
           speedup: results['original']['seconds'] / results['optimized']['seconds'], score: results['optimized']['score']}
    File.open(File.join(__dir__, 'results.jsonl'), 'a') { |file| file.puts JSON.generate(row) }
    puts JSON.generate(row)
    raise 'Optimization changed the fixed-trial result' unless identical
  end
end
