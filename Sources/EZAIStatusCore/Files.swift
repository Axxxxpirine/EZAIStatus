import Foundation
import SQLite3

/// Lecture de la fin d'un fichier JSONL sans charger tout le fichier.
enum JSONLTail {
    /// Renvoie les objets des dernières lignes complètes, du plus ancien au plus récent.
    /// `maxBytes` borne la lecture ; on agrandit la fenêtre seulement si `isEnough` n'est pas satisfait.
    /// `markers` : seules les lignes contenant l'un de ces fragments sont décodées (recherche d'octets, bien
    /// moins coûteuse que le JSON). `keepLast` : nombre maximal de lignes décodées, en partant de la fin.
    static func objects(at url: URL,
                        initialBytes: Int = 256 * 1024,
                        maxBytes: Int = 8 * 1024 * 1024,
                        markers: [String] = [],
                        keepLast: Int? = nil,
                        isEnough: ([[String: Any]]) -> Bool) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let needles = markers.map { Data($0.utf8) }
        var window = UInt64(initialBytes)
        while true {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd() else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            // La première ligne est probablement tronquée si on n'a pas lu depuis le début.
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            var objects: [[String: Any]] = []
            for line in lines.reversed() {
                if let keepLast, objects.count >= keepLast { break }
                if !needles.isEmpty, !needles.contains(where: { line.range(of: $0) != nil }) { continue }
                if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                    objects.append(object)
                }
            }
            objects.reverse()
            if start == 0 || isEnough(objects) || window >= UInt64(maxBytes) { return objects }
            window *= 4
        }
    }
}

/// Accès SQLite en lecture seule, sans jamais écrire dans la base d'une autre app.
final class ReadOnlyDatabase {
    private var db: OpaquePointer?

    /// `nil` si la base ne se lit pas : absente, verrouillée ou pas une base SQLite.
    init?(url: URL) {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var result = open("file:\(path)?mode=ro")
        // Base en mode WAL dont l'app propriétaire a fermé toutes ses connexions (Codex inactif) : SQLite a
        // retiré le fichier `-wal` et une connexion en lecture seule ne peut pas le recréer. Tout le contenu
        // est alors dans le fichier principal, que `immutable` lit tel quel, sans WAL ni verrou.
        if result == SQLITE_CANTOPEN, !FileManager.default.fileExists(atPath: url.path + "-wal") {
            result = open("file:\(path)?mode=ro&immutable=1")
        }
        guard result == SQLITE_OK else { return nil }
    }

    /// Ouvre puis lit le schéma : `sqlite3_open_v2` seul ne touche pas encore au fichier, une base
    /// illisible n'échouerait qu'à la première requête (et passerait pour une base vide).
    private func open(_ uri: String) -> Int32 {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        var result = sqlite3_open_v2(uri, &db, flags, nil)
        if result == SQLITE_OK {
            sqlite3_busy_timeout(db, 500)
            result = sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil)
        }
        if result != SQLITE_OK {
            sqlite3_close(db)
            db = nil
        }
        return result
    }

    deinit { sqlite3_close(db) }

    func columns(of table: String) -> Set<String> {
        Set(rows("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
    }

    func rows(_ sql: String, _ bindings: [Any] = []) -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let int as Int: sqlite3_bind_int64(statement, position, Int64(int))
            case let double as Double: sqlite3_bind_double(statement, position, double)
            case let string as String: sqlite3_bind_text(statement, position, string, -1, transient)
            default: sqlite3_bind_null(statement, position)
            }
        }
        var result: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                default: break
                }
            }
            result.append(row)
        }
        return result
    }
}

enum ISODate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func modificationDate(_ url: URL) -> Date? {
        FileStat(url).map { Date(timeIntervalSince1970: $0.modified) }
    }
}

func number(_ value: Any?) -> Double? {
    switch value {
    case let double as Double: double
    case let int as Int: Double(int)
    case let number as NSNumber: number.doubleValue
    default: nil
    }
}

/// Mémorise le résultat d'une lecture tant que le fichier garde la même taille et la même date :
/// un balayage ne relit que les fichiers modifiés depuis le précédent.
final class FileMemo<Value>: @unchecked Sendable {
    private struct Entry { var modified: Date; var size: Int; var value: Value }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func value(for url: URL, compute: () -> Value) -> Value {
        let stat = FileStat(url)
        let modified = stat.map { Date(timeIntervalSince1970: $0.modified) } ?? .distantPast
        let size = stat?.size ?? -1
        lock.lock()
        if let entry = entries[url.path], entry.modified == modified, entry.size == size {
            lock.unlock()
            return entry.value
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        entries[url.path] = Entry(modified: modified, size: size, value: value)
        lock.unlock()
        return value
    }
}

/// `stat()` direct : `FileManager.attributesOfItem` lit aussi les attributs étendus, ce qui coûtait
/// l'essentiel du temps de balayage sur plusieurs centaines de fichiers.
struct FileStat {
    var modified: Double
    var size: Int

    init?(_ url: URL) {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in path.map { stat($0, &info) == 0 } ?? false }) else { return nil }
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        size = Int(info.st_size)
    }
}
