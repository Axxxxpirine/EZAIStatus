import AppKit
import EZAIStatusCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    /// Liens reçus avant la fin du lancement : au lancement à froid par URL, `application(_:open:)` arrive
    /// avant `applicationDidFinishLaunching`, quand la barre des menus n'existe pas encore. `nil` ensuite.
    private var pendingLinks: [URL]? = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: MenuView(
            model: model,
            openSettings: { [weak self] in self?.showSettings() },
            close: { [weak self] in self?.popover.performClose(nil) }))

        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
        model.onSnapshotChange = { [weak self] in self?.updateStatusItem() }
        model.onLanguageChange = { [weak self] in
            self?.updateStatusItem()
            self?.settingsWindow?.title = L10n.t("Réglages d'EZAIStatus", "EZAIStatus Settings")
        }
        updateStatusItem()
        model.start()
        Updater.shared.start()
        // Après le premier balayage : `next` connaît alors les terminées, et l'icône de la barre des menus a sa place
        // pour y accrocher le panneau.
        let links = pendingLinks ?? []
        pendingLinks = nil
        if !links.isEmpty { model.afterFirstScan { [weak self] in self?.handle(links) } }
    }

    // MARK: Barre des menus

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let snapshot = model.snapshot
        let title = StatusSymbol.title(for: snapshot)
        if title.length == 0 {
            // Rien à suivre : une coche discrète, en image modèle pour suivre la couleur de la barre.
            let image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = true
            button.attributedTitle = NSAttributedString()
        } else {
            button.image = nil
            button.appearsDisabled = false
            button.attributedTitle = title
        }
        var label = L10n.t("Conversations : \(snapshot.count(.running)) en cours, \(snapshot.count(.waiting)) attendent ta réponse, \(snapshot.count(.finished)) terminées",
                           "Conversations: \(snapshot.count(.running)) running, \(snapshot.count(.waiting)) waiting for you, \(snapshot.count(.finished)) finished")
        if !snapshot.problems.isEmpty { label += L10n.t(". Source illisible : ", ". Unreadable source: ") + snapshot.problems.map(\.source.displayName).joined(separator: ", ") }
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        model.scheduleRefresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Liens ezaistatus:// (touche Stream Deck)

    func application(_ application: NSApplication, open urls: [URL]) {
        if pendingLinks != nil {
            pendingLinks?.append(contentsOf: urls)
        } else {
            handle(urls)
        }
    }

    private func handle(_ urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "ezaistatus" {
            switch url.host?.lowercased() {
            case "next":
                // Au lancement par le lien, le premier balayage n'est pas fini : le panneau s'ouvre.
                if !model.openNext() { showPanelFromLink() }
            case "panel":
                showPanelFromLink()
            default:
                break
            }
        }
    }

    private func showPanelFromLink() {
        NSApp.activate(ignoringOtherApps: true)
        showPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopExport()
    }

    // MARK: Réglages

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = L10n.t("Réglages d'EZAIStatus", "EZAIStatus Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["conversationID"] as? String else { return }
        await MainActor.run { model.open(conversationID: id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

MainActor.assumeIsolated {
    // Outil de développement : dessine le panneau réel dans un PNG, puis quitte.
    // Avec --demo : conversations fictives, rendu Retina, barre des menus et visuel de présentation en plus.
    if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), index + 1 < CommandLine.arguments.count {
        PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                               demo: CommandLine.arguments.contains("--demo"))
        exit(0)
    }
    LegacySettings.migrate()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

/// Jusqu'à la 0.1.1, l'app s'appelait `io.github.axxxxpirine.EZAIStatus` : au premier lancement sous le nouvel
/// identifiant, elle reprend les réglages enregistrés sous l'ancien (macOS les range par identifiant).
enum LegacySettings {
    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "legacySettingsMigrated") else { return }
        defaults.set(true, forKey: "legacySettingsMigrated")
        guard let old = defaults.persistentDomain(forName: "io.github.axxxxpirine.EZAIStatus") else { return }
        for key in [L10n.defaultsKey, "notifyFinished", "notifyWaiting"] where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
    }
}

/// Symboles SF de la barre des menus : mêmes formes et couleurs vives sur barre claire comme sombre.
enum StatusSymbol {
    static func name(_ state: ConversationState) -> String {
        switch state {
        case .running: "circle.dotted"
        case .waiting: "exclamationmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    static func color(_ state: ConversationState) -> NSColor {
        switch state {
        case .running: .systemBlue
        case .waiting: .systemOrange
        case .finished: .systemGreen
        }
    }

    /// Titre de l'élément de barre des menus : symbole et nombre pour chaque état non nul, triangle si une source est illisible.
    /// Vide quand il n'y a rien à suivre.
    static func title(for snapshot: Snapshot) -> NSMutableAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let title = NSMutableAttributedString()
        // Ordre de la maquette : en cours, attente, terminé. Seuls les états non nuls sont affichés.
        for state in [ConversationState.running, .waiting, .finished] where snapshot.count(state) > 0 {
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            title.append(attachment(name(state), color: color(state), font: font))
            title.append(NSAttributedString(string: " \(snapshot.count(state))",
                                            attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        if !snapshot.problems.isEmpty {
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            title.append(attachment("exclamationmark.triangle.fill", color: .systemYellow, font: font))
        }
        return title
    }

    /// Symbole en pièce jointe, centré sur la hauteur des chiffres. Les symboles pleins gardent leur glyphe en blanc.
    static func attachment(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        let palette: [NSColor] = name.hasSuffix(".fill") ? [.white, color] : [color]
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: name.hasSuffix(".fill") ? .semibold : .bold)
            .applying(.init(paletteColors: palette))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}
