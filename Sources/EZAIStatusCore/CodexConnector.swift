import Foundation

/// Codex (app ChatGPT/Codex d'OpenAI).
///
/// - Liste des conversations : `~/.codex/state_N.sqlite`, table `threads` (sous-agents exclus).
/// - Consultation : `thread_read_receipts.first_unread_turn`, tenu par Codex lui-même.
/// - État d'exécution : fin du fichier rollout `.jsonl` (`task_started`, `task_complete`, `turn_aborted`).
/// - Attente explicite : appel `request_user_input` sans réponse dans le tour en cours.
public struct CodexConnector: Connector {
    public init() {}

    public var sources: [SourceKind] { [.codex] }

    static func codexHome(_ home: URL) -> URL { home.appendingPathComponent(".codex", isDirectory: true) }

    public func watchPaths(home: URL) -> [URL] {
        let root = Self.codexHome(home)
        return [root.appendingPathComponent("sessions", isDirectory: true), root]
    }

    /// La base d'état la plus récente (`state_5.sqlite` au 15.11.2026).
    static func stateDatabase(in root: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return files
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                      let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
                return (version, name)
            }
            .max { $0.0 < $1.0 }
            .map { root.appendingPathComponent($0.1) }
    }

    public func scan(_ context: ScanContext) -> [ConnectorResult] {
        [scanCodex(context)]
    }

    private func scanCodex(_ context: ScanContext) -> ConnectorResult {
        let root = Self.codexHome(context.home)
        guard FileManager.default.isDirectory(root) else {
            return ConnectorResult(source: .codex, status: .notInstalled)
        }
        guard let dbURL = Self.stateDatabase(in: root), let db = ReadOnlyDatabase(url: dbURL) else {
            return ConnectorResult(source: .codex, status: .unreadable(L10n.t("Base d'état Codex introuvable ou verrouillée.", "Codex state database missing or locked.")))
        }
        let threadColumns = db.columns(of: "threads")
        let required: Set<String> = ["id", "rollout_path", "title", "archived", "updated_at"]
        guard required.isSubset(of: threadColumns) else {
            return ConnectorResult(source: .codex, status: .unreadable(L10n.t("Format de la base Codex inconnu (\(dbURL.lastPathComponent)).", "Unknown Codex database format (\(dbURL.lastPathComponent)).")))
        }
        let hasReceipts = db.columns(of: "thread_read_receipts").contains("first_unread_turn")
        let titleExpr = threadColumns.contains("name") ? "coalesce(nullif(t.name, ''), t.title)" : "t.title"
        let updatedExpr = threadColumns.contains("updated_at_ms") ? "coalesce(t.updated_at_ms, t.updated_at * 1000)" : "t.updated_at * 1000"
        var filters = ["t.archived = 0", "\(updatedExpr) >= ?"]
        if threadColumns.contains("thread_source") { filters.append("coalesce(t.thread_source, '') <> 'subagent'") }
        if threadColumns.contains("source") { filters.append("t.source NOT LIKE '{\"subagent\"%'") }
        let receiptJoin = hasReceipts ? "LEFT JOIN thread_read_receipts r ON r.thread_id = t.id" : ""
        let receiptSelect = hasReceipts ? ", r.thread_id AS receipt, r.first_unread_turn AS unread_turn" : ""
        let hasProjects = threadColumns.contains("project_id") && db.columns(of: "projects").contains("name")
        let projectJoin = hasProjects ? "LEFT JOIN projects p ON p.id = t.project_id" : ""
        let projectSelect = hasProjects ? ", p.name AS project_name" : ""
        let cwdSelect = threadColumns.contains("cwd") ? ", t.cwd" : ""
        let sql = """
            SELECT t.id, t.rollout_path, \(titleExpr) AS title, \(updatedExpr) AS updated_ms\(receiptSelect)\(projectSelect)\(cwdSelect)
            FROM threads t \(receiptJoin) \(projectJoin)
            WHERE \(filters.joined(separator: " AND "))
            ORDER BY updated_ms DESC LIMIT 200
            """
        let rows = db.rows(sql, [(context.now.timeIntervalSince1970 - context.lookback) * 1000])
        let appRunning = context.isRunning(.codex)

        let since = (context.now.timeIntervalSince1970 - context.lookback) * 1000
        let children = Self.subagents(db: db, threadColumns: threadColumns, updatedExpr: updatedExpr, since: since, appRunning: appRunning)

        let observations = rows.compactMap { row -> ObservedConversation? in
            guard let id = row["id"] as? String, let path = row["rollout_path"] as? String else { return nil }
            let unread: Bool
            if hasReceipts {
                // Pas de reçu : Codex ne sait pas, on considère non lu pour ne pas perdre une fin.
                unread = row["receipt"] == nil || row["unread_turn"] != nil
            } else {
                unread = true
            }
            let objects = Self.rolloutObjects(URL(fileURLWithPath: path))
            let activity = objects.map { Self.activity(objects: $0, unread: unread, appRunning: appRunning) } ?? .idle
            let project = (row["project_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ProjectName.from(path: row["cwd"] as? String)
            let turnStart = objects.flatMap(Self.turnStart)
            return ObservedConversation(id: "codex:\(id)", source: .codex,
                                        title: Text.title(row["title"] as? String),
                                        activity: activity,
                                        openURL: URL(string: "codex://threads/\(id)"),
                                        project: project,
                                        subagents: SubagentFilter.visible(children[id] ?? [], since: turnStart))
        }
        return ConnectorResult(source: .codex, status: .ok, observations: observations,
                               note: L10n.t("Les demandes d'approbation de commandes ne sont pas écrites sur disque ; seules les questions posées par l'agent comptent comme attente.",
                                             "Command approval requests are not written to disk; only questions asked by the agent count as waiting."))
    }

    static let lifecycle: Set<String> = ["task_started", "task_complete", "turn_aborted"]

    static let rolloutMemo = FileMemo<[[String: Any]]?>()

    /// Sous-agents Codex (`thread_spawn_edges`), regroupés par fil parent.
    static func subagents(db: ReadOnlyDatabase, threadColumns: Set<String>, updatedExpr: String,
                          since: Double, appRunning: Bool) -> [String: [ObservedSubagent]] {
        guard db.columns(of: "thread_spawn_edges").contains("parent_thread_id") else { return [:] }
        let nickname = threadColumns.contains("agent_nickname") ? "t.agent_nickname" : "NULL"
        let role = threadColumns.contains("agent_role") ? "t.agent_role" : "NULL"
        let agentPath = threadColumns.contains("agent_path") ? "t.agent_path" : "NULL"
        let rows = db.rows("""
            SELECT e.parent_thread_id AS parent, t.id, t.rollout_path, t.title,
                   \(nickname) AS nickname, \(role) AS role, \(agentPath) AS agent_path
            FROM thread_spawn_edges e JOIN threads t ON t.id = e.child_thread_id
            WHERE \(updatedExpr) >= ?
            """, [since])
        var result: [String: [ObservedSubagent]] = [:]
        for row in rows {
            guard let parent = row["parent"] as? String, let id = row["id"] as? String,
                  let path = row["rollout_path"] as? String else { continue }
            let activity = rolloutObjects(URL(fileURLWithPath: path))
                .map { Self.activity(objects: $0, unread: false, appRunning: appRunning) } ?? .idle
            result[parent, default: []].append(ObservedSubagent(id: "codex:\(id)", title: subagentTitle(row), activity: activity))
        }
        return result
    }

    /// « Tesla · brief_builder_check » : surnom donné par Codex et mission (dernier élément du chemin d'agent).
    static func subagentTitle(_ row: [String: Any]) -> String {
        let nickname = (row["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let mission = (row["agent_path"] as? String).map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ") }
            ?? (row["role"] as? String)
        let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let parts = [nickname, mission.flatMap { $0.isEmpty ? nil : $0 } ?? title].compactMap { $0 }
        return Text.title(parts.joined(separator: " · "), fallback: L10n.t("Sous-agent", "Subagent"))
    }

    static func turnStart(_ objects: [[String: Any]]) -> Date? {
        guard let start = objects.last(where: { isLifecycle($0) && ($0["payload"] as? [String: Any])?["type"] as? String == "task_started" })
        else { return nil }
        return ISODate.parse(start["timestamp"])
    }

    static func activity(rollout: URL, unread: Bool, appRunning: Bool) -> Activity {
        rolloutObjects(rollout).map { activity(objects: $0, unread: unread, appRunning: appRunning) } ?? .idle
    }

    static func rolloutObjects(_ rollout: URL) -> [[String: Any]]? {
        // On ne garde que les lignes utiles à la décision pour limiter la mémoire du cache.
        rolloutMemo.value(for: rollout) { () -> [[String: Any]]? in
            JSONLTail.objects(at: rollout, markers: ["task_started", "task_complete", "turn_aborted", "\"call_id\""],
                              keepLast: 400, isEnough: { objects in
                objects.contains { isLifecycle($0) }
            })?.filter { isLifecycle($0) || $0["type"] as? String == "response_item" && ($0["payload"] as? [String: Any])?["call_id"] != nil }
            .map { object in
                var slim = object
                if var payload = object["payload"] as? [String: Any] {
                    payload = payload.filter { ["type", "name", "call_id"].contains($0.key) }
                    slim["payload"] = payload
                }
                return slim
            }
        }
    }

    static func isLifecycle(_ object: [String: Any]) -> Bool {
        guard object["type"] as? String == "event_msg",
              let type = (object["payload"] as? [String: Any])?["type"] as? String else { return false }
        return lifecycle.contains(type)
    }

    static func activity(objects: [[String: Any]], unread: Bool, appRunning: Bool) -> Activity {
        guard let lastIndex = objects.lastIndex(where: isLifecycle),
              let payload = objects[lastIndex]["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return .idle }
        let timestamp = ISODate.parse(objects[lastIndex]["timestamp"]) ?? .distantPast

        switch type {
        case "task_complete":
            return .finished(at: timestamp, unread: unread)
        case "task_started":
            // Codex fermé en plein tour : le fichier reste « commencé », ce n'est pas une exécution réelle.
            guard appRunning else { return .idle }
            var pending: [String: Date] = [:]
            for object in objects[(lastIndex + 1)...] {
                guard object["type"] as? String == "response_item",
                      let item = object["payload"] as? [String: Any],
                      let callID = item["call_id"] as? String else { continue }
                switch item["type"] as? String {
                case "function_call", "custom_tool_call":
                    if let name = item["name"] as? String, name.hasPrefix("request_user_input") {
                        pending[callID] = ISODate.parse(object["timestamp"]) ?? timestamp
                    }
                case "function_call_output", "custom_tool_call_output":
                    pending[callID] = nil
                default:
                    break
                }
            }
            if let since = pending.values.min() { return .waiting(since: since) }
            return .running
        default:
            // Tour interrompu par l'utilisateur : rien à signaler.
            return .idle
        }
    }
}
