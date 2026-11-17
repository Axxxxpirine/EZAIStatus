import Foundation

public struct TrackedSubagent: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: ConversationState
    public var kind: ObservedSubagent.Kind = .agent
    public var startedAt: Date?
}

public struct TrackedConversation: Identifiable, Equatable, Sendable {
    public var id: String
    public var source: SourceKind
    public var title: String
    public var state: ConversationState
    /// Début de l'attente ou fin de l'exécution ; date de détection pour « en cours ».
    public var date: Date
    public var openURL: URL?
    public var project: String?
    /// Affichés sous la conversation, jamais comptés dans les compteurs.
    public var subagents: [TrackedSubagent] = []
}

public struct SourceReport: Identifiable, Equatable, Sendable {
    public var source: SourceKind
    public var status: SourceStatus
    public var note: String?
    public var id: SourceKind { source }
}

public struct Snapshot: Equatable, Sendable {
    public var conversations: [TrackedConversation] = []
    public var reports: [SourceReport] = []

    public init(conversations: [TrackedConversation] = [], reports: [SourceReport] = []) {
        self.conversations = conversations
        self.reports = reports
    }

    public func count(_ state: ConversationState) -> Int {
        conversations.filter { $0.state == state }.count
    }

    public func conversations(in state: ConversationState) -> [TrackedConversation] {
        conversations.filter { $0.state == state }.sorted { $0.date > $1.date }
    }

    public var problems: [SourceReport] { reports.filter { $0.status.isProblem } }
}

/// Événement digne d'une notification : nouvelle fin ou nouvelle attente, une seule fois.
public struct Transition: Equatable, Sendable {
    public var conversation: TrackedConversation
}

/// Mémoire locale minimale : début du suivi, fins acquittées, événements déjà notifiés.
public struct TrackerMemory: Codable, Equatable, Sendable {
    public var trackingStartedAt: Date
    public var acknowledged: [String: Date] = [:]
    public var notified: [String: Date] = [:]

    public init(trackingStartedAt: Date) { self.trackingStartedAt = trackingStartedAt }
}

public final class Tracker {
    public private(set) var memory: TrackerMemory
    private var hasPublished = false
    private let storeURL: URL?
    private var lastResults: [ConnectorResult] = []

    /// `storeURL` nil : mémoire non persistée (tests).
    public init(storeURL: URL?, now: Date = Date()) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder.memory.decode(TrackerMemory.self, from: data) {
            memory = saved
        } else {
            // Premier lancement : seules les fins postérieures comptent, pas tout l'historique.
            memory = TrackerMemory(trackingStartedAt: now)
        }
    }

    public static func defaultStoreURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        ClaudeHooks.supportDir(home: home).appendingPathComponent("state.json")
    }

    /// Calcule l'instantané et les transitions à notifier. Le premier appel ne notifie rien.
    public func update(_ results: [ConnectorResult], now: Date = Date()) -> (Snapshot, [Transition]) {
        lastResults = results
        let snapshot = makeSnapshot(results, now: now)
        var transitions: [Transition] = []
        for conversation in snapshot.conversations where conversation.state != .running {
            let key = Self.eventKey(conversation)
            if memory.notified[key] == nil {
                memory.notified[key] = now
                if hasPublished { transitions.append(Transition(conversation: conversation)) }
            }
        }
        hasPublished = true
        prune(now: now)
        save()
        return (snapshot, transitions)
    }

    /// Retire une fin du compteur après ouverture effective de la conversation.
    @discardableResult
    public func acknowledge(_ conversation: TrackedConversation, now: Date = Date()) -> Snapshot {
        guard conversation.state == .finished else { return makeSnapshot(lastResults, now: now) }
        memory.acknowledged[conversation.id] = conversation.date
        save()
        return makeSnapshot(lastResults, now: now)
    }

    func makeSnapshot(_ results: [ConnectorResult], now: Date) -> Snapshot {
        var conversations: [TrackedConversation] = []
        var seen = Set<String>()
        for result in results {
            for observation in result.observations where !seen.contains(observation.id) {
                guard let tracked = track(observation, now: now) else { continue }
                seen.insert(observation.id)
                conversations.append(tracked)
            }
        }
        let reports = results.map { SourceReport(source: $0.source, status: $0.status, note: $0.note) }
        return Snapshot(conversations: conversations, reports: reports)
    }

    func track(_ observation: ObservedConversation, now: Date) -> TrackedConversation? {
        let subagents = observation.subagents.compactMap { subagent -> TrackedSubagent? in
            let state: ConversationState
            switch subagent.activity {
            case .running: state = .running
            case .waiting: state = .waiting
            case .finished: state = .finished
            case .idle: return nil
            }
            return TrackedSubagent(id: subagent.id, title: subagent.title, state: state,
                                   kind: subagent.kind, startedAt: subagent.startedAt)
        }
        let subagentsActive = subagents.contains { $0.state != .finished }

        var state: ConversationState?
        var date = now
        switch observation.activity {
        case .idle:
            break
        case .running:
            state = .running
        case .waiting(let since):
            state = .waiting
            date = since
        case .finished(let at, let unread):
            let acknowledged = memory.acknowledged[observation.id].map { $0 >= at } ?? false
            if unread, at > memory.trackingStartedAt, !acknowledged {
                state = .finished
                date = at
            }
        }
        // Conversation consultée ou au repos dont des sous-agents travaillent encore : elle reste visible.
        if state == nil, subagentsActive { state = .running }
        guard let state else { return nil }
        return TrackedConversation(id: observation.id, source: observation.source, title: observation.title,
                                   state: state, date: date, openURL: observation.openURL,
                                   project: observation.project, subagents: subagents)
    }

    static func eventKey(_ conversation: TrackedConversation) -> String {
        "\(conversation.id)|\(conversation.state.rawValue)|\(Int(conversation.date.timeIntervalSince1970))"
    }

    private func prune(now: Date) {
        let horizon = now.addingTimeInterval(-14 * 24 * 3600)
        memory.notified = memory.notified.filter { $0.value > horizon }
        memory.acknowledged = memory.acknowledged.filter { $0.value > horizon }
    }

    private func save() {
        guard let storeURL else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.memory.encode(memory) { try? data.write(to: storeURL, options: .atomic) }
    }
}

private extension JSONEncoder {
    static var memory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var memory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// Toutes les sources, chacune isolée dans son connecteur.
public enum Connectors {
    public static let all: [any Connector] = [CodexConnector(), ClaudeConnector()]

    public static func scanAll(_ context: ScanContext) -> [ConnectorResult] {
        all.flatMap { $0.scan(context) }
    }
}
