import Foundation

/// Application ou mode Claude d'où vient une conversation.
public enum SourceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claudeCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    /// Badge court affiché devant le titre, comme dans la maquette.
    public var badge: String {
        switch self {
        case .codex: "Cx"
        case .claudeCode: "Cl"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .codex: "com.openai.codex"
        case .claudeCode: "com.anthropic.claudefordesktop"
        }
    }
}

/// Les trois états suivis, dans l'ordre d'affichage validé.
public enum ConversationState: Int, CaseIterable, Comparable, Sendable {
    case waiting = 0
    case running = 1
    case finished = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .waiting: L10n.t("Attend ta réponse", "Waiting for you")
        case .running: L10n.t("En cours", "Running")
        case .finished: L10n.t("Terminé", "Finished")
        }
    }

    public var glyph: String {
        switch self {
        case .waiting: "!"
        case .running: "◌"
        case .finished: "✓"
        }
    }
}

/// Ce qu'un connecteur observe pour une conversation, avant acquittement et filtrage de l'historique.
public enum Activity: Equatable, Sendable {
    case running
    /// Signal explicite de demande d'intervention. `since` sert à dédupliquer les notifications.
    case waiting(since: Date)
    /// Dernière exécution terminée. `unread` vient de l'app source quand elle le sait.
    case finished(at: Date, unread: Bool)
    case idle
}

/// Sous-agent lancé par une conversation : affiché sous elle, jamais compté à part.
public struct ObservedSubagent: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case agent, command }

    public var id: String
    public var title: String
    public var activity: Activity
    /// Sous-agent, ou commande passée en arrière-plan qui tourne encore.
    public var kind: Kind
    /// Démarrage, quand il est connu (commandes) : signale les boucles oubliées depuis longtemps.
    public var startedAt: Date?

    public init(id: String, title: String, activity: Activity, kind: Kind = .agent, startedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.activity = activity
        self.kind = kind
        self.startedAt = startedAt
    }
}

public struct ObservedConversation: Equatable, Sendable, Identifiable {
    /// Identifiant unique toutes sources confondues, préfixé par la source.
    public var id: String
    public var source: SourceKind
    public var title: String
    public var activity: Activity
    /// Lien qui ouvre directement la conversation, s'il existe.
    public var openURL: URL?
    /// Nom du projet ou du dossier de travail, quand l'app source en a un.
    public var project: String?
    /// Sous-agents actifs ou terminés pendant le tour en cours.
    public var subagents: [ObservedSubagent]

    public init(id: String, source: SourceKind, title: String, activity: Activity, openURL: URL?,
                project: String? = nil, subagents: [ObservedSubagent] = []) {
        self.id = id
        self.source = source
        self.title = title
        self.activity = activity
        self.openURL = openURL
        self.project = project
        self.subagents = subagents
    }
}

public enum SourceStatus: Equatable, Sendable {
    case ok
    /// App absente de ce Mac : rien à suivre, pas une erreur.
    case notInstalled
    /// Mode connu mais non pris en charge, avec la raison affichée à l'utilisateur.
    case unsupported(String)
    /// Source attendue mais illisible : ne jamais l'afficher comme zéro conversation.
    case unreadable(String)

    public var isProblem: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

public struct ConnectorResult: Sendable {
    public var source: SourceKind
    public var status: SourceStatus
    public var observations: [ObservedConversation]
    /// Remarque visible dans les réglages (par exemple « en cours non détectable »).
    public var note: String?

    public init(source: SourceKind, status: SourceStatus, observations: [ObservedConversation] = [], note: String? = nil) {
        self.source = source
        self.status = status
        self.observations = observations
        self.note = note
    }
}

/// Environnement d'un balayage, injectable pour les tests.
public struct ScanContext: Sendable {
    public var home: URL
    public var now: Date
    /// Conversations plus anciennes ignorées : on ne charge pas tout l'historique.
    public var lookback: TimeInterval
    public var runningBundleIDs: Set<String>

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: Date = Date(),
                lookback: TimeInterval = 3 * 24 * 3600,
                runningBundleIDs: Set<String> = []) {
        self.home = home
        self.now = now
        self.lookback = lookback
        self.runningBundleIDs = runningBundleIDs
    }

    public func isRunning(_ source: SourceKind) -> Bool {
        runningBundleIDs.contains(source.bundleIdentifier)
    }
}

public protocol Connector: Sendable {
    var sources: [SourceKind] { get }
    /// Dossiers à surveiller par FSEvents.
    func watchPaths(home: URL) -> [URL]
    func scan(_ context: ScanContext) -> [ConnectorResult]
}

enum Text {
    /// Première ligne, espaces normalisés, longueur bornée.
    static func title(_ raw: String?, fallback: String? = nil, limit: Int = 80) -> String {
        let firstLine = (raw ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback ?? L10n.t("Sans titre", "Untitled") }
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }
}

enum ProjectName {
    /// Nom lisible d'un dossier de travail : le dépôt d'origine pour une worktree, rien pour un dossier temporaire.
    static func from(path: String?) -> String? {
        guard var path, !path.isEmpty else { return nil }
        for marker in ["/.claude/worktrees/", "/.codex/worktrees/"] {
            if let range = path.range(of: marker) {
                if marker == "/.claude/worktrees/" {
                    path = String(path[..<range.lowerBound])
                } else {
                    // ~/.codex/worktrees/<id>/<dépôt> : le dernier composant est déjà le dépôt.
                    break
                }
            }
        }
        // Conversations Codex sans projet : dossier daté créé automatiquement.
        if path.range(of: #"/Codex/\d{4}-\d{2}-\d{2}(/|$)"#, options: .regularExpression) != nil { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home || path == "/" { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

/// Règle commune d'affichage des sous-agents : actifs, ou terminés depuis le début du tour du parent.
enum SubagentFilter {
    static let limit = 6

    static func visible(_ subagents: [ObservedSubagent], since turnStart: Date?) -> [ObservedSubagent] {
        let kept = subagents.filter { subagent in
            switch subagent.activity {
            case .running, .waiting: return true
            case .finished(let at, _): return turnStart.map { at >= $0 } ?? false
            case .idle: return false
            }
        }
        return kept.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ subagent: ObservedSubagent) -> (Int, Double) {
        switch subagent.activity {
        case .waiting(let since): (0, -since.timeIntervalSince1970)
        case .running: (1, 0)
        case .finished(let at, _): (2, -at.timeIntervalSince1970)
        case .idle: (3, 0)
        }
    }
}

extension Date {
    init(milliseconds: Double) { self.init(timeIntervalSince1970: milliseconds / 1000) }
}
