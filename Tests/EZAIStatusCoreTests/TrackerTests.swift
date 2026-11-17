import Foundation
import Testing
@testable import EZAIStatusCore

private let start = Date(timeIntervalSince1970: 1_000_000)

private func result(_ observations: [ObservedConversation], status: SourceStatus = .ok) -> [ConnectorResult] {
    [ConnectorResult(source: .codex, status: status, observations: observations)]
}

private func codex(_ id: String, _ activity: Activity) -> ObservedConversation {
    ObservedConversation(id: "codex:\(id)", source: .codex, title: id, activity: activity, openURL: URL(string: "codex://threads/\(id)"))
}

@Suite("Suivi")
struct TrackerTests {
    @Test func historyBeforeTrackingIsIgnored() {
        let tracker = Tracker(storeURL: nil, now: start)
        let (snapshot, _) = tracker.update(result([
            codex("old", .finished(at: start.addingTimeInterval(-60), unread: true)),
            codex("new", .finished(at: start.addingTimeInterval(60), unread: true)),
            codex("read", .finished(at: start.addingTimeInterval(60), unread: false)),
            codex("run", .running),
            codex("ask", .waiting(since: start.addingTimeInterval(-3600))),
            codex("idle", .idle),
        ]), now: start.addingTimeInterval(120))
        #expect(snapshot.conversations(in: .finished).map(\.title) == ["new"])
        #expect(snapshot.count(.running) == 1)
        #expect(snapshot.count(.waiting) == 1)
    }

    @Test func acknowledgementHidesOnlyThatFinish() {
        let tracker = Tracker(storeURL: nil, now: start)
        let first = start.addingTimeInterval(60)
        var (snapshot, _) = tracker.update(result([codex("a", .finished(at: first, unread: true))]), now: first)
        let conversation = snapshot.conversations[0]
        snapshot = tracker.acknowledge(conversation, now: first)
        #expect(snapshot.count(.finished) == 0)
        // Nouvelle exécution puis nouvelle fin : elle réapparaît.
        let second = first.addingTimeInterval(300)
        (snapshot, _) = tracker.update(result([codex("a", .finished(at: second, unread: true))]), now: second)
        #expect(snapshot.count(.finished) == 1)
    }

    @Test func runningIsNeverAcknowledged() {
        let tracker = Tracker(storeURL: nil, now: start)
        let (snapshot, _) = tracker.update(result([codex("r", .running)]), now: start)
        #expect(tracker.acknowledge(snapshot.conversations[0]).count(.running) == 1)
    }

    @Test func notificationsOncePerEventAndNotAtStartup() {
        let tracker = Tracker(storeURL: nil, now: start)
        let t1 = start.addingTimeInterval(10)
        var (_, transitions) = tracker.update(result([codex("a", .finished(at: t1, unread: true))]), now: t1)
        #expect(transitions.isEmpty)
        (_, transitions) = tracker.update(result([codex("a", .finished(at: t1, unread: true))]), now: t1)
        #expect(transitions.isEmpty)
        let t2 = t1.addingTimeInterval(10)
        (_, transitions) = tracker.update(result([codex("a", .finished(at: t1, unread: true)),
                                                  codex("b", .waiting(since: t2)),
                                                  codex("c", .running)]), now: t2)
        #expect(transitions.map(\.conversation.title) == ["b"])
        (_, transitions) = tracker.update(result([codex("b", .waiting(since: t2))]), now: t2)
        #expect(transitions.isEmpty)
    }

    @Test func memoryPersistsAcrossRestarts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        let finish = start.addingTimeInterval(60)
        let tracker = Tracker(storeURL: url, now: start)
        let (snapshot, _) = tracker.update(result([codex("a", .finished(at: finish, unread: true))]), now: finish)
        tracker.acknowledge(snapshot.conversations[0], now: finish)

        let restarted = Tracker(storeURL: url, now: start.addingTimeInterval(9_999))
        #expect(restarted.memory.trackingStartedAt == start)
        let (again, transitions) = restarted.update(result([codex("a", .finished(at: finish, unread: true))]), now: finish)
        #expect(again.count(.finished) == 0)
        #expect(transitions.isEmpty)
    }

    @Test func unreadableSourceIsReportedAsProblem() {
        let tracker = Tracker(storeURL: nil, now: start)
        let (snapshot, _) = tracker.update(result([], status: .unreadable("verrou")), now: start)
        #expect(snapshot.problems.map(\.source) == [.codex])
        #expect(!SourceStatus.unsupported("x").isProblem)
    }
}

@Suite("Hooks Claude Code")
struct HookTests {
    private func line(_ ts: Double, _ session: String, _ name: String, type: String? = nil) -> [String: Any] {
        var event: [String: Any] = ["session_id": session, "hook_event_name": name]
        if let type { event["notification_type"] = type }
        return ["ts": ts, "event": event]
    }

    @Test func permissionPromptUntilNextEvent() {
        var objects = [line(10, "s1", "Notification", type: "permission_prompt"),
                       line(11, "s2", "Notification", type: "permission_prompt"),
                       line(12, "s2", "PostToolUse"),
                       line(13, "s1", "Notification", type: "idle_prompt")]
        #expect(ClaudeHooks.waitingSessions(in: objects) == ["s1": Date(timeIntervalSince1970: 10)])
        objects.append(line(14, "s1", "Stop"))
        #expect(ClaudeHooks.waitingSessions(in: objects).isEmpty)
    }

    @Test func installAndUninstallKeepUserHooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = ["model": "opus", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "say fini"]]]]]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try ClaudeHooks.install(home: home)
        #expect(ClaudeHooks.isInstalled(home: home))
        let installed = ClaudeHooks.readSettings(home: home)!
        let stop = (installed["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 2)
        #expect(installed["model"] as? String == "opus")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.ezaistatus-backup").path))
        // Réinstaller ne duplique pas.
        try ClaudeHooks.install(home: home)
        #expect(((ClaudeHooks.readSettings(home: home)!["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 2)

        try ClaudeHooks.uninstall(home: home)
        #expect(!ClaudeHooks.isInstalled(home: home))
        let restored = ClaudeHooks.readSettings(home: home)!
        let hooks = restored["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == ["Stop"])
        #expect((hooks["Stop"] as! [[String: Any]]).count == 1)
    }

    @Test func hookScriptWritesParsableLine() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ClaudeHooks.install(home: home)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [home.appendingPathComponent("Library/Application Support/EZAIStatus/claude-hook.sh").path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("{\"session_id\":\"abc\",\n\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"message\":\"secret \\\"x\\\"\"}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(ClaudeHooks.waitingSessions(home: home).keys.contains("abc"))
        // Seuls les identifiants sont notés, jamais le contenu.
        let journal = try String(contentsOf: ClaudeHooks.eventsFile(home: home), encoding: .utf8)
        #expect(!journal.contains("secret"))
    }
}
