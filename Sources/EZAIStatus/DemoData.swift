import EZAIStatusCore
import Foundation

/// Conversations fictives pour les captures publiques (README, réseaux) : aucune donnée réelle du Mac.
enum DemoData {
    static func snapshot(now: Date = Date()) -> Snapshot {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let link = URL(string: "https://example.com")
        return Snapshot(conversations: [
            TrackedConversation(id: "demo-1", source: .claudeCode,
                                title: L10n.t("Choisir la base de données",
                                              "Pick a database for the sync service"),
                                state: .waiting, date: ago(2), openURL: link, project: "atlas-api"),
            TrackedConversation(id: "demo-2", source: .codex,
                                title: L10n.t("Refondre les webhooks", "Refactor the payment webhooks"),
                                state: .running, date: ago(4), openURL: link, project: "shop-backend",
                                subagents: [
                                    TrackedSubagent(id: "demo-2a", title: L10n.t("Explorer · tests existants", "Explorer · existing tests"),
                                                    state: .finished),
                                    TrackedSubagent(id: "demo-2b", title: L10n.t("Worker · migration Stripe", "Worker · Stripe migration"),
                                                    state: .running),
                                ]),
            TrackedConversation(id: "demo-3", source: .claudeCode,
                                title: L10n.t("Corriger le test de connexion", "Fix the flaky login test"),
                                state: .running, date: ago(1), openURL: link, project: "mobile-app",
                                subagents: [
                                    TrackedSubagent(id: "demo-3a", title: "npm run test:e2e", state: .running,
                                                    kind: .command, startedAt: ago(14)),
                                ]),
            TrackedConversation(id: "demo-4", source: .codex,
                                title: L10n.t("Rédiger les notes de version 2.3", "Write the 2.3 release notes"),
                                state: .finished, date: ago(6), openURL: link, project: "docs-site"),
            TrackedConversation(id: "demo-5", source: .claudeCode,
                                title: L10n.t("Expliquer le bug de cache", "Explain the cache invalidation bug"),
                                state: .finished, date: ago(25), openURL: link, project: "atlas-api"),
        ], reports: SourceKind.allCases.map { SourceReport(source: $0, status: .ok) })
    }
}
