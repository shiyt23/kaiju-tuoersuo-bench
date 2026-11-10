import Foundation

let maximumSearchSeconds: Double = 32

struct PlannedRectangle: Codable {
    let top: Int, left: Int, bottom: Int, right: Int, count: Int
}
struct SolverResult: Codable {
    var strategy: String? = nil
    let score: Int
    let trials: Int
    let seconds: Double
    let seed: UInt64
    let moves: [PlannedRectangle]
}
struct ValidatedPlan {
    let result: SolverResult
    let moves: [Move]
}
extension Board {
    var remaining: Int { values.filter { $0 > 0 }.count }
    var points: Int { rows * cols - remaining }
    func validate() throws {
        guard (1...30).contains(rows), (1...30).contains(cols), values.count == rows * cols,
              values.allSatisfy({ (0...9).contains($0) }) else { throw Failure("Invalid board dimensions or cell values.") }
    }
    func validatedMove(_ rectangle: PlannedRectangle) throws -> Move {
        guard rectangle.top >= 0, rectangle.left >= 0,
              rectangle.bottom >= rectangle.top, rectangle.right >= rectangle.left,
              rectangle.bottom < rows, rectangle.right < cols else { throw Failure("Solver returned an out-of-bounds rectangle.") }
        let indices = (rectangle.top...rectangle.bottom).flatMap { r in
            (rectangle.left...rectangle.right).map { r * cols + $0 }
        }.filter { values[$0] > 0 }
        guard indices.count == rectangle.count, indices.reduce(0, { $0 + values[$1] }) == 10 else {
            throw Failure("Planned move does not sum to ten on this board.")
        }
        return Move(top: rectangle.top, left: rectangle.left, bottom: rectangle.bottom, right: rectangle.right, cells: indices)
    }
    func validatedMove(_ move: Move) throws -> Move {
        let result = try validatedMove(PlannedRectangle(top: move.top, left: move.left, bottom: move.bottom, right: move.right, count: move.cells.count))
        guard result.cells == move.cells else { throw Failure("Saved move does not match the current board.") }
        return result
    }
    var solverText: String { "\(rows) \(cols)\n" + values.map(String.init).joined(separator: " ") + "\n" }
    static func readFixture(_ path: String) throws -> Board {
        let tokens = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace)
        let numbers = tokens.compactMap { Int($0) }
        guard tokens.count == numbers.count, numbers.count >= 2 else { throw Failure("Malformed board file.") }
        let board = Board(rows: numbers[0], cols: numbers[1], values: Array(numbers.dropFirst(2)))
        try board.validate()
        return board
    }
}
func solverURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("Solver")
}
func runSolver(_ board: Board, seconds: Double, target: Int, seed: UInt64, listOnly: Bool = false) throws -> SolverResult {
    try board.validate()
    guard seconds.isFinite, seconds > 0, seconds <= maximumSearchSeconds, (0...board.values.count).contains(target) else { throw Failure("Search budget must be greater than zero and at most 32 seconds; target must fit the board.") }
    let executable = solverURL()
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure("Solver executable is missing. Run ./build.sh first.") }
    let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".board")
    try board.solverText.write(to: input, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: input) }
    let process = Process(), output = Pipe()
    process.executableURL = executable
    process.arguments = ["--board", input.path, "--seconds", String(seconds), "--target", String(target), "--seed", String(seed)]
    if let strategy = option("--strategy") { process.arguments?.append(contentsOf: ["--strategy", strategy]) }
    if listOnly { process.arguments?.append("--moves") }
    if args.contains("--best-effort") { process.arguments?.append("--full-search") }
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure("Solver failed; no mouse input will be sent.") }
    return try JSONDecoder().decode(SolverResult.self, from: data)
}
func planGame(_ board: Board, seconds: Double, target: Int, seed: UInt64) throws -> ValidatedPlan {
    let result = try runSolver(board, seconds: seconds, target: max(0, target - board.points), seed: seed)
    var replay = board
    var moves: [Move] = []
    for rectangle in result.moves {
        let move = try replay.validatedMove(rectangle)
        replay = replay.removing(move)
        moves.append(move)
    }
    guard board.remaining - replay.remaining == result.score else { throw Failure("Solver score differs from independently replayed score.") }
    return ValidatedPlan(result: result, moves: moves)
}

func testPlanner() throws {
    // Compare the optimized C++ enumerator with the independent Swift brute-force
    // enumerator, including zero gaps and strips whose column sums exceed ten.
    var random: UInt64 = 0xC0FFEE
    func next() -> UInt64 { random = random &* 6364136223846793005 &+ 1; return random }
    for _ in 0..<30 {
        let rows = Int(next() % 6) + 1, cols = Int(next() % 6) + 1
        let board = Board(rows: rows, cols: cols, values: (0..<(rows * cols)).map { _ in Int(next() % 10) })
        let expected = Set(board.moves().map { $0.cells.map(String.init).joined(separator: ",") })
        let result = try runSolver(board, seconds: 1, target: board.values.count, seed: 1, listOnly: true)
        let observed = try Set(result.moves.map { try board.validatedMove($0).cells.map(String.init).joined(separator: ",") })
        guard expected == observed, observed.count == result.moves.count else { throw Failure("Optimized move enumeration disagrees with exhaustive reference.") }
    }
    let sample = Board(rows: 1, cols: 3, values: [9, 1, 2])
    do {
        _ = try sample.validatedMove(PlannedRectangle(top: 0, left: 0, bottom: 0, right: 2, count: 3))
        throw Failure("Invalid move was accepted.")
    } catch let error as Failure where error.description.contains("does not sum") { }
    print("Planner checks passed: 30 exhaustive move-set comparisons and invalid-plan rejection.")
}
