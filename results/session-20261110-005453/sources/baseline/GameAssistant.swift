import Cocoa
import ApplicationServices
import CoreGraphics
import Vision

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func json(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func required(_ name: String) throws -> String {
    guard let value = option(name) else { throw Failure("Missing \(name)") }
    return value
}
struct GameWindow {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
    var object: [String: Any] {
        ["id": id, "pid": pid, "title": title,
         "bounds": [bounds.minX, bounds.minY, bounds.width, bounds.height]]
    }
}
func miniApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        let bundle = $0.bundleIdentifier ?? ""
        return bundle == "com.tencent.flue.WeApp" || bundle == "com.tencent.flue.WeChatAppEx" || bundle == "com.tencent.xinWeChat"
    }
}
func windows() -> [GameWindow] {
    let pids = Set(miniApps().map(\.processIdentifier))
    let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.compactMap { item in
        guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
              let id = item[kCGWindowNumber as String] as? UInt32,
              let dict = item[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
              (item[kCGWindowLayer as String] as? Int) == 0,
              (item[kCGWindowName as String] as? String ?? "").contains("开局托儿所") else { return nil }
        return GameWindow(id: id, pid: pid, title: item[kCGWindowName as String] as? String ?? "", bounds: bounds)
    }
}
func selectedWindow() throws -> GameWindow {
    let candidates = windows()
    if option("--window") == nil, candidates.count == 1 { return candidates[0] }
    guard let raw = option("--window"), let id = UInt32(raw), let window = candidates.first(where: { $0.id == id }) else {
        throw Failure("Mini-program window is not visible. Run status after opening the game.")
    }
    guard window.title.contains("开局托儿所") else {
        throw Failure("Window title does not identify 开局托儿所; refusing to operate another window.")
    }
    return window
}
func capture(_ window: GameWindow, to url: URL) throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else {
        throw Failure("Screen recording permission is missing. Enable it for the host terminal/application in macOS System Settings.")
    }
    for attempt in 0..<3 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.id), url.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
    }
    throw Failure("Could not capture the selected game window.")
}
struct Board: Codable {
    let rows: Int
    let cols: Int
    var values: [Int]
    func printGrid() {
        for r in 0..<rows {
            print(values[(r * cols)..<((r + 1) * cols)].map { $0 == 0 ? "." : String($0) }.joined(separator: " "))
        }
    }
    func removing(_ move: Move) -> Board {
        var next = self
        for i in move.cells { next.values[i] = 0 }
        return next
    }
    func moves() -> [Move] {
        var result: [Move] = []
        var seen = Set<[Int]>()
        for top in 0..<rows {
            var columnSums = Array(repeating: 0, count: cols)
            for bottom in top..<rows {
                for c in 0..<cols { columnSums[c] += values[bottom * cols + c] }
                for left in 0..<cols {
                    var sum = 0
                    for right in left..<cols {
                        sum += columnSums[right]
                        if sum > 10 { break }
                        if sum == 10 {
                            let cells = (top...bottom).flatMap { r in (left...right).map { r * cols + $0 } }.filter { values[$0] > 0 }
                            if seen.insert(cells).inserted {
                                result.append(Move(top: top, left: left, bottom: bottom, right: right, cells: cells))
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}
struct Move: Codable {
    let top: Int, left: Int, bottom: Int, right: Int
    let cells: [Int]
    var description: String { "rows \(top + 1)...\(bottom + 1), columns \(left + 1)...\(right + 1), remove \(cells.count)" }
}
struct Grid {
    let rect: CGRect
    let rows: Int
    let cols: Int
    static func forImage(_ image: CGImage) throws -> Grid {
        if option("--board") != nil { return try arguments() }
        // Calibrated for this game's 16x10 layout. OCR must validate every initial
        // cell; a layout change therefore fails before any input is issued.
        let sx = Double(image.width) / 704, sy = Double(image.height) / 1338
        guard abs(sx / sy - 1) < 0.04 else { throw Failure("Unrecognized window aspect ratio; provide explicit --board/--rows/--cols calibration.") }
        return Grid(rect: CGRect(x: 24 * sx, y: 226 * sy, width: 656 * sx, height: 1050 * sy), rows: 16, cols: 10)
    }
    static func arguments() throws -> Grid {
        let tokens = try required("--board").split(separator: ",", omittingEmptySubsequences: false)
        let numbers = tokens.compactMap { Double($0) }
        guard tokens.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[0] >= 0, numbers[1] >= 0,
              numbers[2] > 0, numbers[3] > 0,
              let rows = Int(try required("--rows")), let cols = Int(try required("--cols")),
              (1...30).contains(rows), (1...30).contains(cols) else { throw Failure("Invalid grid geometry.") }
        return Grid(rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), rows: rows, cols: cols)
    }
    func recognize(_ image: CGImage, expected: Board? = nil) throws -> Board {
        if let expected = expected {
            try expected.validate()
            guard expected.rows == rows, expected.cols == cols else { throw Failure("Expected board dimensions differ from OCR grid.") }
        }
        guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(rect),
              let cropped = image.cropping(to: rect) else { throw Failure("Board rectangle is outside screenshot pixels.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = Float(0.15 / Double(rows))
        try VNImageRequestHandler(cgImage: cropped).perform([request])
        var values = Array(repeating: 0, count: rows * cols)
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first else { continue }
            for index in text.string.indices {
                let character = text.string[index]
                if character.isWhitespace { continue }
                guard let value = character.wholeNumberValue, (1...9).contains(value), text.confidence >= 0.8,
                      let box = try text.boundingBox(for: index..<text.string.index(after: index)) else {
                    continue // Sparse-board OCR is unreliable; individual cells are checked below.
                }
                let column = min(cols - 1, max(0, Int(box.boundingBox.midX * Double(cols))))
                let row = min(rows - 1, max(0, Int((1 - box.boundingBox.midY) * Double(rows))))
                let cell = row * cols + column
                if values[cell] != 0 { values[cell] = 0; continue }
                values[cell] = value
            }
        }
        // Whole-grid OCR can omit isolated digits. Retry only missing/mismatched
        // occupied cells, with generous white space around each individual tile.
        for cell in values.indices {
            let needsRetry = expected.map { values[cell] != $0.values[cell] && $0.values[cell] != 0 } ?? (values[cell] == 0)
            if !needsRetry { continue }
            let r = cell / cols, c = cell % cols
            let cw = Double(cropped.width) / Double(cols), ch = Double(cropped.height) / Double(rows)
            let cellRect = CGRect(x: Double(c) * cw, y: Double(r) * ch, width: cw, height: ch).insetBy(dx: cw * 0.22, dy: ch * 0.22)
            guard let tile = cropped.cropping(to: cellRect) else { continue }
            for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
                let single = VNRecognizeTextRequest()
                single.recognitionLevel = level
                single.usesLanguageCorrection = false
                single.recognitionLanguages = ["en-US"]
                single.minimumTextHeight = 0.05
                try VNImageRequestHandler(cgImage: tile).perform([single])
                let candidates = (single.results ?? []).compactMap { $0.topCandidates(1).first }
                if args.contains("--debug-ocr") {
                    fputs("cell \(cell) level \(level.rawValue): \(candidates.map { "\($0.string):\($0.confidence)" })\n", stderr)
                }
                if candidates.count == 1, let candidate = candidates.first,
                   candidate.confidence >= 0.5,
                   let digit = Int(["I", "l", "|"].contains(candidate.string) ? "1" : candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)), (1...9).contains(digit) {
                    values[cell] = digit
                    break
                }
            }
        }
        if let expected = expected {
            guard values == expected.values else { throw Failure("Observed board differs from expected board; stopping rather than clicking with stale data.") }
        } else {
            guard values.allSatisfy({ $0 > 0 }) else {
                throw Failure("Initial grid was not completely recognized (\(values.filter { $0 > 0 }.count)/\(values.count)). Start on a full board and check grid bounds.")
            }
        }
        let paper = try paperMask(image)
        guard values.indices.allSatisfy({ paper[$0] == (values[$0] > 0) }) else {
            throw Failure("Paper-tile presence disagrees with recognized digits; waiting for stable board.")
        }
        return Board(rows: rows, cols: cols, values: values)
    }
    func paperMask(_ image: CGImage) throws -> [Bool] {
        var result: [Bool] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let cw = rect.width / Double(cols), ch = rect.height / Double(rows)
                let area = CGRect(x: rect.minX + Double(c) * cw, y: rect.minY + Double(r) * ch, width: cw, height: ch).insetBy(dx: cw * 0.22, dy: ch * 0.22)
                guard let tile = image.cropping(to: area) else { throw Failure("Cannot inspect tile occupancy.") }
                var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
                guard let context = CGContext(data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure("Cannot create tile image context.") }
                context.draw(tile, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                let white = (0..<64).filter { let i = $0 * 4; return pixels[i] > 170 && pixels[i + 1] > 170 && pixels[i + 2] > 170 }.count
                result.append(white >= 16)
            }
        }
        return result
    }
}
func ensureForeground(_ window: GameWindow) throws {
    guard AXIsProcessTrusted() else { throw Failure("Accessibility permission is missing.") }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
          let current = windows().first(where: { $0.id == window.id }), current.bounds == window.bounds else {
        throw Failure("Game is no longer foreground or its window moved; stopping mouse input.")
    }
    let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let front = ordered.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
          (front[kCGWindowNumber as String] as? UInt32) == window.id else {
        throw Failure("A different window covers the game; stopping mouse input.")
    }
}
func focus(_ window: GameWindow) throws {
    guard AXIsProcessTrusted() else { throw Failure("Accessibility permission is missing.") }
    let app = AXUIElementCreateApplication(window.pid)
    NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.5)
    if (try? ensureForeground(window)) != nil { return }
    // A background command cannot always activate WeChat while an editor owns
    // focus. LaunchServices handles that activation request reliably on macOS.
    if let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleURL {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-a", bundle.path]
        try launcher.run()
        launcher.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.6)
        if (try? ensureForeground(window)) != nil { return }
    }
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
    guard status == .success, let items = raw as? [AXUIElement] else { throw Failure("Cannot inspect game window accessibility.") }
    for item in items {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
        if (title as? String) == window.title {
            AXUIElementSetAttributeValue(item, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            AXUIElementPerformAction(item, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, item)
            Thread.sleep(forTimeInterval: 0.5)
            try ensureForeground(window)
            return
        }
    }
    throw Failure("Cannot find the game window in accessibility tree.")
}
func click(_ window: GameWindow, x: Double, y: Double) throws {
    guard x >= 0, x < window.bounds.width, y >= 0, y < window.bounds.height else { throw Failure("Click is outside the game window.") }
    try ensureForeground(window)
    let point = CGPoint(x: window.bounds.minX + x, y: window.bounds.minY + y)
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
}
func drag(_ move: Move, grid: Grid, image: CGImage, window: GameWindow) throws {
    try ensureForeground(window)
    let sx = window.bounds.width / Double(image.width), sy = window.bounds.height / Double(image.height)
    func point(row: Double, col: Double) -> CGPoint {
        CGPoint(x: window.bounds.minX + (grid.rect.minX + col * grid.rect.width / Double(grid.cols)) * sx,
                y: window.bounds.minY + (grid.rect.minY + row * grid.rect.height / Double(grid.rows)) * sy)
    }
    let start = point(row: Double(move.top) + 0.15, col: Double(move.left) + 0.15)
    let end = point(row: Double(move.bottom) + 0.85, col: Double(move.right) + 0.85)
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    post(.mouseMoved, start)
    post(.leftMouseDown, start)
    var last = start
    defer { post(.leftMouseUp, last) }
    for step in 1...10 {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else {
            throw Failure("Application focus changed during drag; mouse released.")
        }
        let fraction = Double(step) / 10
        last = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        post(.leftMouseDragged, last)
        usleep(8_000)
    }
}
func run() throws {
    switch args.first ?? "help" {
    case "scene":
        try inspectScreen()
    case "session":
        try runSession()
    case "focus":
        try focus(selectedWindow())
    case "click":
        let window = try selectedWindow()
        let point = try required("--at").split(separator: ",").compactMap { Double($0) }
        guard point.count == 2, point.allSatisfy(\.isFinite) else { throw Failure("Invalid --at X,Y in window points.") }
        try focus(window)
        try click(window, x: point[0], y: point[1])
    case "status":
        try json(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
                  "miniProgramProcesses": miniApps().map { ["pid": $0.processIdentifier, "name": $0.localizedName ?? "", "bundle": $0.bundleIdentifier ?? ""] as [String: Any] },
                  "visibleMiniProgramWindows": windows().map(\.object)])
    case "capture":
        let url = URL(fileURLWithPath: try required("--out"))
        let image = try capture(selectedWindow(), to: url)
        try json(["path": url.path, "width": image.width, "height": image.height])
    case "analyze":
        let url = URL(fileURLWithPath: try required("--image"))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("Cannot open image.")
        }
        let board = try Grid.forImage(image).recognize(image)
        board.printGrid()
        print("Legal moves: \(board.moves().count)")
    case "solve":
        let board: Board
        if let path = option("--board-file") { board = try Board.readFixture(path) }
        else {
            let url = URL(fileURLWithPath: try required("--image"))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Cannot open image.") }
            board = try Grid.forImage(image).recognize(image)
        }
        let plan = try planGame(board, seconds: Double(option("--search-seconds") ?? "32") ?? .nan,
                                target: Int(option("--target") ?? "140") ?? 0, seed: UInt64(option("--seed") ?? "2") ?? 2)
        if let path = option("--out") { try JSONEncoder().encode(plan.result).write(to: URL(fileURLWithPath: path), options: .atomic) }
        print("Validated final score \(board.points + plan.result.score); \(plan.moves.count) moves; \(plan.result.trials) trials in \(plan.result.seconds) seconds.")
    case "play":
        try playGame()
    case "selftest":
        try selftest()
    default:
        print("""
        GameAssistant status
        GameAssistant focus --window ID
        GameAssistant click --window ID --at X,Y  (window logical points)
        GameAssistant capture --window ID --out game.png
        GameAssistant analyze --image game.png --board X,Y,W,H --rows R --cols C
        GameAssistant solve --board-file BOARD.txt [--target 140 --search-seconds 32 --seed 2 --out plan.json]
        GameAssistant play [--window ID] [--target 140 --search-seconds 32 --best-effort --seconds 120 --output runs/NAME]
        GameAssistant play --resume runs/NAME/checkpoint.json [--output runs/RESUMED]
        GameAssistant selftest
        Default calibration scales the verified 704x1338 layout; --board X,Y,W,H --rows R --cols C overrides it.
        """)
    }
}

func selftest() throws {
    let board = Board(rows: 2, cols: 2, values: [1, 2, 3, 4])
    guard let move = board.moves().first, move.cells.count == 4, board.removing(move).values == [0, 0, 0, 0] else { throw Failure("2x2 solver check failed.") }
    let gap = Board(rows: 1, cols: 3, values: [1, 0, 9])
    guard gap.moves().count == 1, gap.moves().first?.cells.count == 2 else { throw Failure("Empty-cell solver check failed.") }
    let blocked = Board(rows: 1, cols: 3, values: [1, 2, 9])
    guard blocked.moves().isEmpty else { throw Failure("Rectangle inclusion check failed.") }
    print("Solver checks passed.")
    try checkOCR(rows: 4, cols: 4)
    try checkOCR(rows: 16, cols: 10)
    try testPlanner()
    try testCheckpoint()
    let base = solverURL().deletingLastPathComponent().appendingPathComponent("fixtures")
    for name in ["board-a", "board-b"] {
        let expected = try Board.readFixture(base.appendingPathComponent(name + ".txt").path)
        let url = base.appendingPathComponent(name + ".png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Missing OCR regression fixture.") }
        let actual = try Grid.forImage(image).recognize(image)
        guard actual.values == expected.values else { throw Failure("Initial-board OCR regression failed for \(name).") }
    }
    print("Real screenshot regressions passed: 320/320 cells.")
    let sparse = try JSONDecoder().decode(Board.self, from: Data(contentsOf: base.appendingPathComponent("sparse-board.json")))
    guard let source = CGImageSourceCreateWithURL(base.appendingPathComponent("sparse-board.png") as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Missing sparse-board regression fixture.") }
    _ = try Grid.forImage(image).recognize(image, expected: sparse)
    print("Sparse-board OCR and paper-occupancy regression passed.")
}
func checkOCR(rows: Int, cols: Int) throws {
    // Exercise actual Vision OCR, including a realistically sized 160-cell grid.
    let values = (0..<(rows * cols)).map { $0 % 9 + 1 }
    let size = NSSize(width: cols * 100, height: rows * 100)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    for r in 0..<rows {
        for c in 0..<cols {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.black]
            let text = String(values[r * cols + c]) as NSString
            text.draw(at: NSPoint(x: c * 100 + 35, y: (rows - 1 - r) * 100 + 20), withAttributes: attributes)
        }
    }
    image.unlockFocus()
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure("Synthetic image failed.") }
    let grid = Grid(rect: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height), rows: rows, cols: cols)
    let start = Date()
    let read = try grid.recognize(cgImage)
    guard read.values == values else { throw Failure("OCR values or row orientation failed.") }
    print("Synthetic Vision OCR check passed (\(values.count)/\(values.count) digits, \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds).")
}
@main
struct GameAssistantMain {
    static func main() {
        do { try run() }
        catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
}
