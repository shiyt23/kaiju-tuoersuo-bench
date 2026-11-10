import Cocoa

// Digits never move or change in this game. A previously OCR-verified glyph can
// therefore certify an unchanged occupied cell without rerunning text recognition.
struct BoardAppearance {
    struct Glyph {
        let rows: [UInt32]
        let ink: Int
        func matches(_ other: Glyph) -> Bool {
            guard ink >= 20, other.ink >= 20 else { return false }
            let tolerance = max(4, min(ink, other.ink) / 12)
            for dy in -1...1 {
                for dx in -1...1 {
                    var difference = 0
                    for y in 0..<32 {
                        let sourceY = y + dy
                        var shifted: UInt32 = (0..<32).contains(sourceY) ? other.rows[sourceY] : 0
                        if dx < 0 { shifted >>= 1 }
                        if dx > 0 { shifted <<= 1 }
                        difference += (rows[y] ^ shifted).nonzeroBitCount
                        if difference > tolerance { break }
                    }
                    if difference <= tolerance { return true }
                }
            }
            return false
        }
    }
    let board: Board
    let glyphs: [Glyph?]
    static func glyph(_ image: CGImage, grid: Grid, cell: Int) throws -> Glyph {
        let cw = grid.rect.width / Double(grid.cols), ch = grid.rect.height / Double(grid.rows)
        let area = CGRect(x: grid.rect.minX + Double(cell % grid.cols) * cw,
                          y: grid.rect.minY + Double(cell / grid.cols) * ch,
                          width: cw, height: ch).insetBy(dx: cw * 0.22, dy: ch * 0.22)
        guard let tile = image.cropping(to: area) else { throw Failure("Cannot sample verified glyph.") }
        var pixels = [UInt8](repeating: 255, count: 32 * 32 * 4)
        guard let context = CGContext(data: &pixels, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure("Cannot create glyph context.") }
        context.interpolationQuality = .high
        context.draw(tile, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        var rows = [UInt32](repeating: 0, count: 32)
        var ink = 0
        for y in 0..<32 {
            for x in 0..<32 {
                let i = (y * 32 + x) * 4
                if pixels[i] < 110 && pixels[i + 1] < 110 && pixels[i + 2] < 110 {
                    rows[y] |= UInt32(1) << x
                    ink += 1
                }
            }
        }
        return Glyph(rows: rows, ink: ink)
    }
    init(image: CGImage, grid: Grid, board: Board) throws {
        self.board = board
        glyphs = try board.values.indices.map { board.values[$0] > 0 ? try Self.glyph(image, grid: grid, cell: $0) : nil }
    }
    func matches(_ image: CGImage, grid: Grid, expected: Board) throws -> Bool {
        guard expected.rows == board.rows, expected.cols == board.cols else { return false }
        let paper = try grid.paperMask(image)
        guard paper.indices.allSatisfy({ paper[$0] == (expected.values[$0] > 0) }) else { return false }
        for cell in expected.values.indices where expected.values[cell] > 0 {
            guard expected.values[cell] == board.values[cell], let reference = glyphs[cell],
                  reference.matches(try Self.glyph(image, grid: grid, cell: cell)) else { return false }
        }
        return true
    }
}

func testBoardAppearance() throws {
    let root = solverURL().deletingLastPathComponent()
    let runRoot = root.appendingPathComponent("fixtures/appearance")
    func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Missing appearance fixture: \(url.path)") }
        return result
    }
    var pairs = 0
    var totalTime: Double = 0
    for name in ["round-003", "round-004", "round-005", "round-006", "round-007", "round-008", "round-009", "round-010", "round-011", "round-012", "round-013"] {
        let path = runRoot.appendingPathComponent(name)
        let initial = try image(path.appendingPathComponent("initial.png"))
        let final = try image(path.appendingPathComponent("latest.png"))
        let initialBoard = try Board.readFixture(path.appendingPathComponent("initial-board.txt").path)
        let checkpoint = try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: path.appendingPathComponent("checkpoint.json")))
        let grid = try Grid.forImage(initial)
        let appearance = try BoardAppearance(image: initial, grid: grid, board: initialBoard)
        let start = Date()
        guard try appearance.matches(final, grid: grid, expected: checkpoint.board) else { throw Failure("Unchanged glyph appearance rejected \(name)") }
        totalTime += Date().timeIntervalSince(start)
        guard try !appearance.matches(initial, grid: grid, expected: checkpoint.board) else { throw Failure("Unapplied actions accepted by appearance verifier.") }
        var corrupted = checkpoint.board
        if let cell = corrupted.values.firstIndex(where: { $0 > 0 }) {
            corrupted.values[cell] = corrupted.values[cell] % 9 + 1
            guard try !appearance.matches(final, grid: grid, expected: corrupted) else { throw Failure("Different digit accepted by appearance verifier.") }
        }
        pairs += 1
    }
    // Verify that glyphs for distinct recognized digits are not interchangeable.
    let referenceImage = try image(runRoot.appendingPathComponent("round-003/initial.png"))
    let referenceBoard = try Board.readFixture(runRoot.appendingPathComponent("round-003/initial-board.txt").path)
    let grid = try Grid.forImage(referenceImage)
    let appearance = try BoardAppearance(image: referenceImage, grid: grid, board: referenceBoard)
    var distinct = 0
    for a in referenceBoard.values.indices {
        for b in referenceBoard.values.indices where referenceBoard.values[a] != referenceBoard.values[b] {
            guard !appearance.glyphs[a]!.matches(appearance.glyphs[b]!) else { throw Failure("Distinct digit glyphs matched: \(referenceBoard.values[a]), \(referenceBoard.values[b])") }
            distinct += 1
        }
    }
    print("Appearance verification passed: \(pairs) real before/after boards, \(distinct) distinct-digit rejections, mean \(totalTime / Double(pairs)) seconds per board.")
}
