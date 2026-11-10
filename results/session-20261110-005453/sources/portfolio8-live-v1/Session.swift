import Cocoa
import Vision
import CryptoKit

struct ScreenLabel: Codable {
    let text: String
    let x: Double, y: Double, width: Double, height: Double
}
func screenLabels(_ image: CGImage) throws -> [ScreenLabel] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return ScreenLabel(text: candidate.string, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
func inspectScreen() throws {
    let image: CGImage
    if let path = option("--image") {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Cannot open scene image.") }
        image = loaded
    } else {
        image = try capture(selectedWindow(), to: URL(fileURLWithPath: option("--out") ?? "runs/scene.png"))
    }
    print(String(data: try JSONEncoder().encode(screenLabels(image)), encoding: .utf8)!)
}
func writeObject(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
func appendObject(_ object: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(10)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: data)
}
func settlementScore(_ labels: [ScreenLabel]) -> Int? {
    let text = labels.map(\.text).joined(separator: " ")
    guard let expression = try? NSRegularExpression(pattern: "智力总分数[为為]?\\s*([0-9]{1,3})"),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text), let score = Int(text[range]), (0...160).contains(score) else { return nil }
    return score
}
func unlimitedSeconds(_ labels: [ScreenLabel]) -> Int? {
    let text = labels.filter { $0.y < 0.15 }.map(\.text).joined()
    guard let regex = try? NSRegularExpression(pattern: "(?:(\\d+)小时)?(?:(\\d+)分)?(\\d+)秒"),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func component(_ i: Int) -> Int { Range(match.range(at: i), in: text).flatMap { Int(text[$0]) } ?? 0 }
    return component(1) * 3600 + component(2) * 60 + component(3)
}
func rewardedAdClose(_ labels: [ScreenLabel]) -> ScreenLabel? {
    guard labels.contains(where: { $0.y < 0.17 && $0.text.contains("已获得奖励") }) else { return nil }
    return labels.first { $0.text.contains("关闭") && $0.x > 0.75 && $0.y < 0.17 }
}
func newAppearanceCancel(_ labels: [ScreenLabel]) -> ScreenLabel? {
    let text = labels.map(\.text).joined()
    guard text.contains("立刻替换新形象"), text.contains("获得新形象") || text.contains("解锁新形象") else { return nil }
    return labels.first { $0.text.replacingOccurrences(of: " ", with: "") == "取消" &&
        $0.y > 0.6 && $0.y < 0.85 && $0.x > 0.15 && $0.x + $0.width < 0.85 }
}
func mainBackgroundVisible(_ image: CGImage) -> Bool {
    // Dialogs dim the home screen. Its text remains OCR-readable underneath,
    // so require the uncovered background before pressing any home controls.
    let area = CGRect(x: Double(image.width) * 0.015, y: Double(image.height) * 0.17,
                      width: Double(image.width) * 0.035, height: Double(image.height) * 0.025)
    guard let tile = image.cropping(to: area) else { return false }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
    context.draw(tile, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 240
}
func testSessionScenes() throws {
    let root = solverURL().deletingLastPathComponent()
    func labels(_ path: String) throws -> [ScreenLabel] {
        let url = root.appendingPathComponent(path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Missing scene regression image: \(path)") }
        return try screenLabels(image)
    }
    guard unlimitedSeconds(try labels("unlimited-unlocked.png")) == 7199,
          rewardedAdClose(try labels("unlimited-ad.png")) != nil,
          rewardedAdClose(try labels("unlimited-progress.png")) == nil,
          newAppearanceCancel(try labels("results/session-20261110-005453/round-059/appearance-prompt.png")) != nil,
          newAppearanceCancel(try labels("unlimited-progress.png")) == nil,
          settlementScore(try labels("runs/unlimited-05/settlement.png")) == 142 else {
        throw Failure("Session scene recognition regression failed.")
    }
    for (path, expected) in [("unlimited-unlocked.png", true), ("unlimited-progress.png", false), ("results/session-20261110-005453/renewal-review.png", false)] {
        let url = root.appendingPathComponent(path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              mainBackgroundVisible(image) == expected else { throw Failure("Home overlay detection failed: \(path)") }
    }
    print("Session scenes passed: lease countdown, rewarded ad close, non-ad rejection, new appearance, and settlement score.")
}

func runSession() throws {
    let directory = URL(fileURLWithPath: try required("--output"), isDirectory: true)
    guard let endEpoch = Double(try required("--until")), endEpoch.isFinite else { throw Failure("Invalid --until epoch.") }
    let end = Date(timeIntervalSince1970: endEpoch)
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let events = directory.appendingPathComponent("events.jsonl")
    let latest = directory.appendingPathComponent("latest.png")
    let stateURL = directory.appendingPathComponent("state.json")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    var index = Int(option("--start-index") ?? "1") ?? 1
    var current: URL? = option("--adopt-run").map { URL(fileURLWithPath: $0, isDirectory: true) }
    var child: Process?
    var logFile: FileHandle?
    var unknownSince: Date?
    var lastReport = Date.distantPast
    var lastAction = Date.distantPast
    var recorded = current.map { manager.fileExists(atPath: $0.appendingPathComponent("result.json").path) } ?? false
    var completed = 0
    var best = 0
    for folder in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where folder.lastPathComponent.hasPrefix("round-") {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("result.json")), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            completed += 1; best = max(best, result["settlement_score"] as? Int ?? 0)
        }
    }
    let leaseURL = directory.appendingPathComponent("unlimited-lease.json")
    let lease = (try? Data(contentsOf: leaseURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    var unlimitedUntil = lease["expires_epoch"] as? Double ?? 0
    var adDirectory: URL?
    var adStarted: Date?
    let window = try selectedWindow()
    try focus(window)
    defer { if let child = child, child.isRunning { child.terminate() }; try? logFile?.close() }
    func event(_ kind: String, _ extra: [String: Any] = [:]) throws {
        var object = extra
        object["time"] = ISO8601DateFormatter().string(from: Date())
        object["event"] = kind
        if let current = current { object["round"] = current.lastPathComponent }
        try appendObject(object, to: events)
    }
    func state(_ status: String) throws {
        try writeObject(["updated_at": ISO8601DateFormatter().string(from: Date()), "status": status,
                         "until_epoch": endEpoch, "next_index": index, "current_round": current?.path ?? "",
                         "completed_since_start": completed, "best_since_start": best], to: stateURL)
    }
    func saveScene(_ name: String, labels: [ScreenLabel]) throws {
        let base = current ?? directory
        let destination = base.appendingPathComponent(name + ".png")
        try Data(contentsOf: latest).write(to: destination, options: .atomic)
        try JSONEncoder().encode(labels).write(to: base.appendingPathComponent(name + ".ocr.json"), options: .atomic)
    }
    func press(_ label: ScreenLabel, name: String) throws {
        try event("click", ["label": label.text, "purpose": name, "x": label.x + label.width / 2, "y": label.y + label.height / 2])
        try click(window, x: (label.x + label.width / 2) * window.bounds.width, y: (label.y + label.height / 2) * window.bounds.height)
        lastAction = Date()
        unknownSince = nil
    }
    func saveAdScene(_ name: String, labels: [ScreenLabel]) throws {
        if adDirectory == nil {
            adDirectory = directory.appendingPathComponent("ads/renew-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            try manager.createDirectory(at: adDirectory!, withIntermediateDirectories: true)
        }
        try Data(contentsOf: latest).write(to: adDirectory!.appendingPathComponent(name + ".png"), options: .atomic)
        try JSONEncoder().encode(labels).write(to: adDirectory!.appendingPathComponent(name + ".ocr.json"), options: .atomic)
    }
    func launchRound(_ startButton: ScreenLabel, labels: [ScreenLabel]) throws {
        let configURL = directory.appendingPathComponent("config.json")
        let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let strategy = config["strategy"] as? String ?? "portfolio8"
        guard ["baseline", "repair", "neighborhood", "fastrepair", "tailrepair", "portfolio", "portfolio8"].contains(strategy) else { throw Failure("Unknown session strategy.") }
        let next = directory.appendingPathComponent(String(format: "round-%03d", index), isDirectory: true)
        guard !manager.fileExists(atPath: next.path) else { throw Failure("Round directory already exists; refusing to overwrite it: \(next.path)") }
        try manager.createDirectory(at: next, withIntermediateDirectories: true)
        current = next; recorded = false
        let seed = 100 + index
        index += 1
        try saveScene("before-start", labels: labels)
        var provenance: [String: Any] = ["seed": seed, "target": 150, "search_seconds": 32, "strategy": strategy, "started_at": ISO8601DateFormatter().string(from: Date())]
        for name in ["Solver", "GameAssistant", "Solver.cpp", "GameRun.swift", "Planner.swift", "Session.swift", "BoardVerification.swift"] {
            if let data = try? Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent(name)) { provenance[name + "_sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        }
        try writeObject(provenance, to: next.appendingPathComponent("provenance.json"))
        try press(startButton, name: "start_next_round")
        Thread.sleep(forTimeInterval: 0.6)
        let logURL = next.appendingPathComponent("execution.log")
        manager.createFile(atPath: logURL.path, contents: nil)
        logFile = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["play", "--target", "150", "--best-effort", "--search-seconds", "32", "--seed", String(seed), "--strategy", strategy, "--output", next.path]
        process.standardOutput = logFile; process.standardError = logFile
        child = process
        try process.run()
        try state("playing")
    }
    try event("session_started", ["until_epoch": endEpoch, "search_budget_seconds": 32])
    while Date() < end || child != nil || (current != nil && !recorded) {
        if manager.fileExists(atPath: directory.appendingPathComponent("STOP").path) {
            try event("stop_file_detected"); try state("stopped"); return
        }
        if let running = child {
            if running.isRunning {
                if Date().timeIntervalSince(lastReport) >= 20 {
                    print("Session: executing \(current!.lastPathComponent)"); fflush(stdout)
                    try state("playing"); lastReport = Date()
                }
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            try event("play_exited", ["exit_code": running.terminationStatus])
            if let current = current { try writeObject(["exit_code": running.terminationStatus, "ended_at": ISO8601DateFormatter().string(from: Date())], to: current.appendingPathComponent("execution-result.json")) }
            try logFile?.close(); logFile = nil; child = nil
            unknownSince = nil
        }
        if (try? ensureForeground(window)) == nil {
            try state("waiting_for_game_focus")
            unknownSince = nil
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        let image = try capture(window, to: latest)
        let labels = try screenLabels(image)
        let text = labels.map(\.text).joined(separator: " ")
        func button(_ value: String, minimumY: Double = 0.4) -> ScreenLabel? {
            labels.first { $0.text.replacingOccurrences(of: " ", with: "").contains(value) && $0.y > minimumY && $0.x > 0.1 && $0.x + $0.width < 0.9 }
        }
        if Date().timeIntervalSince(lastAction) < 2 { Thread.sleep(forTimeInterval: 1); continue }
        if let started = adStarted {
            if Date().timeIntervalSince(started) >= 30, let close = rewardedAdClose(labels) {
                try saveAdScene("reward-\(Int(Date().timeIntervalSince1970))", labels: labels)
                try press(close, name: "close_completed_ad_and_claim_reward")
                try event("ad_closed_after_reward", ["watched_seconds": Date().timeIntervalSince(started)])
                adStarted = nil
                continue
            }
            if Date().timeIntervalSince(started) > 100 {
                try saveAdScene("needs-review", labels: labels)
                throw Failure("Advertisement did not expose a rewarded close button within 100 seconds.")
            }
            try state("watching_ad"); Thread.sleep(forTimeInterval: 2); continue
        }
        if text.contains("无限脑力"), text.contains("2小时"), let watch = button("免广告") {
            try saveAdScene("progress-\(Int(Date().timeIntervalSince1970))", labels: labels)
            try press(watch, name: "watch_ad_for_two_hour_unlimited_challenges")
            adStarted = Date()
            try event("ad_started", ["progress_text": text]); continue
        }
        if let cancel = newAppearanceCancel(labels) {
            try saveScene("appearance-prompt", labels: labels)
            try press(cancel, name: "decline_new_appearance_and_continue"); continue
        }
        if text.contains("恭喜你成为"), button("继续挑战", minimumY: 0.6) != nil {
            try saveScene("home-achievement-\(Int(Date().timeIntervalSince1970))", labels: labels)
            try event("dismiss_home_achievement")
            try click(window, x: window.bounds.width * 0.832, y: window.bounds.height * 0.265)
            lastAction = Date(); unknownSince = nil; continue
        }
        if let start = button("开始游戏", minimumY: 0.75), mainBackgroundVisible(image) {
            if let seconds = unlimitedSeconds(labels), seconds > 3 {
                unlimitedUntil = Date().timeIntervalSince1970 + Double(seconds)
                try writeObject(["observed_at": ISO8601DateFormatter().string(from: Date()), "remaining_seconds": seconds, "expires_epoch": unlimitedUntil], to: leaseURL)
                if adDirectory != nil {
                    try saveAdScene("unlimited-unlocked", labels: labels)
                    try event("unlimited_renewed", ["remaining_seconds": seconds, "evidence": adDirectory!.path])
                    adDirectory = nil
                }
                if Date() >= end { break }
                try launchRound(start, labels: labels); continue
            }
            if text.contains("无限挑战次数") {
                try saveAdScene("before-renewal", labels: labels)
                try event("open_unlimited_challenge_dialog")
                try click(window, x: window.bounds.width * 185 / 352, y: window.bounds.height * 75 / 669)
                lastAction = Date(); unknownSince = nil; continue
            }
        }
        if text.contains("智力总分数"), let again = button("再次挑战") {
            if let current = current, !recorded {
                try saveScene("settlement", labels: labels)
                let score = settlementScore(labels)
                var result: [String: Any] = ["settled_at": ISO8601DateFormatter().string(from: Date()), "score_confirmed": score != nil, "settlement_text": text]
                if let score = score { result["settlement_score"] = score; best = max(best, score) }
                if let data = try? Data(contentsOf: current.appendingPathComponent("checkpoint.json")), let checkpoint = try? JSONDecoder().decode(RunCheckpoint.self, from: data) {
                    result["verified_score"] = checkpoint.board.points
                    result["verified_moves"] = checkpoint.verifiedMoves
                    result["plan_completed"] = checkpoint.completed
                    result["score_matches_execution"] = score == checkpoint.board.points
                }
                if !manager.fileExists(atPath: current.appendingPathComponent("result.json").path) { completed += 1 }
                try writeObject(result, to: current.appendingPathComponent("result.json"))
                try event("settled", result)
                recorded = true
                print("Settled \(current.lastPathComponent): \(score.map(String.init) ?? "needs review"); session best \(best)"); fflush(stdout)
            }
            if Date() >= end { break }
            if manager.fileExists(atPath: directory.appendingPathComponent("DRAIN").path) {
                try event("drained_after_settlement"); try state("drained"); return
            }
            if manager.fileExists(atPath: directory.appendingPathComponent("HOLD").path) {
                try state("holding_between_rounds"); Thread.sleep(forTimeInterval: 2); continue
            }
            if Date().timeIntervalSince1970 >= unlimitedUntil - 3, let home = button("返回主界面") {
                try press(home, name: "check_and_renew_unlimited_challenges"); continue
            }
            try launchRound(again, labels: labels)
            continue
        }
        if (text.contains("当前赛况") || text.contains("上轮赛况")), let confirm = button("确定", minimumY: 0.7) {
            try saveScene("tournament", labels: labels); try press(confirm, name: "dismiss_tournament_result"); continue
        }
        if text.contains("成绩证书"), let confirm = button("确定", minimumY: 0.7) {
            try saveScene("certificate", labels: labels); try press(confirm, name: "dismiss_certificate"); continue
        }
        if text.contains("证书"), let confirm = button("知道了", minimumY: 0.6) {
            try saveScene("achievement", labels: labels); try press(confirm, name: "dismiss_achievement"); continue
        }
        if text.contains("贴纸"), let claim = button("领取", minimumY: 0.6) {
            try saveScene("sticker-\(Int(Date().timeIntervalSince1970))", labels: labels); try press(claim, name: "claim_sticker"); continue
        }
        if let skip = labels.first(where: { $0.text.contains("跳过动画") }) {
            try event("skip_settlement_animation", ["label": skip.text])
            try click(window, x: window.bounds.width / 2, y: window.bounds.height * 0.45)
            lastAction = Date(); unknownSince = nil; continue
        }
        // During the remaining game timer or a settlement animation, observe only.
        if unknownSince == nil { unknownSince = Date(); try saveScene("waiting", labels: labels) }
        try state("waiting_for_settlement")
        if Date().timeIntervalSince(lastReport) >= 20 {
            print("Session: waiting; screen: \(text.prefix(220))"); fflush(stdout); lastReport = Date()
        }
        if Date().timeIntervalSince(unknownSince!) > 150 {
            try saveScene("needs-review", labels: labels)
            try event("unrecognized_screen", ["text": text]); try state("needs_review")
            throw Failure("Session stopped on an unrecognized screen; screenshot saved for review.")
        }
        Thread.sleep(forTimeInterval: 2)
    }
    try event("session_finished", ["completed": completed, "best": best])
    try state("completed")
}
