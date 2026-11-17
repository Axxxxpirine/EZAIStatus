import Foundation
import Testing
@testable import EZAIStatusCore

private func event(_ type: String, _ time: String) -> [String: Any] {
    ["type": "event_msg", "timestamp": time, "payload": ["type": type]]
}

private func call(_ name: String, id: String, _ time: String) -> [String: Any] {
    ["type": "response_item", "timestamp": time, "payload": ["type": "function_call", "name": name, "call_id": id]]
}

private func output(id: String, _ time: String) -> [String: Any] {
    ["type": "response_item", "timestamp": time, "payload": ["type": "function_call_output", "call_id": id]]
}

@Suite("Codex")
struct CodexTests {
    @Test func finishedTurnUsesReadReceipt() {
        let objects = [event("task_started", "2026-11-15T10:00:00Z"), event("task_complete", "2026-11-15T10:05:00Z")]
        let activity = CodexConnector.activity(objects: objects, unread: true, appRunning: true)
        #expect(activity == .finished(at: ISODate.parse("2026-11-15T10:05:00Z")!, unread: true))
        #expect(CodexConnector.activity(objects: objects, unread: false, appRunning: false)
            == .finished(at: ISODate.parse("2026-11-15T10:05:00Z")!, unread: false))
    }

    @Test func runningTurnAndPendingQuestion() {
        var objects = [event("task_complete", "2026-11-15T09:00:00Z"), event("task_started", "2026-11-15T10:00:00Z")]
        #expect(CodexConnector.activity(objects: objects, unread: false, appRunning: true) == .running)
        objects.append(call("request_user_input", id: "c1", "2026-11-15T10:01:00Z"))
        #expect(CodexConnector.activity(objects: objects, unread: false, appRunning: true)
            == .waiting(since: ISODate.parse("2026-11-15T10:01:00Z")!))
        objects.append(output(id: "c1", "2026-11-15T10:02:00Z"))
        #expect(CodexConnector.activity(objects: objects, unread: false, appRunning: true) == .running)
    }

    @Test func questionFromPreviousTurnIsIgnored() {
        let objects = [call("request_user_input_async", id: "old", "2026-11-15T09:00:00Z"),
                       event("task_started", "2026-11-15T10:00:00Z")]
        #expect(CodexConnector.activity(objects: objects, unread: false, appRunning: true) == .running)
    }

    @Test func appClosedOrAbortedIsNotAFinish() {
        let started = [event("task_started", "2026-11-15T10:00:00Z")]
        #expect(CodexConnector.activity(objects: started, unread: true, appRunning: false) == .idle)
        let aborted = started + [event("turn_aborted", "2026-11-15T10:01:00Z")]
        #expect(CodexConnector.activity(objects: aborted, unread: true, appRunning: true) == .idle)
        #expect(CodexConnector.activity(objects: [], unread: true, appRunning: true) == .idle)
    }

    @Test func picksLatestStateDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["state_4.sqlite", "state_12.sqlite", "state_5.sqlite-wal", "logs_2.sqlite"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        #expect(CodexConnector.stateDatabase(in: dir)?.lastPathComponent == "state_12.sqlite")
    }
}

private func entry(_ type: String, _ time: String, stop: String? = nil, content: [[String: Any]], sidechain: Bool = false) -> [String: Any] {
    var message: [String: Any] = ["content": content]
    if let stop { message["stop_reason"] = stop }
    return ["type": type, "timestamp": time, "message": message, "isSidechain": sidechain]
}

@Suite("Claude")
struct ClaudeTests {
    @Test func transcriptTurnStates() {
        let ended = [entry("user", "2026-11-15T10:00:00Z", content: [["type": "text", "text": "Salut"]]),
                     entry("assistant", "2026-11-15T10:01:00Z", stop: "end_turn", content: [["type": "text", "text": "Fini"]]),
                     ["type": "custom-title", "customTitle": "x"]]
        #expect(ClaudeConnector.turn(in: ended) == .ended(at: ISODate.parse("2026-11-15T10:01:00Z")!))

        let tool = [entry("assistant", "2026-11-15T10:02:00Z", stop: "tool_use", content: [["type": "tool_use", "id": "t1", "name": "Bash"]])]
        #expect(ClaudeConnector.turn(in: tool) == .inProgress(questionSince: nil))

        let asking = [entry("assistant", "2026-11-15T10:03:00Z", stop: "tool_use",
                            content: [["type": "tool_use", "id": "q1", "name": "AskUserQuestion"]])]
        #expect(ClaudeConnector.turn(in: asking) == .inProgress(questionSince: ISODate.parse("2026-11-15T10:03:00Z")!))

        let answered = asking + [entry("user", "2026-11-15T10:04:00Z", content: [["type": "tool_result", "tool_use_id": "q1"]])]
        #expect(ClaudeConnector.turn(in: answered) == .inProgress(questionSince: nil))

        let interrupted = [entry("user", "2026-11-15T10:05:00Z", content: [["type": "text", "text": "[Request interrupted by user]"]])]
        #expect(ClaudeConnector.turn(in: interrupted) == .interrupted)
    }

