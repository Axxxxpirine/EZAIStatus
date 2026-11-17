import EZAIStatusCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var hookInstalled = ClaudeHooks.isInstalled(home: FileManager.default.homeDirectoryForCurrentUser)
    @State private var message: String?
    @State private var autoUpdate = Updater.shared.automaticallyChecks

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        Form {
            Section(L10n.t("Langue", "Language")) {
                Picker(L10n.t("Langue de l'interface", "Interface language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section("Notifications") {
                Toggle(L10n.t("Quand une réponse est terminée", "When a response is finished"), isOn: notificationBinding(\.notifyFinished))
                Toggle(L10n.t("Quand une conversation attend ta réponse", "When a conversation is waiting for you"), isOn: notificationBinding(\.notifyWaiting))
            }

            Section(L10n.t("Démarrage", "Startup")) {
                Toggle(L10n.t("Lancer à l'ouverture de session", "Launch at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LoginItem.set(newValue)
                            launchAtLogin = LoginItem.isEnabled
                        } catch {
                            message = L10n.t("Lancement automatique impossible : ", "Could not enable launch at login: ") + error.localizedDescription
                        }
                    }))
            }

            Section {
                if Updater.shared.isConfigured {
                    Toggle(L10n.t("Rechercher automatiquement les mises à jour", "Check for updates automatically"), isOn: Binding(
                        get: { autoUpdate },
                        set: { Updater.shared.automaticallyChecks = $0; autoUpdate = Updater.shared.automaticallyChecks }))
                    HStack {
                        Text("EZAIStatus \(Updater.version)").foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.t("Rechercher maintenant…", "Check Now…")) { Updater.shared.checkForUpdates() }
                    }
                } else {
                    Text("EZAIStatus \(Updater.version)").foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.t("Mises à jour", "Updates"))
            }

            Section {
                Toggle(L10n.t("Détecter les demandes d'autorisation", "Detect permission requests"), isOn: Binding(
                    get: { hookInstalled },
                    set: { newValue in
                        do {
                            if newValue { try ClaudeHooks.install(home: home) } else { try ClaudeHooks.uninstall(home: home) }
                            hookInstalled = ClaudeHooks.isInstalled(home: home)
                            model.refresh()
                        } catch {
                            message = L10n.t("Modification du hook impossible : ", "Could not change the hook: ") + error.localizedDescription
                        }
                    }))
            } header: {
                Text("Claude Code")
            } footer: {
                Text(L10n.t("Ajoute un hook officiel dans ~/.claude/settings.json (copie de sécurité faite avant). Il note localement les événements de Claude Code, sans réseau. Les nouvelles sessions en tiennent compte.",
                            "Adds an official hook to ~/.claude/settings.json (a backup is made first). It records Claude Code events locally, with no network access. New sessions pick it up."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sources") {
                ForEach(model.snapshot.reports) { report in
                    SourceStatusRow(report: report)
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .id(model.language) // reconstruit les réglages au changement de langue
        .frame(width: 460)
        .frame(minHeight: 520)
    }

    private func notificationBinding(_ keyPath: ReferenceWritableKeyPath<AppModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { newValue in
                guard newValue else { model[keyPath: keyPath] = false; return }
                Task { @MainActor in
                    if await Notifier.requestAuthorization() {
                        model[keyPath: keyPath] = true
                        message = nil
                    } else {
                        message = L10n.t("Notifications refusées : autorise EZAIStatus dans Réglages Système › Notifications.",
                                         "Notifications denied: allow EZAIStatus in System Settings › Notifications.")
                    }
                }
            })
    }
}

private struct SourceStatusRow: View {
    let report: SourceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SourceBadge(source: report.source)
                Text(report.source.displayName)
                Spacer()
                Text(statusText).foregroundStyle(statusColor).font(.callout)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch report.status {
        case .ok: L10n.t("Suivi", "Tracked")
        case .notInstalled: L10n.t("App absente", "Not installed")
        case .unsupported: L10n.t("Non pris en charge", "Not supported")
        case .unreadable: L10n.t("Illisible", "Unreadable")
        }
    }

    private var statusColor: Color {
        switch report.status {
        case .ok: .green
        case .notInstalled: .secondary
        case .unsupported: .orange
        case .unreadable: .red
        }
    }

    private var detail: String? {
        switch report.status {
        case .unsupported(let reason), .unreadable(let reason): reason
        default: report.note
        }
    }
}
