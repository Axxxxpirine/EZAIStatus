import Foundation
import Testing
@testable import EZAIStatusCore

@Suite("Export Stream Deck")
struct StatusExportTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func conv(_ id: String, _ state: ConversationState, _ offset: TimeInterval) -> TrackedConversation {
        TrackedConversation(id: id, source: .codex, title: id, state: state, date: now.addingTimeInterval(offset))
    }

    @Test func countsComeFromSnapshot() {
        let snapshot = Snapshot(conversations: [conv("a", .running, 0), conv("b", .running, 0),
                                                conv("c", .finished, -10), conv("d", .waiting, -5)],
                                reports: [SourceReport(source: .claudeCode, status: .unreadable("x"))])
        let export = StatusExport(snapshot: snapshot, now: now)
        #expect(export.version == 1)
        #expect(export.running == 2)
        #expect(export.waiting == 1)
        #expect(export.finished == 1)
        #expect(export.unreadable == ["Claude Code"])
        #expect(export.writtenAt == now)
    }

    @Test func oldestFinishedIsTheEarliest() {
        let snapshot = Snapshot(conversations: [conv("new", .finished, -10), conv("old", .finished, -100),
                                                conv("run", .running, -500)])
        #expect(snapshot.oldestFinished?.id == "old")
        #expect(Snapshot().oldestFinished == nil)
    }

    @Test func writeIsReadableJSONAndRemoveIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("status.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try StatusExport(snapshot: Snapshot(conversations: [conv("a", .running, 0)]), now: now).write(to: url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["running"] as? Int == 1)
        #expect(json?["writtenAt"] as? String == "1970-01-24T03:33:20Z")
        StatusExport.remove(at: url)
        StatusExport.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileLivesInSupportDir() {
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(StatusExport.fileURL(home: home).path == "/tmp/home/Library/Application Support/EZAIStatus/status.json")
    }
}
