import Foundation

/// État résumé écrit pour les outils externes (touche Stream Deck). Réécrit à chaque balayage : `writtenAt` sert de
/// battement de cœur, un fichier trop vieux veut dire que l'app ne tourne plus.
public struct StatusExport: Codable, Equatable, Sendable {
    public var version: Int
    public var writtenAt: Date
    public var running: Int
    public var waiting: Int
    public var finished: Int
    /// Sources illisibles : les compteurs peuvent alors être incomplets.
    public var unreadable: [String]

    public init(snapshot: Snapshot, now: Date) {
        version = 1
        writtenAt = now
        running = snapshot.count(.running)
        waiting = snapshot.count(.waiting)
        finished = snapshot.count(.finished)
        unreadable = snapshot.problems.map(\.source.displayName)
    }

    public static func fileURL(home: URL) -> URL {
        ClaudeHooks.supportDir(home: home).appendingPathComponent("status.json")
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Écriture atomique : un lecteur ne voit jamais un fichier à moitié écrit.
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension Snapshot {
    /// Conversation terminée la plus ancienne : la prochaine à ouvrir depuis la touche.
    public var oldestFinished: TrackedConversation? {
        conversations.filter { $0.state == .finished }.min { $0.date < $1.date }
    }
}
