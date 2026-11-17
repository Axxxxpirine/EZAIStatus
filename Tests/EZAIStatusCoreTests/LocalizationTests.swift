import Testing
@testable import EZAIStatusCore

@Suite("Langue")
struct LocalizationTests {
    @Test func explicitChoiceWins() {
        #expect(L10n.resolveFrench(.french, preferredLanguages: ["en-US"]))
        #expect(!L10n.resolveFrench(.english, preferredLanguages: ["fr-CH"]))
    }

    @Test func systemFollowsFirstPreferredLanguage() {
        #expect(L10n.resolveFrench(.system, preferredLanguages: ["fr-CH", "en-US"]))
        #expect(!L10n.resolveFrench(.system, preferredLanguages: ["de-CH", "fr-CH"]))
        #expect(!L10n.resolveFrench(.system, preferredLanguages: []))
    }
}
