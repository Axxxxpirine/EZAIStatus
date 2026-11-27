import AppKit
import EZAIStatusCore
import Observation

/// État partagé de l'app : instantané courant, réglages, rafraîchissement sur événements fichiers.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = Snapshot()
    private(set) var lastScan: Date?

    var notifyFinished: Bool {
        didSet { UserDefaults.standard.set(notifyFinished, forKey: Keys.notifyFinished) }
    }
    var notifyWaiting: Bool {
        didSet { UserDefaults.standard.set(notifyWaiting, forKey: Keys.notifyWaiting) }
    }

    /// Langue de l'interface ; changée à chaud, les textes du cœur suivent au balayage suivant.
    var language: AppLanguage = L10n.preference {
        didSet {
            guard language != oldValue else { return }
            L10n.preference = language
            onLanguageChange?()
            refresh()
        }
    }

    @ObservationIgnored var onSnapshotChange: (() -> Void)?
    @ObservationIgnored var onLanguageChange: (() -> Void)?
    @ObservationIgnored private let tracker: Tracker
    @ObservationIgnored private let home = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "dev.xprn.ezaistatus.scan", qos: .utility)
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanAfterCurrent = false
    @ObservationIgnored private var fallbackTimer: Timer?
    /// Actions en attente du premier balayage (liens reçus au lancement), `nil` une fois ce balayage fait.
    @ObservationIgnored private var afterFirstScan: [() -> Void]? = []

    private enum Keys {
        static let notifyFinished = "notifyFinished"
        static let notifyWaiting = "notifyWaiting"
    }

    init() {
        tracker = Tracker(storeURL: Tracker.defaultStoreURL())
        // Notifications désactivées par défaut, conformément au brief.
        notifyFinished = UserDefaults.standard.bool(forKey: Keys.notifyFinished)
        notifyWaiting = UserDefaults.standard.bool(forKey: Keys.notifyWaiting)
    }

    func start() {
        ClaudeHooks.refreshScriptIfInstalled(home: home)
        let paths = Connectors.all.flatMap { $0.watchPaths(home: home) }
        watcher = FileWatcher(paths: paths) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
        // Filet de sécurité peu coûteux si un événement fichier est manqué.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        fallbackTimer?.tolerance = 15
        refresh()
    }

    /// Regroupe les rafales d'événements en un seul balayage.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        guard !scanning else { rescanAfterCurrent = true; return }
        scanning = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let home = self.home
        scanQueue.async { [weak self] in
            let context = ScanContext(home: home, runningBundleIDs: running)
            let results = Connectors.scanAll(context)
            ClaudeHooks.compactIfNeeded(home: home)
            DispatchQueue.main.async {
                guard let self else { return }
                let (snapshot, transitions) = self.tracker.update(results)
                self.apply(snapshot)
                self.exportStatus()
                self.notify(transitions)
                self.lastScan = Date()
                self.scanning = false
                if let pending = self.afterFirstScan {
                    self.afterFirstScan = nil
                    pending.forEach { $0() }
                }
                if self.rescanAfterCurrent {
                    self.rescanAfterCurrent = false
                    self.scheduleRefresh()
                }
            }
        }
    }

    /// Captures publiques : affiche des données fictives à la place du balayage.
    func showDemo(_ snapshot: Snapshot) {
        apply(snapshot)
        lastScan = Date()
    }

    private func apply(_ snapshot: Snapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        onSnapshotChange?()
    }

    private func notify(_ transitions: [Transition]) {
        for transition in transitions {
            switch transition.conversation.state {
            case .finished where notifyFinished, .waiting where notifyWaiting:
                Notifier.post(transition.conversation)
            default:
                break
            }
        }
    }

    /// Ouvre la conversation dans son app. Une fin n'est acquittée que si le lien direct a été accepté.
    func open(_ conversation: TrackedConversation) {
        if let url = conversation.openURL, NSWorkspace.shared.open(url) {
            apply(tracker.acknowledge(conversation))
            // La touche Stream Deck doit perdre cette terminée tout de suite, sans attendre le balayage suivant.
            exportStatus()
            return
        }
        openApp(conversation.source)
    }

    func open(conversationID: String) {
        if let conversation = snapshot.conversations.first(where: { $0.id == conversationID }) { open(conversation) }
    }

    /// Exécute `action` tout de suite si le premier balayage est fait, sinon juste après lui.
    func afterFirstScan(_ action: @escaping () -> Void) {
        if afterFirstScan != nil { afterFirstScan?.append(action) } else { action() }
    }

    /// Touche Stream Deck : ouvre la plus ancienne conversation terminée. `false` s'il n'y en a pas.
    func openNext() -> Bool {
        guard let conversation = snapshot.oldestFinished else { return false }
        open(conversation)
        return true
    }

    /// Réécrit l'état résumé à chaque balayage, même inchangé : sa date prouve que l'app tourne.
    private func exportStatus() {
        try? StatusExport(snapshot: snapshot, now: Date()).write(to: StatusExport.fileURL(home: home))
    }

    /// À la fermeture : sans fichier, la touche passe tout de suite « hors ligne ».
    func stopExport() {
        StatusExport.remove(at: StatusExport.fileURL(home: home))
    }

    private func openApp(_ source: SourceKind) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
