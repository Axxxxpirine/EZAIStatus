// Génère Resources/AppIcon.icns : la pastille de la barre des menus avec les trois états
// (en cours en bleu, attente en ambre, terminé en vert), couleurs de la maquette validée.
// Usage : swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Fond : carré arrondi macOS (marge de la grille Apple : 100 px sur 1024).
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x21312F, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    color(0x496866).setFill()
    tilePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [color(0x93A8A0), color(0x496866), color(0x2F4A44)])!.draw(in: tilePath, angle: -60)

    // Pastille claire comme le déclencheur de la barre des menus.
    let pill = NSRect(x: 172 * s, y: 392 * s, width: 680 * s, height: 240 * s)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: 120 * s, yRadius: 120 * s)
    color(0xF9FAF7, 0.96).setFill()
    pillPath.fill()

    // Trois pastilles d'état.
    let states: [(UInt32, String)] = [(0x3878BC, "◌"), (0xA76B14, "!"), (0x36815E, "✓")]
    for (index, state) in states.enumerated() {
        let center = CGPoint(x: (302 + CGFloat(index) * 210) * s, y: 512 * s)
        let radius = 78 * s
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        color(state.0).setFill()
        dot.fill()
        // Les glyphes ne se lisent qu'à partir de 64 px : en dessous, des points de couleur suffisent.
        if size >= 64, index == 0 {
            // Anneau pointillé dessiné : le glyphe ◌ de la police système est trop fin à cette taille.
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 40 * s, y: center.y - 40 * s, width: 80 * s, height: 80 * s))
            ring.lineWidth = 15 * s
            ring.lineCapStyle = .round
            ring.setLineDash([16 * s, 17.5 * s], count: 2, phase: 0)
            NSColor.white.setStroke()
            ring.stroke()
        } else if size >= 64 {
            let font = NSFont.systemFont(ofSize: 104 * s, weight: .heavy)
            let text = NSAttributedString(string: state.1, attributes: [.font: font, .foregroundColor: NSColor.white])
            let bounds = text.size()
            text.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2 + 2 * s))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: pixels).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "OK : Resources/AppIcon.icns" : "Échec iconutil")
