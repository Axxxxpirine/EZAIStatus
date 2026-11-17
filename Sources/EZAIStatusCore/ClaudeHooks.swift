import Foundation

/// Hook officiel de Claude Code, facultatif et installé uniquement à la demande de l'utilisateur.
///
/// Claude Code appelle un petit script à chaque événement `Notification`, `UserPromptSubmit`,
/// `PostToolUse` et `Stop`. Le script ajoute une ligne à `claude-hooks.jsonl` ; EZAIStatus en déduit
/// qu'une session attend une autorisation (notification `permission_prompt` non suivie d'un autre événement).
public enum ClaudeHooks {
    public static let events = ["Notification", "UserPromptSubmit", "PostToolUse", "Stop"]

    public static func supportDir(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/EZAIStatus", isDirectory: true)
    }

    public static func eventsFile(home: URL) -> URL {
        supportDir(home: home).appendingPathComponent("claude-hooks/events.jsonl")
    }

    static func scriptFile(home: URL) -> URL {
        supportDir(home: home).appendingPathComponent("claude-hook.sh")
    }

    static func settingsFile(home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    static let marker = "EZAIStatus/claude-hook.sh"

    /// Ne garde que trois identifiants : jamais le contenu des messages ni les sorties d'outils.
    /// `plutil` (fourni avec macOS) lit le JSON reçu sur l'entrée standard, sans dépendance externe.
    static let script = """
        #!/bin/sh
        # Installé par EZAIStatus. Note la session, le type d'événement et le type de notification
        # reçus de Claude Code dans un journal local, sans réseau ni contenu des conversations.
        dir="$HOME/Library/Application Support/EZAIStatus/claude-hooks"
        mkdir -p "$dir"
        input=$(cat)
        field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null | tr -cd 'A-Za-z0-9_.-'; }
        event=$(field hook_event_name)
        type=""
        [ "$event" = "Notification" ] && type=$(field notification_type)
        printf '{"ts":%s,"event":{"session_id":"%s","hook_event_name":"%s","notification_type":"%s"}}\\n' \\
          "$(date +%s)" "$(field session_id)" "$event" "$type" >> "$dir/events.jsonl"
        exit 0

        """

    /// Met à jour le script d'un hook déjà installé par une version précédente ; repart d'un journal vide.
    public static func refreshScriptIfInstalled(home: URL) {
        guard isInstalled(home: home) else { return }
        let url = scriptFile(home: home)
        guard (try? String(contentsOf: url, encoding: .utf8)) != script else { return }
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: eventsFile(home: home))
    }

    // MARK: Lecture

    /// Sessions (identifiant CLI) dont le dernier événement est une demande d'autorisation, avec sa date.
    public static func waitingSessions(home: URL) -> [String: Date] {
        let url = eventsFile(home: home)
        guard let objects = JSONLTail.objects(at: url, initialBytes: 64 * 1024, maxBytes: 64 * 1024, isEnough: { _ in true })
        else { return [:] }
        return waitingSessions(in: objects)
    }

    static func waitingSessions(in objects: [[String: Any]]) -> [String: Date] {
        var latest: [String: (date: Date, waiting: Bool)] = [:]
        for object in objects {
            guard let event = object["event"] as? [String: Any],
                  let session = event["session_id"] as? String,
                  let name = event["hook_event_name"] as? String else { continue }
            let date = Date(timeIntervalSince1970: number(object["ts"]) ?? 0)
            var waiting = false
            if name == "Notification" {
                waiting = event["notification_type"] as? String == "permission_prompt"
                // Les autres notifications (inactivité, etc.) ne changent pas l'état.
                if !waiting { continue }
            }
            latest[session] = (date, waiting)
        }
        return latest.compactMapValues { $0.waiting ? $0.date : nil }
    }

    /// Garde le journal petit : au-delà de 512 Ko, on conserve les 300 dernières lignes.
    public static func compactIfNeeded(home: URL) {
        let url = eventsFile(home: home)
        guard let size = FileStat(url)?.size, size > 512 * 1024,
              let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n")).suffix(300)
        var output = Data()
        for line in lines { output.append(contentsOf: line); output.append(UInt8(ascii: "\n")) }
        try? output.write(to: url, options: .atomic)
    }

    // MARK: Installation

    public static func isInstalled(home: URL) -> Bool {
        guard let settings = readSettings(home: home) else { return false }
        return containsMarker(settings)
    }

    public static func install(home: URL) throws {
        let fm = FileManager.default
        let script = scriptFile(home: home)
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var settings = readSettings(home: home) ?? [:]
        settings = removingMarker(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command = "\"\(script.path)\""
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 5]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings, home: home)
    }

    public static func uninstall(home: URL) throws {
        if var settings = readSettings(home: home) {
            settings = removingMarker(settings)
            try writeSettings(settings, home: home)
        }
        try? FileManager.default.removeItem(at: scriptFile(home: home))
    }

    static func readSettings(home: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile(home: home)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func writeSettings(_ settings: [String: Any], home: URL) throws {
        let url = settingsFile(home: home)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copie de sécurité avant toute modification d'un fichier qui n'appartient pas à EZAIStatus.
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.ezaistatus-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func containsMarker(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains(where: isOurGroup)
        }
    }

    static func isOurGroup(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains(marker) }
    }

    static func removingMarker(_ settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurGroup($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }
}
