import AppKit
import EZAIStatusCore

/// Icônes des apps IA, lues sur ce Mac au moment de l'affichage : rien n'est copié dans EZAIStatus.
/// Si l'app est absente, l'appelant garde le badge texte.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(for source: SourceKind, dark: Bool) -> NSImage? {
        let key = "\(source.bundleIdentifier)|\(source == .codex ? (dark ? "dark" : "light") : "")"
        if let image = cache[key] { return image }
        if missing.contains(key) { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else {
            missing.insert(key)
            return nil
        }
        var image: NSImage?
        if source == .codex {
            // L'app ChatGPT contient une icône propre à Codex, en version claire et sombre.
            let name = dark ? "icon-codex-dark-color.png" : "icon-codex-light.png"
            image = NSImage(contentsOf: appURL.appendingPathComponent("Contents/Resources/\(name)"))
        }
        image = image ?? NSWorkspace.shared.icon(forFile: appURL.path)
        if let image { cache[key] = image } else { missing.insert(key) }
        return image
    }
}
