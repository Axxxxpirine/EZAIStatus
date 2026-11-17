import EZAIStatusCore
import SwiftUI

enum Palette {
    static let running = Color(red: 0.22, green: 0.47, blue: 0.74)
    static let waiting = Color(red: 0.65, green: 0.42, blue: 0.08)
    static let finished = Color(red: 0.21, green: 0.51, blue: 0.37)

    static func color(_ state: ConversationState) -> Color {
        switch state {
        case .running: running
        case .waiting: waiting
        case .finished: finished
        }
    }
}

/// Panneau ouvert depuis la barre des menus : conversations groupées par état, attente en premier.
struct MenuView: View {
    let model: AppModel
    var openSettings: () -> Void
    var close: () -> Void
    /// Faux uniquement pour le rendu hors écran, qui ne dessine pas le contenu d'une ScrollView.
    var scrollable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Conversations").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L10n.t("Sur ce Mac", "On this Mac")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 10)

            let snapshot = model.snapshot
            if scrollable {
                // Défile au-delà d'une hauteur raisonnable (beaucoup de sous-agents, par exemple).
                ScrollView { groups(snapshot) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 560)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                groups(snapshot)
            }
            if snapshot.conversations.isEmpty {
                Divider().opacity(0.5)
                Text(snapshot.problems.isEmpty ? L10n.t("Tout a été consulté.", "All caught up.")
                                                : L10n.t("Rien à afficher pour les sources lisibles.", "Nothing to show from readable sources."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
            }
            if !snapshot.problems.isEmpty {
                ProblemList(reports: snapshot.problems)
            }

            Divider().opacity(0.5).padding(.top, 4)
            HStack {
                Button(L10n.t("Réglages…", "Settings…"), action: openSettings)
                Spacer()
                Button(L10n.t("Quitter", "Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, 8)
        }
        .padding(.top, 14)
        .id(model.language) // reconstruit le panneau au changement de langue
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(width: 360)
    }

    private func groups(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ConversationState.allCases, id: \.self) { state in
                let items = snapshot.conversations(in: state)
                if !items.isEmpty {
                    ConversationGroup(state: state, items: items) { conversation in
                        close()
                        model.open(conversation)
                    }
                }
            }
        }
    }
}

private struct ConversationGroup: View {
    let state: ConversationState
    let items: [TrackedConversation]
    let open: (TrackedConversation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            HStack {
                Text(state.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.color(state))
                Spacer()
                Text("\(items.count)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(items) { conversation in
                ConversationRow(conversation: conversation) { open(conversation) }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct ConversationRow: View {
    let conversation: TrackedConversation
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    SourceBadge(source: conversation.source)
                    Text(conversation.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let project = conversation.project {
                        Text(project)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 96, alignment: .trailing)
                            .fixedSize(horizontal: project.count < 14, vertical: false)
                    }
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                }
                if !conversation.subagents.isEmpty {
                    SubagentList(subagents: conversation.subagents)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(conversation.openURL == nil
              ? L10n.t("Ouvre \(conversation.source.displayName) (lien direct indisponible)",
                       "Opens \(conversation.source.displayName) (no direct link)")
              : L10n.t("Ouvre la conversation dans \(conversation.source.displayName)",
                       "Opens the conversation in \(conversation.source.displayName)"))
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(conversation.source.displayName), \(conversation.title), \(conversation.state.title)"
        if let project = conversation.project { text += L10n.t(", projet \(project)", ", project \(project)") }
        if !conversation.subagents.isEmpty { text += L10n.t(", \(conversation.subagents.count) sous-agents", ", \(conversation.subagents.count) subagents") }
        return text
    }
}

/// Sous-agents en retrait sous leur conversation : état en couleur et mission, sans compteur propre.
private struct SubagentList: View {
    let subagents: [TrackedSubagent]
    private let limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(subagents.prefix(limit)) { subagent in
                HStack(spacing: 6) {
                    Image(systemName: subagent.kind == .command ? "terminal" : Self.symbol(subagent.state))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Palette.color(subagent.state))
                        .frame(width: 12)
                    Text(subagent.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let age = Self.age(subagent.startedAt) {
                        Text(age)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                .help(subagent.kind == .command ? L10n.t("Commande en arrière-plan", "Background command") : L10n.t("Sous-agent", "Subagent"))
            }
            if subagents.count > limit {
                Text(L10n.t("+ \(subagents.count - limit) autres sous-agents", "+ \(subagents.count - limit) more subagents"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }
        }
        .padding(.leading, 30)
    }

    /// Ancienneté d'une commande, seulement au-delà de 10 minutes (« depuis 26 h »).
    static func age(_ started: Date?, now: Date = Date()) -> String? {
        guard let started else { return nil }
        let minutes = Int(now.timeIntervalSince(started) / 60)
        guard minutes >= 10 else { return nil }
        if minutes < 60 { return L10n.t("depuis \(minutes) min", "for \(minutes) min") }
        let hours = minutes / 60
        return hours < 48 ? L10n.t("depuis \(hours) h", "for \(hours) h") : L10n.t("depuis \(hours / 24) j", "for \(hours / 24) d")
    }

    static func symbol(_ state: ConversationState) -> String {
        switch state {
        case .running: "circle.dashed"
        case .waiting: "exclamationmark.circle.fill"
        case .finished: "checkmark"
        }
    }
}

struct SourceBadge: View {
    let source: SourceKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let icon = AppIcons.image(for: source, dark: colorScheme == .dark) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .help(source.displayName)
                .accessibilityLabel(source.displayName)
        } else {
            textBadge
        }
    }

    /// Repli quand l'app n'est pas installée sur ce Mac.
    private var textBadge: some View {
        let (foreground, background): (Color, Color) = switch source {
        case .codex: (Color.primary, Color.primary.opacity(0.06))
        case .claudeCode: (Color(red: 0.66, green: 0.37, blue: 0.25), Color(red: 0.95, green: 0.91, blue: 0.87))
        }
        return Text(source.badge)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 21, height: 21)
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.09)))
            .help(source.displayName)
    }
}

private struct ProblemList: View {
    let reports: [SourceReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.5)
            ForEach(reports) { report in
                if case .unreadable(let reason) = report.status {
                    Label {
                        Text(L10n.t("\(report.source.displayName) illisible : \(reason)", "\(report.source.displayName) unreadable: \(reason)")).font(.system(size: 11))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 9)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
