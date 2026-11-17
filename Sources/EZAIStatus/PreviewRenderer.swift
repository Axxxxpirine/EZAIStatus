import AppKit
import EZAIStatusCore
import SwiftUI

/// Rendu hors écran du panneau, pour vérifier l'interface sans cliquer.
/// Données réelles par défaut ; en mode démo, conversations fictives et images Retina pour le README et les réseaux.
@MainActor
enum PreviewRenderer {
    static func render(to url: URL, demo: Bool = false) {
        let model = AppModel()
        if demo {
            model.showDemo(DemoData.snapshot())
        } else {
            model.refresh()
            // Le balayage est asynchrone : on laisse tourner la boucle principale le temps qu'il finisse.
            let deadline = Date().addingTimeInterval(5)
            while model.lastScan == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        let scale: CGFloat = demo ? 2 : 1
        var heroPanels: [Bool: NSBitmapImageRep] = [:]

        // Rendu AppKit (NSHostingView) : plus fidèle au popover réel qu'ImageRenderer, boutons natifs compris.
        for dark in [false, true] {
            let view = NSHostingView(rootView: MenuView(model: model, openSettings: {}, close: {}, scrollable: false)
                .background(Color(nsColor: .windowBackgroundColor)))
            guard let rep = snapshot(of: view, dark: dark, scale: scale) else { continue }
            // Le visuel de présentation agrandit le panneau : rendu plus fin pour rester net.
            if demo { heroPanels[dark] = snapshot(of: view, dark: dark, scale: heroScale) }
            write(rep, to: dark ? sibling(url, "dark") : url)
        }
        // Réglages, en clair seulement.
        if let rep = snapshot(of: NSHostingView(rootView: SettingsView(model: model)), dark: false, scale: scale) {
            write(rep, to: sibling(url, "settings"))
        }
        guard demo else { return }
        let title = StatusSymbol.title(for: model.snapshot)
        for dark in [false, true] {
            if let rep = menuBar(title, dark: dark) { write(rep, to: sibling(url, dark ? "menubar.dark" : "menubar")) }
            if let panel = heroPanels[dark], let rep = hero(title: title, panel: panel, dark: dark) {
                write(rep, to: sibling(url, dark ? "hero.dark" : "hero"))
            }
        }
    }

    // MARK: Rendu

    private static func snapshot(of view: NSView, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = bitmap(view.bounds.size, scale: scale) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func bitmap(_ size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    /// Dessine dans une image Retina avec l'apparence voulue (couleurs système résolues en clair ou en sombre).
    private static func draw(_ size: NSSize, scale: CGFloat = 2, dark: Bool, _ body: () -> Void) -> NSBitmapImageRep? {
        guard let rep = bitmap(size, scale: scale), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance(body)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func sibling(_ url: URL, _ suffix: String) -> URL {
        url.deletingPathExtension().appendingPathExtension("\(suffix).png")
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print(url.path)
    }

    // MARK: Visuels de présentation

    /// Morceau de barre des menus : l'élément d'EZAIStatus suivi de quelques icônes système génériques.
    private static func menuBar(_ title: NSAttributedString, dark: Bool) -> NSBitmapImageRep? {
        let extras = systemExtras()
        let size = NSSize(width: ceil(title.size().width) + extras.width + 48, height: 30)
        return draw(size, dark: dark) {
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let titleSize = title.size()
            title.draw(at: NSPoint(x: 16, y: (size.height - titleSize.height) / 2))
            extras.draw(NSPoint(x: 16 + ceil(titleSize.width) + 20, y: size.height / 2))
        }
    }

    /// Le visuel fait 860 × 484 points, rendus à 2400 × 1350 pixels : tout y paraît agrandi d'environ 40 %.
    private static let heroScale: CGFloat = 2400 / 860

    /// Visuel 16:9 : fond dégradé, barre des menus, panneau ouvert et accroche.
    private static func hero(title: NSAttributedString, panel: NSBitmapImageRep, dark: Bool) -> NSBitmapImageRep? {
        let size = NSSize(width: 860, height: 484)
        let barHeight: CGFloat = 26
        return draw(size, scale: heroScale, dark: dark) {
            let colors: [NSColor] = dark
                ? [NSColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1), NSColor(red: 0.20, green: 0.15, blue: 0.32, alpha: 1)]
                : [NSColor(red: 0.86, green: 0.90, blue: 0.98, alpha: 1), NSColor(red: 0.95, green: 0.89, blue: 0.95, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: NSRect(origin: .zero, size: size), angle: -35)

            // Barre des menus translucide.
            (dark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 1, alpha: 0.55)).setFill()
            NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()
            let extras = systemExtras()
            let extrasX = size.width - 14 - extras.width
            extras.draw(NSPoint(x: extrasX, y: size.height - barHeight / 2))
            let titleSize = title.size()
            let titleX = extrasX - 18 - titleSize.width
            title.draw(at: NSPoint(x: titleX, y: size.height - barHeight + (barHeight - titleSize.height) / 2))

            // Panneau sous l'élément, aligné à droite comme un popover.
            let panelSize = panel.size
            let panelRect = NSRect(x: min(titleX + titleSize.width / 2 - panelSize.width / 2, size.width - 14 - panelSize.width),
                                   y: size.height - barHeight - 8 - panelSize.height,
                                   width: panelSize.width, height: panelSize.height)
            let shape = NSBezierPath(roundedRect: panelRect, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.55 : 0.22)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            panel.draw(in: panelRect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: dark ? 1 : 0, alpha: 0.12).setStroke()
            shape.lineWidth = 1
            shape.stroke()

            // Accroche à gauche.
            let ink = dark ? NSColor.white : NSColor(white: 0.1, alpha: 1)
            let name = NSAttributedString(string: "EZAIStatus", attributes: [
                .font: NSFont.systemFont(ofSize: 46, weight: .bold), .foregroundColor: ink])
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            let tagline = NSAttributedString(
                string: L10n.t("Tes conversations Codex et Claude Code,\nd'un coup d'œil dans la barre des menus.",
                               "Your Codex and Claude Code conversations,\nat a glance in the menu bar."),
                attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .regular),
                             .foregroundColor: ink.withAlphaComponent(0.8), .paragraphStyle: paragraph])
            let legend = legendLine(ink: ink.withAlphaComponent(0.75), size: 13)
            let left: CGFloat = 44
            let textWidth = panelRect.minX - left - 24
            let taglineHeight = tagline.boundingRect(with: NSSize(width: textWidth, height: 400),
                                                     options: [.usesLineFragmentOrigin]).height
            let nameHeight = name.size().height
            let blockHeight = nameHeight + 12 + taglineHeight + 26 + legend.size().height
            var y = (size.height - barHeight) / 2 + blockHeight / 2
            y -= nameHeight
            name.draw(at: NSPoint(x: left, y: y))
            y -= 12 + taglineHeight
            tagline.draw(with: NSRect(x: left, y: y, width: textWidth, height: taglineHeight), options: [.usesLineFragmentOrigin])
            y -= 26 + legend.size().height
            legend.draw(at: NSPoint(x: left, y: y))
        }
    }

    /// Légende des trois symboles, avec les mêmes formes que la barre.
    private static func legendLine(ink: NSColor, size: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let line = NSMutableAttributedString()
        for state in [ConversationState.running, .waiting, .finished] {
            if line.length > 0 { line.append(NSAttributedString(string: "    ", attributes: [.font: font])) }
            line.append(StatusSymbol.attachment(StatusSymbol.name(state), color: StatusSymbol.color(state), font: font))
            line.append(NSAttributedString(string: " " + state.title, attributes: [.font: font, .foregroundColor: ink]))
        }
        return line
    }

    /// Wi-Fi, batterie et heure fictive, pour situer l'élément dans une vraie barre.
    private static func systemExtras() -> (width: CGFloat, draw: (NSPoint) -> Void) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let images = ["wifi", "battery.75percent"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        let clock = NSAttributedString(string: "9:41", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let gap: CGFloat = 16
        let width = images.reduce(0) { $0 + $1.size.width + gap } + clock.size().width
        return (width, { origin in
            var x = origin.x
            for image in images {
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.labelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x, y: origin.y - image.size.height / 2, width: image.size.width, height: image.size.height))
                x += image.size.width + gap
            }
            clock.draw(at: NSPoint(x: x, y: origin.y - clock.size().height / 2))
        })
    }
}
