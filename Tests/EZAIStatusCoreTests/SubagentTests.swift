import Foundation
import Testing
@testable import EZAIStatusCore

@Suite("Projets et sous-agents")
struct SubagentTests {
    @Test func projectNames() {
        #expect(ProjectName.from(path: "/Users/alex/Documents/DEV/MyApp") == "MyApp")
        #expect(ProjectName.from(path: "/Users/alex/Documents/DEV/MyApp/.claude/worktrees/perf-plan") == "MyApp")
        #expect(ProjectName.from(path: "/Users/alex/.codex/worktrees/ab12/Side Project") == "Side Project")
        #expect(ProjectName.from(path: "/Users/alex/Documents/Codex/2026-11-15/j") == nil)
        #expect(ProjectName.from(path: "/Users/alex/Documents/Codex/2026-11-15") == nil)
        #expect(ProjectName.from(path: FileManager.default.homeDirectoryForCurrentUser.path) == nil)
        #expect(ProjectName.from(path: nil) == nil)
    }

    @Test func filterKeepsActiveAndCurrentTurn() {
        let turn = Date(timeIntervalSince1970: 1_000)
        let subagents = [
            ObservedSubagent(id: "old", title: "Ancien", activity: .finished(at: turn.addingTimeInterval(-10), unread: false)),
            ObservedSubagent(id: "done", title: "Fini", activity: .finished(at: turn.addingTimeInterval(10), unread: false)),
            ObservedSubagent(id: "run", title: "Actif", activity: .running),
            ObservedSubagent(id: "ask", title: "Question", activity: .waiting(since: turn)),
            ObservedSubagent(id: "idle", title: "Repos", activity: .idle),
        ]
        #expect(SubagentFilter.visible(subagents, since: turn).map(\.id) == ["ask", "run", "done"])
        #expect(SubagentFilter.visible(subagents, since: nil).map(\.id) == ["ask", "run"])
    }

    @Test func codexSubagentTitle() {
        #expect(CodexConnector.subagentTitle(["nickname": "Tesla", "agent_path": "/root/brief_builder_check"]) == "Tesla · brief builder check")
        #expect(CodexConnector.subagentTitle(["title": ""]) == "Sous-agent")
    }

    @Test func claudeSubagentTranscriptIsSidechain() {
        let objects: [[String: Any]] = [
            ["type": "user", "timestamp": "2026-11-15T10:00:00Z", "isSidechain": true, "message": ["content": [["type": "text", "text": "Mission"]]]],
            ["type": "assistant", "timestamp": "2026-11-15T10:05:00Z", "isSidechain": true,
             "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Fini"]]]],
        ]
        #expect(ClaudeConnector.turn(in: objects) == nil)
        #expect(ClaudeConnector.turn(in: objects, sidechain: true) == .ended(at: ISODate.parse("2026-11-15T10:05:00Z")!))
    }

    @Test func duplicateTranscriptIDsAreMerged() {
        let session = ClaudeConnector.Session(json: ["sessionId": "local_1", "cliSessionId": "a", "lastAssistantCliSessionId": "a"])!
        #expect(session.cliSessionIDs == ["a"])
    }

    @Test func subagentsKeepReadConversationVisibleButAreNotCounted() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let tracker = Tracker(storeURL: nil, now: start)
        let parent = ObservedConversation(id: "claude:p", source: .claudeCode, title: "Parent",
                                          activity: .finished(at: start.addingTimeInterval(60), unread: false),
                                          openURL: nil, project: "MyApp",
                                          subagents: [ObservedSubagent(id: "s1", title: "Piste", activity: .running),
                                                      ObservedSubagent(id: "s2", title: "Revue", activity: .running)])
        let (snapshot, _) = tracker.update([ConnectorResult(source: .claudeCode, status: .ok, observations: [parent])],
                                           now: start.addingTimeInterval(120))
        #expect(snapshot.count(.running) == 1)
        #expect(snapshot.conversations.first?.subagents.count == 2)
        #expect(snapshot.conversations.first?.project == "MyApp")

        let quiet = ObservedConversation(id: "claude:q", source: .claudeCode, title: "Calme",
                                         activity: .finished(at: start.addingTimeInterval(60), unread: false), openURL: nil,
                                         subagents: [ObservedSubagent(id: "s3", title: "Fini", activity: .finished(at: start, unread: false))])
        let (again, _) = tracker.update([ConnectorResult(source: .claudeCode, status: .ok, observations: [quiet])],
                                        now: start.addingTimeInterval(120))
        #expect(again.conversations.isEmpty)
    }
}

@Suite("Commandes en arrière-plan")
struct BackgroundCommandTests {
    private func write(_ lines: [[String: Any]], to url: URL, append: Bool = false) throws {
        var text = append ? (try String(contentsOf: url, encoding: .utf8)) : ""
        for line in lines { text += String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)! + "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func toolUse(_ id: String, _ description: String) -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": "Bash",
                                                       "input": ["command": "sleep 99", "description": description]]]]]
    }

    private func result(_ toolUse: String, _ text: String) -> [String: Any] {
        ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": toolUse, "content": text]]]]
    }

    @Test func findsLaunchedCommandsIncrementally() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let main = dir.appendingPathComponent("main.jsonl")
        let sub = dir.appendingPathComponent("agent-x.jsonl")
        try write([toolUse("t1", "Lancer le rejeu"), result("t1", "Command running in background with ID: bkrp8mfrx. Output is being written to: /tmp/x")], to: main)
        try write([toolUse("t2", "Attendre la suite"),
                   result("t2", "Command did not complete within its 120s timeout and was moved to the background (ID: b114xlqc2). Output…")], to: sub)
        let index = BackgroundCommandIndex()
        #expect(index.description(of: "bkrp8mfrx", in: [main, sub]) == "Lancer le rejeu")
        #expect(index.description(of: "b114xlqc2", in: [main, sub]) == "Attendre la suite")
        // Commande au premier plan : jamais annoncée, donc ignorée (et pas recherchée à chaque balayage).
        let now = Date()
        #expect(index.description(of: "bforeground", in: [main], now: now) == nil)
        // Ajout ultérieur dans la même transcription : seule la fin est relue, après le délai de 30 s.
        try write([toolUse("t3", "Nouvelle tâche"), result("t3", "Command running in background with ID: bnew1")], to: main, append: true)
        #expect(index.description(of: "bnew1", in: [main], now: now) == "Nouvelle tâche")
    }

    @Test func liveTaskScanFindsOwnShell() throws {
        // Un shell qui écrit dans un fichier …/claude-<uid>/<dossier>/<session>/tasks/<id>.output doit être vu comme vivant.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(getuid())-test-\(UUID().uuidString)")
        let tasks = root.appendingPathComponent("projet/session-abc/tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "exec 3>>'\(tasks.path)/bvivant.output'; sleep 3; true"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.4)
        let live = OpenFiles.claudeLiveTasks()
        #expect(live["session-abc"]?["bvivant"] != nil)
    }
}
