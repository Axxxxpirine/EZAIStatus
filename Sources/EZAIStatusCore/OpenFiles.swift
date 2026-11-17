import Darwin
import Foundation

/// Fichiers ouverts par les processus de l'utilisateur, via libproc (sans lancer lsof, 10 fois plus lent).
enum OpenFiles {
    /// Commandes de Claude Code vivantes : un processus tient encore ouvert
    /// `…/claude-<uid>/<dossier>/<cliSessionId>/tasks/<id>.output`.
    /// Renvoie cliSessionId → (identifiant de tâche → démarrage du plus ancien processus qui la tient).
    static func claudeLiveTasks() -> [String: [String: Date]] {
        var result: [String: [String: Date]] = [:]
        // Le shell qui enveloppe chaque commande tient le fichier tant qu'elle vit : inutile d'inspecter les autres processus.
        let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]
        for (path, started) in openVnodePaths(processNames: shells, where: { $0.contains("/tasks/") && $0.hasSuffix(".output") }) {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, parts[parts.count - 2] == "tasks",
                  parts.contains(where: { $0.hasPrefix("claude-") }) else { continue }
            let session = String(parts[parts.count - 3])
            let task = String(parts[parts.count - 1].dropLast(".output".count))
            result[session, default: [:]][task] = min(result[session]?[task] ?? .distantFuture, started)
        }
        return result
    }

    /// Chemins ouverts retenus par `keep`, avec la date de démarrage la plus ancienne des processus qui les tiennent.
    static func openVnodePaths(processNames: Set<String>? = nil, where keep: (String) -> Bool) -> [String: Date] {
        let uid = getuid()
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var found: [String: Date] = [:]
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var bsd = proc_bsdshortinfo()
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                  bsd.pbsi_uid == uid else { continue }
            if let processNames {
                let name = withUnsafeBytes(of: bsd.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                guard processNames.contains(name) else { continue }
            }
            var started: Date?
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                guard keep(path) else { continue }
                if started == nil {
                    var info = proc_bsdinfo()
                    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                        started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
                    }
                }
                let date = started ?? Date()
                found[path] = min(found[path] ?? date, date)
            }
        }
        return found
    }
}

/// Accès pour l'outil de diagnostic.
public enum OpenFilesProbe {
    public static func run() -> [String: [String: Date]] { OpenFiles.claudeLiveTasks() }
}

/// Index incrémental des commandes passées en arrière-plan, lu dans les transcriptions Claude Code.
/// Une commande au premier plan écrit aussi dans `tasks/<id>.output` : seules celles annoncées
/// « running in background » ou « moved to the background » sont retenues, avec leur description.
final class BackgroundCommandIndex: @unchecked Sendable {
    static let shared = BackgroundCommandIndex()

    private struct FileState { var offset: UInt64 = 0; var size: UInt64 = 0 }
    private var files: [String: FileState] = [:]
    private var toolUseOfTask: [String: String] = [:]
    private var descriptionOfToolUse: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private let lock = NSLock()

    private static let launch = try! NSRegularExpression(pattern: #"(?:running in background with ID|moved to the background \(ID): ([A-Za-z0-9]+)"#)

    /// Description de la commande, ou nil si ce n'est pas une commande d'arrière-plan connue.
    /// `transcripts` : du plus probable au moins probable ; le parcours s'arrête dès que la tâche est trouvée.
    func description(of task: String, in transcripts: [URL], now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let found = resolved(task) { return found }
        // Commande au premier plan probable : on ne recherche pas à chaque balayage.
        if let miss = misses[task], now.timeIntervalSince(miss) < 30 { return nil }
        for url in transcripts {
            index(url)
            if let found = resolved(task) { misses[task] = nil; return found }
        }
        misses[task] = now
        return nil
    }

    private func resolved(_ task: String) -> String? {
        guard let toolUse = toolUseOfTask[task] else { return nil }
        return descriptionOfToolUse[toolUse] ?? L10n.t("Commande en arrière-plan", "Background command")
    }

    /// Lit uniquement la partie ajoutée depuis la dernière lecture du fichier.
    private func index(_ url: URL) {
        guard let stat = FileStat(url) else { return }
        var state = files[url.path] ?? FileState()
        let size = UInt64(stat.size)
        if size < state.size { state = FileState() }  // fichier réécrit : on repart de zéro
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd() else { return }
        // Ne traiter que des lignes complètes ; la fin partielle sera relue la fois suivante.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        let launchNeedles = [Data("in background with ID".utf8), Data("moved to the background".utf8)]
        let toolUseNeedle = Data("\"type\":\"tool_use\"".utf8)
        let descriptionNeedle = Data("\"description\"".utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            let isLaunch = launchNeedles.contains { line.range(of: $0) != nil }
            let isToolUse = line.range(of: toolUseNeedle) != nil && line.range(of: descriptionNeedle) != nil
            guard isLaunch || isToolUse,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String,
                   let description = (block["input"] as? [String: Any])?["description"] as? String, !description.isEmpty {
                    descriptionOfToolUse[id] = description
                }
                if block["type"] as? String == "tool_result", let toolUse = block["tool_use_id"] as? String {
                    for text in Self.texts(block["content"]) {
                        let range = NSRange(text.startIndex..., in: text)
                        for match in Self.launch.matches(in: text, range: range) {
                            if let r = Range(match.range(at: 1), in: text) { toolUseOfTask[String(text[r])] = toolUse }
                        }
                    }
                }
            }
        }
        state.offset += UInt64(complete.count)
        state.size = size
        files[url.path] = state
    }

    private static func texts(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }
}