    @Test func sidechainEntriesAreIgnored() {
        let objects = [entry("assistant", "2026-11-15T10:01:00Z", stop: "end_turn", content: [["type": "text", "text": "Fini"]]),
                       entry("assistant", "2026-11-15T10:02:00Z", stop: "tool_use", content: [["type": "tool_use", "id": "s", "name": "Bash"]], sidechain: true)]
        #expect(ClaudeConnector.turn(in: objects) == .ended(at: ISODate.parse("2026-11-15T10:01:00Z")!))
    }

    private func session(_ extra: [String: Any] = [:]) -> ClaudeConnector.Session {
        var json: [String: Any] = ["sessionId": "local_1", "cliSessionId": "cli", "title": "Titre",
                                   "lastActivityAt": 2_000, "latestUserFrameAt": 1_000]
        json.merge(extra) { $1 }
        return ClaudeConnector.Session(json: json)!
    }

    @Test func activityFromTurn() {
        let end = Date(milliseconds: 1_500)
        #expect(ClaudeConnector.activity(session: session(["lastFocusedAt": 1_200]), turn: .ended(at: end), appRunning: true, hookWaiting: nil)
            == .finished(at: end, unread: true))
        #expect(ClaudeConnector.activity(session: session(["lastFocusedAt": 1_600]), turn: .ended(at: end), appRunning: true, hookWaiting: nil)
            == .finished(at: end, unread: false))
        #expect(ClaudeConnector.activity(session: session(["turnWrapUp": ["description": "d", "needsUser": "On valide ?"]]),
                                         turn: .ended(at: end), appRunning: true, hookWaiting: nil) == .waiting(since: end))
        #expect(ClaudeConnector.activity(session: session(), turn: .inProgress(questionSince: nil), appRunning: false, hookWaiting: nil) == .idle)
        #expect(ClaudeConnector.activity(session: session(), turn: .inProgress(questionSince: nil), appRunning: true, hookWaiting: nil) == .running)
        let hook = Date(milliseconds: 1_100)
        #expect(ClaudeConnector.activity(session: session(), turn: .inProgress(questionSince: nil), appRunning: true, hookWaiting: hook) == .waiting(since: hook))
        // Un hook antérieur au dernier message de l'utilisateur est périmé.
        #expect(ClaudeConnector.activity(session: session(), turn: .inProgress(questionSince: nil), appRunning: true,
                                         hookWaiting: Date(milliseconds: 900)) == .waiting(since: Date(milliseconds: 900)))
        #expect(ClaudeConnector.activity(session: session(["latestUserFrameAt": 5_000]), turn: .inProgress(questionSince: nil), appRunning: true,
                                         hookWaiting: Date(milliseconds: 900)) == .running)
    }

    @Test func fallsBackToDesktopTimestampsWithoutTranscript() {
        let s = session(["lastTurnEdgeAt": 1_500, "lastFocusedAt": 1_600])
        #expect(ClaudeConnector.activity(session: s, turn: nil, appRunning: true, hookWaiting: nil)
            == .finished(at: Date(milliseconds: 1_500), unread: false))
        let busy = session(["lastTurnEdgeAt": 500])
        #expect(ClaudeConnector.activity(session: busy, turn: nil, appRunning: true, hookWaiting: nil) == .running)
    }
}

@Suite("Fichiers")
struct FileTests {
    @Test func tailSkipsTruncatedFirstLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        var text = ""
        for i in 0..<200 { text += "{\"i\":\(i),\"pad\":\"\(String(repeating: "x", count: 50))\"}\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let objects = JSONLTail.objects(at: url, initialBytes: 500, isEnough: { _ in true })!
        #expect(!objects.isEmpty)
        #expect(objects.last?["i"] as? Int == 199)
        let grown = JSONLTail.objects(at: url, initialBytes: 500, isEnough: { $0.contains { $0["i"] as? Int == 10 } })!
        #expect(grown.contains { $0["i"] as? Int == 10 })
    }

    @Test func titleNormalization() {
        #expect(Text.title("  Premier   titre\nseconde ligne") == "Premier titre")
        #expect(Text.title("") == "Sans titre")
        #expect(Text.title(String(repeating: "a", count: 100)).count == 80)
    }
}
