import Cocoa
import CoreGraphics

struct RunCheckpoint: Codable {
    let version: Int
    let target: Int
    var minimumScore: Int? = nil
    var board: Board
    var moves: [Move]
    var pending: Move?
    var verifiedMoves: Int
    let imageWidth: Int
    let imageHeight: Int
    let grid: [Double]
    var completed: Bool
    func save(_ url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    mutating func reconcile(_ observed: Board) throws {
        try observed.validate()
        guard observed.rows == board.rows, observed.cols == board.cols else { throw Failure("Observed board dimensions changed.") }
        if let pending = pending, observed.values == board.removing(pending).values {
            board = observed
            moves.removeFirst()
            verifiedMoves += 1
            self.pending = nil
        } else if observed.values == board.values {
            pending = nil
        } else { throw Failure("Observed board matches neither side of the pending action; refusing recovery.") }
    }
    func validate() throws {
        try board.validate()
        guard version == 1, target > 0, target <= board.values.count, grid.count == 4,
              grid.allSatisfy(\.isFinite), grid[0] >= 0, grid[1] >= 0, grid[2] > 0, grid[3] > 0,
              imageWidth > 0, imageHeight > 0, verifiedMoves >= 0 else { throw Failure("Invalid checkpoint metadata.") }
        guard !completed || (pending == nil && moves.isEmpty) else { throw Failure("Completed checkpoint still has pending work.") }
        var replay = board
        if let pending = pending {
            guard let first = moves.first, first.cells == pending.cells,
                  first.top == pending.top, first.left == pending.left, first.bottom == pending.bottom, first.right == pending.right else {
                throw Failure("Pending action differs from saved plan.")
            }
        }
        for move in moves { replay = replay.removing(try replay.validatedMove(move)) }
        let required = minimumScore ?? target
        guard required >= 0, required <= target, replay.points >= required else { throw Failure("Saved plan cannot reach its required score.") }
    }
}
func playGame() throws {
    let runStarted = Date()
    guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { throw Failure("Screen recording and accessibility permissions are required.") }
    var window = try selectedWindow()
    let totalSeconds = Double(option("--seconds") ?? "120") ?? .nan
    let searchSeconds = Double(option("--search-seconds") ?? "32") ?? .nan
    let target = Int(option("--target") ?? "140") ?? 0
    guard let seed = UInt64(option("--seed") ?? "2") else { throw Failure("Seed must be an unsigned integer.") }
    guard totalSeconds.isFinite, totalSeconds > 0, totalSeconds <= 300,
          searchSeconds.isFinite, searchSeconds > 0, searchSeconds <= maximumSearchSeconds, searchSeconds < totalSeconds,
          (1...900).contains(target) else { throw Failure("Invalid time budget or target. Search budget must be greater than zero and at most 60 seconds.") }
    let deadline = Date().addingTimeInterval(totalSeconds)
    let directory = URL(fileURLWithPath: option("--output") ?? "runs/\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frameURL = directory.appendingPathComponent("latest.png")
    let stateURL = directory.appendingPathComponent("checkpoint.json")
    try focus(window)
    // Activation may unminimize a window; use its resulting geometry.
    window = try selectedWindow()
    var image = try capture(window, to: frameURL)
    let grid: Grid
    var state: RunCheckpoint
    if let resumePath = option("--resume") {
        state = try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: URL(fileURLWithPath: resumePath)))
        try state.validate()
        guard image.width == state.imageWidth, image.height == state.imageHeight else { throw Failure("Window was resized; checkpoint geometry must be recalibrated before resuming.") }
        grid = Grid(rect: CGRect(x: state.grid[0], y: state.grid[1], width: state.grid[2], height: state.grid[3]), rows: state.board.rows, cols: state.board.cols)
        if let pending = state.pending {
            let after = state.board.removing(pending)
            if (try? grid.recognize(image, expected: after)) != nil {
                try state.reconcile(after)
            } else {
                _ = try grid.recognize(image, expected: state.board)
                try state.reconcile(state.board)
            }
        } else { _ = try grid.recognize(image, expected: state.board) }
        print("Resuming with verified score \(state.board.points), \(state.moves.count) planned moves left.")
    } else {
        grid = try Grid.forImage(image)
        // The retry button starts a short reveal animation before all tiles exist.
        // Observe that transition before accepting the initial board.
        let revealDeadline = Date().addingTimeInterval(4)
        var initial: Board?
        while Date() < revealDeadline {
            if let observed = try? grid.recognize(image), observed.remaining == grid.rows * grid.cols {
                Thread.sleep(forTimeInterval: 0.25)
                image = try capture(window, to: frameURL)
                if (try? grid.recognize(image, expected: observed)) != nil {
                    initial = observed
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
            image = try capture(window, to: frameURL)
        }
        guard let board = initial else { throw Failure("No complete initial board appeared within four seconds; saved screenshot for review.") }
        try board.validate()
        // The reveal loop requires two consistent, complete frames.
        try Data(contentsOf: frameURL).write(to: directory.appendingPathComponent("initial.png"), options: .atomic)
        try board.solverText.write(to: directory.appendingPathComponent("initial-board.txt"), atomically: true, encoding: .utf8)
        print("Recognized \(board.remaining) digits. Searching for at least \(target) points...")
        fflush(stdout)
        let sum = board.values.reduce(0, +)
        let basicClearCondition = sum % 10 == 0 && sum <= 5 * board.remaining && board.values.filter { $0 == 9 }.count <= board.values.filter { $0 == 1 }.count
        let planningSeconds = args.contains("--full-clear-focus") && !basicClearCondition ? min(32, searchSeconds) : searchSeconds
        try writeObject(["digit_sum": sum, "basic_full_clear_condition": basicClearCondition,
                         "requested_search_seconds": searchSeconds, "used_search_seconds": planningSeconds],
                        to: directory.appendingPathComponent("planning-budget.json"))
        let plan = try planGame(board, seconds: planningSeconds, target: target, seed: seed)
        try JSONEncoder().encode(plan.result).write(to: directory.appendingPathComponent("plan.json"), options: .atomic)
        print("Validated plan: \(board.points + plan.result.score) points, \(plan.moves.count) moves, \(plan.result.trials) search trials in \(String(format: "%.2f", plan.result.seconds)) seconds.")
        guard board.points + plan.result.score >= target || args.contains("--best-effort") else {
            throw Failure("No \(target)-point path found within the search budget. Best validated path scores \(board.points + plan.result.score). No digits were clicked. Saved board can be searched again with another seed.")
        }
        state = RunCheckpoint(version: 1, target: target, board: board, moves: plan.moves, pending: nil, verifiedMoves: 0,
                              imageWidth: image.width, imageHeight: image.height,
                              grid: [grid.rect.minX, grid.rect.minY, grid.rect.width, grid.rect.height], completed: false)
        if args.contains("--best-effort") { state.minimumScore = min(target, board.points + plan.result.score) }
    }
    try state.save(stateURL)
    print("Executing verified plan. Switching to another application stops mouse input.")
    fflush(stdout)
    // A menu/overlay or manual play during planning must be detected before a drag.
    image = try capture(window, to: frameURL)
    _ = try grid.recognize(image, expected: state.board)
    let appearance = try BoardAppearance(image: image, grid: grid, board: state.board)
    let executionStarted = Date()
    while let move = state.moves.first {
        let moveStarted = Date()
        var verificationMethod = "ocr"
        guard Date() < deadline else { throw Failure("Time budget reached; checkpoint saved at \(stateURL.path).") }
        _ = try state.board.validatedMove(move)
        state.pending = move
        try state.save(stateURL) // Journal before input, so interruption cannot lose this action.
        let after = state.board.removing(move)
        var accepted = false
        for attempt in 0..<2 {
            try drag(move, grid: grid, image: image, window: window)
            for _ in 0..<(after.remaining == 0 ? 20 : 3) {
                Thread.sleep(forTimeInterval: 0.16)
                guard Date() < deadline else { throw Failure("Time budget reached during verification.") }
                image = try capture(window, to: frameURL)
                guard image.width == state.imageWidth, image.height == state.imageHeight else { throw Failure("Window resized during play; stopped.") }
                // Check every remaining glyph and every empty cell. Independently
                // rerun OCR periodically and for the final action; uncertainty
                // always falls back to OCR instead of accepting a partial match.
                if !args.contains("--ocr-only"), (state.verifiedMoves + 1) % 10 != 0, state.moves.count > 1,
                   (try? appearance.matches(image, grid: grid, expected: after)) == true {
                    verificationMethod = "appearance"
                    accepted = true
                    break
                }
                if (try? grid.recognize(image, expected: after)) != nil { accepted = true; break }
                if after.remaining == 0, state.moves.count == 1,
                   let labels = try? screenLabels(image), settlementScore(labels) == after.points {
                    verificationMethod = "settlement"
                    accepted = true
                    break
                }
            }
            if accepted { break }
            // Retry only if the entire pre-move board is still visible and unchanged.
            // Unknown screens and partial effects are never treated as a failed click.
            guard attempt == 0, (try? grid.recognize(image, expected: state.board)) != nil else {
                throw Failure("Move outcome is ambiguous. Screenshot and pending-action checkpoint saved in \(directory.path).")
            }
        }
        guard accepted else { throw Failure("Could not verify action.") }
        state.board = after
        state.pending = nil
        state.moves.removeFirst()
        state.verifiedMoves += 1
        try state.save(stateURL)
        try appendObject(["time": ISO8601DateFormatter().string(from: Date()), "move": state.verifiedMoves,
                          "verified_score": state.board.points, "move_seconds": Date().timeIntervalSince(moveStarted),
                          "verification": verificationMethod,
                          "elapsed_seconds": Date().timeIntervalSince(runStarted),
                          "rectangle": [move.top, move.left, move.bottom, move.right]],
                         to: directory.appendingPathComponent("actions.jsonl"))
        print("Verified score \(state.board.points); move \(state.verifiedMoves): \(move.description)")
        fflush(stdout)
    }
    state.completed = true
    try state.save(stateURL)
    try writeObject(["finished_at": ISO8601DateFormatter().string(from: Date()), "verified_score": state.board.points,
                     "verified_moves": state.verifiedMoves, "total_seconds": Date().timeIntervalSince(runStarted),
                     "execution_seconds": Date().timeIntervalSince(executionStarted)],
                    to: directory.appendingPathComponent("performance.json"))
    print("Plan complete: \(state.board.points) verified points (target \(state.target)). Waiting for the game's own settlement is still required.")
}

func testCheckpoint() throws {
    let board = Board(rows: 1, cols: 2, values: [1, 9])
    let move = Move(top: 0, left: 0, bottom: 0, right: 1, cells: [0, 1])
    let sample = RunCheckpoint(version: 1, target: 2, board: board, moves: [move], pending: move, verifiedMoves: 0, imageWidth: 200, imageHeight: 100, grid: [0, 0, 200, 100], completed: false)
    let restored = try JSONDecoder().decode(RunCheckpoint.self, from: JSONEncoder().encode(sample))
    try restored.validate()
    guard restored.board.values == [1, 9], restored.pending?.cells == [0, 1] else { throw Failure("Pending-action checkpoint round trip failed.") }
    var applied = restored
    try applied.reconcile(board.removing(move))
    try applied.reconcile(board.removing(move))
    guard applied.board.points == 2, applied.pending == nil, applied.moves.isEmpty, applied.verifiedMoves == 1 else { throw Failure("Applied action recovery double-counted a move.") }
    var unchanged = restored
    try unchanged.reconcile(board)
    guard unchanged.pending == nil, unchanged.moves.count == 1, unchanged.verifiedMoves == 0 else { throw Failure("Unapplied action recovery lost the retry.") }
    var unexpected = restored
    do { try unexpected.reconcile(Board(rows: 1, cols: 2, values: [9, 1])); throw Failure("Unrelated board was accepted.") }
    catch let error as Failure where error.description.contains("neither side") { }
    let malformed = Board(rows: 2, cols: 2, values: [1])
    do { try malformed.validate(); throw Failure("Malformed checkpoint was accepted.") }
    catch let error as Failure where error.description.contains("Invalid board") { }
    print("Checkpoint checks passed: applied/unapplied action recovery, idempotence, unexpected-board rejection, and malformed-board rejection.")
}
