require 'json'
require 'open3'
require 'digest'

prices = (0...16).map do |mask|
  p = Array.new(10, 0)
  (1..4).each { |v| p[v] = 1 + ((mask >> (v - 1)) & 1) }
  p[5] = 1
  p[6] = [0, 2-p[4], 3-2*p[2], 3-p[1]-p[3], 4-2*p[1]-p[2], 5-4*p[1]].max
  p[7] = [0, 2-p[3], 3-p[1]-p[2], 4-3*p[1]].max
  p[8] = [0, 2-p[2], 3-2*p[1]].max
  p[9] = [0, 2-p[1]].max
  p
end
random = Random.new(2301)
10000.times do
  counts = Array.new(10) { random.rand(161) }
  reference = prices.min_by { |p| (1..9).sum { |v| p[v] * counts[v] } }
  p = Array.new(10, 1); p[0] = 0
  six = [0, counts[4] - counts[6]].min
  eight = [0, counts[2] - counts[8] + six].min
  seven = [0, counts[3] - counts[7]].min
  if counts[1] - counts[9] + eight + seven < 0
    p[1] = 2; p[9] = 0
    if seven < 0 then p[3] = 2; p[7] = 0 end
    if eight < 0
      p[2] = 2; p[8] = 0
      if six < 0 then p[4] = 2; p[6] = 0 end
    end
  end
  raise 'Closed-form price mismatch' unless reference == p
end

session = File.expand_path('../..', __dir__)
reference_solver = File.expand_path('../mixed-v1/Solver', __dir__)
candidate_solver = File.join(__dir__, 'Solver')
rows = []
$stdout.sync = true
[59, 33, 36, 41, 47, 51].each_with_index do |number, index|
  board = File.join(session, format('round-%03d', number), 'initial-board.txt')
  results = [reference_solver, candidate_solver].each_with_index.map do |solver, variant|
    output, error, status = Open3.capture3(solver, '--board', board, '--strategy', 'scarcity',
                                        '--seconds', '32', '--trials', '10000', '--seed', (2301 + index).to_s, '--full-search')
    raise error unless status.success?
    File.write(File.join(__dir__, format('fixed-%03d-%d.json', number, variant)), output)
    JSON.parse(output)
  end
  first, second = results
  raise 'Fixed-trial path mismatch' unless first['score'] == second['score'] && first['moves'] == second['moves'] && first['trials'] == second['trials']
  row = {round: number, score: first['score'], trials: first['trials'], identical_path: true,
         reference_seconds: first['seconds'], candidate_seconds: second['seconds']}
  rows << row
  puts JSON.generate(row)
end
summary = {random_price_vectors_checked: 10000, fixed_trial_boards: rows.size, all_passed: true,
           reference_sha256: Digest::SHA256.file(reference_solver).hexdigest,
           candidate_sha256: Digest::SHA256.file(candidate_solver).hexdigest, rows: rows}
File.write(File.join(__dir__, 'equivalence.json'), JSON.pretty_generate(summary))
