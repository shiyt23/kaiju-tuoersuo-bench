require 'json'
require 'open3'

solver = File.join(__dir__, 'Solver')
cases = [
  {values: [1, 9, 8], score: 2, upper: 2, optimal: true},
  {values: [9, 9, 9], score: 0, upper: 2, optimal: false},
  {values: [1, 9, 8, 2], score: 4, upper: 4, optimal: true},
  {values: [8], score: 0, upper: 0, optimal: true},
  {values: [0], score: 0, upper: 0, optimal: true}
]
rows = []
cases.each_with_index do |example, index|
  path = File.join(__dir__, "case-#{index}.txt")
  File.write(path, "1 #{example[:values].size}\n#{example[:values].join(' ')}\n")
  (1..5).each do |seed|
    output, error, status = Open3.capture3(solver, '--board', path, '--seconds', '0.3', '--strategy', 'portfolio8', '--seed', seed.to_s, '--full-search')
    raise error unless status.success?
    result = JSON.parse(output)
    raise 'Wrong score or optimality certificate' unless result['score'] == example[:score] && result['scoreUpperBound'] == example[:upper] && result['provenOptimal'] == example[:optimal]
    raise 'Unproved state stopped prematurely' if !example[:optimal] && result['seconds'] < 0.2
    raise 'Proved state did not stop promptly' if example[:optimal] && result['seconds'] >= 0.2
    board = example[:values].dup
    result['moves'].each do |move|
      raise 'Unexpected move geometry' unless move['top'] == 0 && move['bottom'] == 0 && move['left'] >= 0 && move['right'] < board.size
      values = board[move['left']..move['right']]
      raise 'Invalid elimination' unless values.sum == 10 && values.count { |v| v > 0 } == move['count']
      (move['left']..move['right']).each { |cell| board[cell] = 0 }
    end
    raise 'Replay score mismatch' unless example[:values].count { |v| v > 0 } - board.count { |v| v > 0 } == result['score']
    rows << {case: index, seed: seed, score: result['score'], seconds: result['seconds'], proven_optimal: result['provenOptimal']}
  end
end
summary = {cases: cases.size, seeded_runs: rows.size, all_passed: true, rows: rows}
File.write(File.join(__dir__, 'checks.json'), JSON.pretty_generate(summary))
puts JSON.generate(summary.reject { |key, value| key == :rows })
