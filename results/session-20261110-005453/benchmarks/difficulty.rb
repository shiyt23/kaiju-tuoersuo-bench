require 'json'

directory = File.expand_path('..', __dir__)
patterns = []
enumerate = lambda do |value, remaining, counts|
  if value == 10
    patterns << counts.dup if remaining == 0
  else
    (0..remaining / value).each do |count|
      counts[value] = count
      enumerate.call(value + 1, remaining - count * value, counts)
    end
  end
end
enumerate.call(1, 10, Array.new(10, 0))
# Nonnegative digit prices that pay at least one unit per removed tile for
# every sum-ten group. Their total on the initial board is an upper bound,
# even before geometric restrictions; this is not a claim of attainability.
prices = (0...16).map do |mask|
  p = [0] + Array.new(9, 1)
  (1..4).each { |value| p[value] += (mask >> (value - 1)) & 1 }
  (6..9).each do |large|
    p[large] = [0, patterns.select { |group| group[large] > 0 }.map do |group|
      group.sum - (1..9).reject { |value| value == large }.sum { |value| group[value] * p[value] }
    end.max].max
  end
  raise 'Infeasible bound prices' unless patterns.all? { |group| (1..9).sum { |v| group[v] * p[v] } >= group.sum }
  p
end
rows = Dir.glob(File.join(directory, 'round-*', 'initial-board.txt')).sort.map do |path|
  values = File.read(path).split.map(&:to_i).drop(2)
  upper = prices.map { |p| values.sum { |value| p[value] } }.min
  folder = File.dirname(path)
  plan_path = File.join(folder, 'plan.json')
  planned = File.exist?(plan_path) ? JSON.parse(File.read(plan_path))['score'] : nil
  raise 'Bound contradicted by a validated path' if planned && planned > upper
  {round: File.basename(folder), relaxed_upper_bound: upper, planned_score: planned,
   gap_to_bound: planned && upper - planned, not_ruled_out_150: upper >= 150}
end
summary = {sum_ten_patterns_verified: patterns.size, feasible_price_vectors: prices.size,
           boards: rows.size, upper_bound_below_150: rows.count { |r| r[:relaxed_upper_bound] < 150 },
           rows: rows}
File.write(File.join(__dir__, 'difficulty.json'), JSON.pretty_generate(summary))
puts JSON.generate(summary.reject { |key, _| key == :rows }.merge(recent: rows.last(6)))
