import AppKit
import EZAIStatusCore
import SwiftUI

/// Rendu hors écran du panneau avec les données réelles, pour vérifier l'interface sans cliquer.
@MainActor
enum PreviewRenderer {
    static func render(to url: URL) {
        let model = AppModel()
        model.refresh()
        // Le balayage est asynchrone : on laisse tourner la boucle principale le temps qu'il finisse.
        let deadline = Date().addingTimeInterval(5)
        while model.lastScan == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Rendu AppKit (NSHostingView) : plus fidèle au popover réel qu'ImageRenderer, boutons natifs compris.
        for dark in [false, true] {
            let view = NSHostingView(rootView: MenuView(model: model, openSettings: {}, close: {}, scrollable: false)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let target = dark ? url.deletingPathExtension().appendingPathExtension("dark.png") : url
            try? png.write(to: target)
            print(target.path)
        }
        // Réglages, en clair seulement.
        let settings = NSHostingView(rootView: SettingsView(model: model))
        settings.appearance = NSAppearance(named: .aqua)
        settings.frame = NSRect(origin: .zero, size: settings.fittingSize)
        settings.layoutSubtreeIfNeeded()
        if let rep = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
            settings.cacheDisplay(in: settings.bounds, to: rep)
            let target = url.deletingPathExtension().appendingPathExtension("settings.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: target)
            print(target.path)
        }
    }
}
