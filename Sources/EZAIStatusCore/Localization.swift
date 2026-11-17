import Foundation

/// Langue de l'interface, choisie dans les réglages. « Système » suit la première langue préférée de macOS
/// (français si elle est française, anglais sinon).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, french, english

    public var id: String { rawValue }

    /// Nom affiché dans le sélecteur, chaque langue dans sa propre langue.
    public var displayName: String {
        switch self {
        case .system: L10n.t("Langue du système", "System language")
        case .french: "Français"
        case .english: "English"
        }
    }
}

/// Traductions français / anglais écrites à côté de leur usage : L10n.t("Réglages…", "Settings…").
/// Volontairement sans catalogue, pour changer de langue à chaud sans relancer l'app.
public enum L10n {
    public static let defaultsKey = "language"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedIsFrench: Bool?

    /// Langue enregistrée dans les préférences.
    public static var preference: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            lock.withLock { cachedIsFrench = nil }
        }
    }

    public static var isFrench: Bool {
        if let cached = lock.withLock({ cachedIsFrench }) { return cached }
        let value = resolveFrench(preference, preferredLanguages: Locale.preferredLanguages)
        lock.withLock { cachedIsFrench = value }
        return value
    }

    static func resolveFrench(_ language: AppLanguage, preferredLanguages: [String]) -> Bool {
        switch language {
        case .french: true
        case .english: false
        case .system: preferredLanguages.first?.lowercased().hasPrefix("fr") ?? false
        }
    }

    public static func t(_ french: String, _ english: String) -> String {
        isFrench ? french : english
    }
}
