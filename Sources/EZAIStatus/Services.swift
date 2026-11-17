import AppKit
import CoreServices
import EZAIStatusCore
import ServiceManagement
import UserNotifications

/// Surveillance FSEvents, sans sondage. Ne réagit qu'aux fichiers utiles au suivi :
/// les apps IA écrivent beaucoup d'autres fichiers (journaux, caches) qu'il faut ignorer.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    static let relevantFragments = [
        "/.codex/sessions/", "/.codex/state_",
        "/claude-code-sessions/", "/.claude/projects/", "/EZAIStatus/claude-hooks/",
    ]

    init(paths: [URL], handler: @escaping () -> Void) {
        self.handler = handler
        let existing = paths.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        // ~/.claude/projects contient les transcriptions : surveillé en plus des dossiers des connecteurs.
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
        let watched = Array(Set(existing + [projects])).filter { FileManager.default.fileExists(atPath: $0) }
        guard !watched.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: FileWatcher.isRelevant) { watcher.handler() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    static func isRelevant(_ path: String) -> Bool {
        relevantFragments.contains { path.contains($0) }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Notifications macOS, uniquement si l'utilisateur les a activées dans les réglages.
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(_ conversation: TrackedConversation) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.state == .waiting ? L10n.t("Attend ta réponse", "Waiting for you") : L10n.t("Réponse terminée", "Response finished")
        content.subtitle = conversation.source.displayName
        content.body = conversation.title
        content.userInfo = ["conversationID": conversation.id]
        content.threadIdentifier = conversation.id
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Lancement à l'ouverture de session, désactivé par défaut.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
