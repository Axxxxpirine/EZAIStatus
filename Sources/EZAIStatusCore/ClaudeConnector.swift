import Foundation

/// Claude Code dans l'app Claude desktop (Chat et Cowork ne laissent aucun état exploitable sur le Mac).
///
/// Chaque session du desktop a un fichier `local_<id>.json` qui contient notamment :
/// - `latestUserFrameAt` : dernier message de l'utilisateur ;
/// - `lastTurnEdgeAt` : fin du dernier tour de l'agent ;
/// - `lastFocusedAt` : dernière consultation de la session dans l'app ;
/// - `turnWrapUp.needsUser` : question explicite posée à la fin du tour (effacée au tour suivant).
/// La transcription (`~/.claude/projects/**/<cliSessionId>.jsonl`) complète l'attente pendant un tour
/// (outil `AskUserQuestion` ou `ExitPlanMode` sans réponse), et les hooks facultatifs signalent les autorisations.
public struct ClaudeConnector: Connector {
    public init() {}

    public var sources: [SourceKind] { [.claudeCode] }

    static let sessionMemo = FileMemo<Session?>()


    static let turnMemo = FileMemo<Turn?>()

    static func supportDir(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    static func sessionsDir(_ home: URL) -> URL {
        supportDir(home).appendingPathComponent("claude-code-sessions", isDirectory: true)
    }

    static func projectsDir(_ home: URL) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func watchPaths(home: URL) -> [URL] {
        [Self.sessionsDir(home), ClaudeHooks.eventsFile(home: home).deletingLastPathComponent()]
    }

    public func scan(_ context: ScanContext) -> [ConnectorResult] {
        let installed = FileManager.default.isDirectory(Self.supportDir(context.home))
        guard installed else {
            return sources.map { ConnectorResult(source: $0, status: .notInstalled) }
        }
        let hookStates = ClaudeHooks.waitingSessions(home: context.home)
        let liveTasks = OpenFiles.claudeLiveTasks()
        return [scan(.claudeCode, context, hookStates: hookStates, liveTasks: liveTasks)]
    }

    private func scan(_ source: SourceKind, _ context: ScanContext, hookStates: [String: Date],
                      liveTasks: [String: [String: Date]]) -> ConnectorResult {
        let root = Self.sessionsDir(context.home)
        let files = FileManager.default.isDirectory(root) ? Self.sessionFiles(in: root) : []
        let since = context.now.addingTimeInterval(-context.lookback)
        let appRunning = context.isRunning(source)
        var observations: [ObservedConversation] = []
        for file in files {
            // Tri rapide par date de modification avant de lire le JSON.
            if let modified = FileManager.default.modificationDate(file), modified < since { continue }
            let parsed = Self.sessionMemo.value(for: file) { () -> Session? in
                guard let data = try? Data(contentsOf: file),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                return Session(json: json)
            }
            guard let session = parsed,
                  !session.isArchived,
                  session.lastActivity >= since else { continue }
            let hookWaiting = session.cliSessionIDs.compactMap { hookStates[$0] }.max()
            let turn = Self.transcriptTurn(session: session, home: context.home)
            let activity = Self.activity(session: session, turn: turn, appRunning: appRunning, hookWaiting: hookWaiting)
            let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.id
            let subagents = Self.subagents(session: session, home: context.home, appRunning: appRunning)
                + Self.backgroundCommands(session: session, home: context.home, liveTasks: liveTasks)
            observations.append(ObservedConversation(id: "claude:\(session.id)", source: source,
                                                     title: Text.title(session.title),
                                                     activity: activity,
                                                     openURL: URL(string: "claude://code/continue?session=\(encoded)"),
                                                     project: ProjectName.from(path: session.originCwd ?? session.cwd),
                                                     subagents: SubagentFilter.visible(subagents, since: session.userFrame)))
        }
        let note = L10n.t("Sans le hook facultatif, les demandes d'autorisation d'outil ne comptent pas comme attente.",
                          "Without the optional hook, tool permission requests do not count as waiting.")
        return ConnectorResult(source: source, status: .ok, observations: observations, note: note)
    }

    static func sessionFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "skills-plugin" { enumerator.skipDescendants(); continue }
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            if url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" { files.append(url) }
        }
        return files
    }

    struct Session {
        var id: String
        var title: String?
        var isArchived: Bool
        var cliSessionIDs: [String]
        var lastActivity: Date
        var userFrame: Date?
        var turnEdge: Date?
        var focused: Date?
        var needsUser: String?
        var cwd: String?
        var originCwd: String?

        init?(json: [String: Any]) {
            guard let id = json["sessionId"] as? String else { return nil }
            self.id = id
            title = json["title"] as? String
            isArchived = json["isArchived"] as? Bool ?? false
            // Souvent deux fois le même identifiant : on dédoublonne en gardant l'ordre.
            var seen = Set<String>()
            cliSessionIDs = [json["cliSessionId"], json["lastAssistantCliSessionId"]]
                .compactMap { $0 as? String }
                .filter { seen.insert($0).inserted }
            func date(_ key: String) -> Date? { number(json[key]).map(Date.init(milliseconds:)) }
            userFrame = date("latestUserFrameAt")
            turnEdge = date("lastTurnEdgeAt")
            focused = date("lastFocusedAt")
            lastActivity = date("lastActivityAt") ?? turnEdge ?? userFrame ?? .distantPast
            needsUser = (json["turnWrapUp"] as? [String: Any])?["needsUser"] as? String
            cwd = json["cwd"] as? String
            originCwd = json["originCwd"] as? String
        }

        /// Un message de l'utilisateur est arrivé après la dernière fin de tour.
        var turnInProgress: Bool {
            guard let userFrame else { return false }
            guard let turnEdge else { return true }
            return userFrame > turnEdge
        }
    }

    /// État du dernier tour selon la transcription, plus fiable que les horodatages du desktop
    /// (`lastTurnEdgeAt` bouge aussi quand l'agent pose une question au milieu d'un tour).
    enum Turn: Equatable {
        case inProgress(questionSince: Date?)
        case ended(at: Date)
        case interrupted
    }

    static func activity(session: Session, turn: Turn?, appRunning: Bool, hookWaiting: Date?) -> Activity {
        let resolved: Turn
        if let turn {
            resolved = turn
        } else if session.turnInProgress {
            // Pas de transcription trouvée : horodatages du desktop.
            resolved = .inProgress(questionSince: nil)
        } else if let edge = session.turnEdge {
            resolved = .ended(at: edge)
        } else {
            return .idle
        }

        switch resolved {
        case .interrupted:
            return .idle
        case .inProgress(let questionSince):
            // App fermée en plein tour : pas d'exécution réelle, ni fausse fin.
            guard appRunning else { return .idle }
            if let questionSince { return .waiting(since: questionSince) }
            // Le script du hook date à la seconde près : tolérance d'une seconde face au dernier message.
            if let hookWaiting, hookWaiting.addingTimeInterval(1) >= (session.userFrame ?? .distantPast) {
                return .waiting(since: hookWaiting)
            }
            return .running
        case .ended(let at):
            if session.needsUser != nil { return .waiting(since: at) }
            let unread = (session.focused ?? .distantPast) < at
            return .finished(at: at, unread: unread)
        }
    }

    static func transcriptTurn(session: Session, home: URL) -> Turn? {
        for id in session.cliSessionIDs.reversed() {
            guard let url = transcript(for: id, cwd: session.cwd, home: home) else { continue }
            if let parsed = transcriptTurn(url: url) { return parsed }
        }
        return nil
    }

    /// `sidechain` : transcription d'un sous-agent, dont toutes les entrées sont marquées `isSidechain`.
    static func transcriptTurn(url: URL, sidechain: Bool = false) -> Turn? {
        turnMemo.value(for: url) { () -> Turn? in
            // Les dernières entrées de conversation suffisent : une question en attente est forcément récente.
            let objects = JSONLTail.objects(at: url, initialBytes: 64 * 1024, maxBytes: 2 * 1024 * 1024,
                                            markers: ["\"type\":\"user\"", "\"type\":\"assistant\""],
                                            keepLast: 12) { objects in
                objects.contains { isConversationEntry($0, sidechain: sidechain) }
            }
            return objects.flatMap { turn(in: $0, sidechain: sidechain) }
        }
    }

    static let subagentMetaMemo = FileMemo<[String: Any]?>()

    /// Sous-agents d'une session : `<transcription sans .jsonl>/subagents/agent-<id>.jsonl` et `.meta.json`
    /// (`description`, `finished`). Seuls les fichiers modifiés depuis le dernier message de l'utilisateur sont lus.
    static func subagents(session: Session, home: URL, appRunning: Bool) -> [ObservedSubagent] {
        let since = session.userFrame ?? .distantFuture
        var result: [ObservedSubagent] = []
        for id in session.cliSessionIDs {
            guard let transcript = transcript(for: id, cwd: session.cwd, home: home) else { continue }
            let dir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                guard let stat = FileStat(url) else { continue }
                let modified = Date(timeIntervalSince1970: stat.modified)
                // Un sous-agent en cours écrit sans cesse : un fichier ancien est terminé ou abandonné.
                guard modified >= since else { continue }
                let base = String(name.dropLast(6))
                let metaURL = dir.appendingPathComponent(base + ".meta.json")
                let meta = subagentMetaMemo.value(for: metaURL) { () -> [String: Any]? in
                    (try? Data(contentsOf: metaURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                }
                let activity: Activity
                if meta?["finished"] as? Bool == true {
                    activity = .finished(at: modified, unread: false)
                } else {
                    switch transcriptTurn(url: url, sidechain: true) {
                    case .ended(let at): activity = .finished(at: at, unread: false)
                    case .inProgress(let question): activity = !appRunning ? .idle : question.map { .waiting(since: $0) } ?? .running
                    case .interrupted, nil: activity = .idle
                    }
                }
                let description = (meta?["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                result.append(ObservedSubagent(id: "claude:\(base)", title: Text.title(description, fallback: L10n.t("Sous-agent", "Subagent")),
                                               activity: activity))
            }
        }
        return result
    }

    /// Commandes passées en arrière-plan qui tournent encore (processus vivant), lancées par la session
    /// ou par l'un de ses sous-agents, même terminé.
    static func backgroundCommands(session: Session, home: URL, liveTasks: [String: [String: Date]]) -> [ObservedSubagent] {
        var result: [ObservedSubagent] = []
        for id in session.cliSessionIDs {
            guard let tasks = liveTasks[id], !tasks.isEmpty,
                  let transcript = transcript(for: id, cwd: session.cwd, home: home) else { continue }
            let subagentDir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            let subagentFiles = ((try? FileManager.default.contentsOfDirectory(atPath: subagentDir.path)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .compactMap { name -> (URL, Double)? in
                    let url = subagentDir.appendingPathComponent(name)
                    return FileStat(url).map { (url, $0.modified) }
                }
            for (task, started) in tasks {
                // L'annonce du passage en arrière-plan est écrite après le démarrage : fichiers modifiés depuis, les plus proches d'abord.
                let candidates = subagentFiles
                    .filter { $0.1 >= started.timeIntervalSince1970 - 120 }
                    .sorted { $0.1 < $1.1 }
                    .prefix(25)
                    .map(\.0)
                guard let title = BackgroundCommandIndex.shared.description(of: task, in: [transcript] + candidates) else { continue }
                result.append(ObservedSubagent(id: "task:\(task)", title: Text.title(title, fallback: L10n.t("Commande en arrière-plan", "Background command")),
                                               activity: .running, kind: .command, startedAt: started))
            }
        }
        return result
    }

    static func isConversationEntry(_ object: [String: Any], sidechain: Bool = false) -> Bool {
        guard let type = object["type"] as? String, type == "user" || type == "assistant" else { return false }
        return sidechain || object["isSidechain"] as? Bool != true
    }

    static func turn(in objects: [[String: Any]], sidechain: Bool = false) -> Turn? {
        guard let last = objects.last(where: { isConversationEntry($0, sidechain: sidechain) }),
              let message = last["message"] as? [String: Any] else { return nil }
        let timestamp = ISODate.parse(last["timestamp"]) ?? .distantPast
        if last["type"] as? String == "assistant" {
            switch message["stop_reason"] as? String {
            case "end_turn", "stop_sequence", "max_tokens", "refusal":
                return .ended(at: timestamp)
            default:
                break
            }
        } else if isInterruption(message) {
            return .interrupted
        }
        return .inProgress(questionSince: pendingQuestion(in: objects, sidechain: sidechain))
    }

    static func isInterruption(_ message: [String: Any]) -> Bool {
        let texts: [String]
        if let text = message["content"] as? String {
            texts = [text]
        } else {
            texts = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        return texts.contains { $0.hasPrefix("[Request interrupted") }
    }

    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func pendingQuestion(in objects: [[String: Any]], sidechain: Bool = false) -> Date? {
        var pending: [String: Date] = [:]
        for object in objects where isConversationEntry(object, sidechain: sidechain) {
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let timestamp = ISODate.parse(object["timestamp"]) ?? Date()
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let name = block["name"] as? String, questionTools.contains(name), let id = block["id"] as? String {
                        pending[id] = timestamp
                    }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { pending[id] = nil }
                default:
                    break
                }
            }
        }
        return pending.values.min()
    }

    static func transcript(for cliSessionID: String, cwd: String?, home: URL) -> URL? {
        let projects = projectsDir(home)
        if let cwd {
            // Claude Code nomme le dossier d'après le chemin, chaque caractère non alphanumérique devenant « - ».
            let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let candidate = projects.appendingPathComponent(encoded).appendingPathComponent("\(cliSessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for dir in dirs {
            let candidate = projects.appendingPathComponent(dir).appendingPathComponent("\(cliSessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
