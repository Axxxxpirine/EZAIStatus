import AppKit
import EZAIStatusCore

// Outil de diagnostic : affiche ce que chaque connecteur voit sur ce Mac, sans rien modifier.
// `--all` montre aussi les conversations inactives ou déjà consultées.
let showAll = CommandLine.arguments.contains("--all")
let home = FileManager.default.homeDirectoryForCurrentUser
// Même code que l'interrupteur des réglages de l'app.
if CommandLine.arguments.contains("--install-hook") { try ClaudeHooks.install(home: home); print("Hook installé"); exit(0) }
if CommandLine.arguments.contains("--uninstall-hook") { try ClaudeHooks.uninstall(home: home); print("Hook retiré"); exit(0) }
let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
let context = ScanContext(runningBundleIDs: running)
let start = Date()
let results = Connectors.scanAll(context)
let elapsed = Date().timeIntervalSince(start)

let formatter = DateFormatter()
formatter.dateFormat = "dd.MM HH:mm"

for result in results {
    let status: String
    switch result.status {
    case .ok: status = "ok"
    case .notInstalled: status = "absente"
    case .unsupported(let reason): status = "non prise en charge — \(reason)"
    case .unreadable(let reason): status = "ILLISIBLE — \(reason)"
    }
    print("== \(result.source.displayName) : \(status) (\(result.observations.count) conversations récentes)")
    for observation in result.observations {
        let label: String
        switch observation.activity {
        case .running: label = "EN COURS"
        case .waiting(let since): label = "ATTEND depuis \(formatter.string(from: since))"
        case .finished(let at, let unread): label = "fini \(formatter.string(from: at))\(unread ? " NON LU" : "")"
        case .idle: label = "inactif"
        }
        if showAll || label != "inactif" && !label.hasPrefix("fini") || label.hasSuffix("NON LU") {
            let project = observation.project.map { "  — \($0)" } ?? ""
            print("   [\(observation.source.badge)] \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(observation.title)\(project)")
            for subagent in observation.subagents {
                let state: String
                switch subagent.activity {
                case .running: state = "en cours"
                case .waiting: state = "attend"
                case .finished(let at, _): state = "fini \(formatter.string(from: at))"
                case .idle: state = "inactif"
                }
                let kind = subagent.kind == .command ? "commande" : "agent"
                let age = subagent.startedAt.map { String(format: " (depuis %.1f h)", Date().timeIntervalSince($0) / 3600) } ?? ""
                print("        ↳ \(kind) \(state.padding(toLength: 16, withPad: " ", startingAt: 0)) \(subagent.title)\(age)")
            }
        }
    }
}
print(String(format: "Balayage complet : %.0f ms", elapsed * 1000))
for connector in Connectors.all {
    for _ in 0..<5 { _ = connector.scan(context) }
    let t0 = Date(); for _ in 0..<(ProcessInfo.processInfo.environment["LOOPS"].flatMap(Int.init) ?? 20) { _ = connector.scan(context) }  // moyenne à caches chauds
    print(String(format: "  %@ : %.0f ms", String(describing: type(of: connector)), Date().timeIntervalSince(t0) * 1000 / 20))
}
if CommandLine.arguments.contains("--tasks") {
    let t0 = Date()
    let tasks = OpenFilesProbe.run()
    print(String(format: "Tâches vivantes (%.0f ms) : %@", Date().timeIntervalSince(t0) * 1000, tasks.description))
}
