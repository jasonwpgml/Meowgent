import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 원본 이벤트 한 건. 시각은 "발생 시점"에 찍는다 (처리 시점 포커스로 귀속하면 틀린다).
struct Event {
    var ts: Double = Date().timeIntervalSince1970
    var mono: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var source: String
    var app: String?
    var bundle: String?
    var pid: Int32?
    var window: String?
    var url: String?
    var payload: [String: Any] = [:]
    var privacy: String = "none"   // none | masked | sensitive | blocked | secure_gap
    /// 민감한 곳에서 생긴 기록. 저장할 때 privacy 를 sensitive 로 바꾼다 (가린 것은 payload.masked 로 남긴다).
    var sensitive = false

    init(_ source: String, payload: [String: Any] = [:], privacy: String = "none") {
        self.source = source
        self.payload = payload
        self.privacy = privacy
    }

    /// 지금 활성 앱·창·URL 문맥을 채운다. 막는 앱이면 창 제목·URL은 남기지 않고, 민감한 곳이면 다 남기고 표시한다.
    mutating func fillContext(_ s: Snapshot = Context.shared.snapshot) {
        app = app ?? s.app
        bundle = bundle ?? s.bundle
        pid = pid ?? s.pid
        if !s.locked {
            window = window ?? s.window
            url = url ?? s.url ?? s.hiddenURL
            sensitive = sensitive || s.sensitive
        }
    }

    /// 저장할 privacy: 내용을 남긴 기록(none·masked)이 민감한 곳이면 sensitive
    var storedPrivacy: String {
        sensitive && (privacy == "none" || privacy == "masked") ? "sensitive" : privacy
    }
}

final class Store {
    let path: URL
    private var db: OpaquePointer?
    private var insert: OpaquePointer?
    private let queue = DispatchQueue(label: "actlog.store")
    private(set) var written = 0

    private static let schema = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS events (
      id      INTEGER PRIMARY KEY,
      ts      REAL NOT NULL,
      mono    INTEGER NOT NULL,
      source  TEXT NOT NULL,
      app     TEXT, bundle TEXT, pid INTEGER, window TEXT, url TEXT,
      payload TEXT NOT NULL,
      privacy TEXT NOT NULL DEFAULT 'none'
    );
    CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
    CREATE INDEX IF NOT EXISTS events_source_ts ON events(source, ts);
    INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1');
    """

    init(dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        path = dir.appendingPathComponent("actlog.db")
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw NSError(domain: "ActLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "DB를 열 수 없음: \(path.path)"])
        }
        chmod(path.path, 0o600)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000;")
        exec(Store.schema)
        let sql = "INSERT INTO events(ts,mono,source,app,bundle,pid,window,url,payload,privacy) VALUES(?,?,?,?,?,?,?,?,?,?)"
        sqlite3_prepare_v2(db, sql, -1, &insert, nil)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            Log.write("sqlite exec 실패: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    /// 일시정지 중이면 버린다. `force`는 일시정지/재개 표시 같은 메타 이벤트용.
    func write(_ e: Event, force: Bool = false) {
        if !force && Context.shared.snapshot.paused { return }
        var payload = e.payload
        if e.storedPrivacy == "sensitive" && e.privacy == "masked" { payload["masked"] = true }
        let privacy = e.storedPrivacy
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "{}"
        }
        queue.async { [self] in
            guard let st = insert else { return }
            sqlite3_reset(st)
            sqlite3_bind_double(st, 1, e.ts)
            sqlite3_bind_int64(st, 2, Int64(bitPattern: e.mono))
            bindText(st, 3, e.source)
            bindText(st, 4, e.app)
            bindText(st, 5, e.bundle)
            if let pid = e.pid { sqlite3_bind_int(st, 6, pid) } else { sqlite3_bind_null(st, 6) }
            bindText(st, 7, e.window)
            bindText(st, 8, e.url)
            bindText(st, 9, json)
            bindText(st, 10, privacy)
            if sqlite3_step(st) != SQLITE_DONE {
                Log.write("insert 실패: \(String(cString: sqlite3_errmsg(db)))")
            } else {
                written += 1
            }
        }
    }

    /// 쌓인 쓰기가 끝날 때까지 기다린다.
    func flush() { queue.sync {} }

    /// 글 내용이 들어가는 기록 (보존 기간이 더 짧다)
    static let contentSources = ["text", "clipboard", "paste", "search", "ai_response"]

    /// 보존 기간이 지난 기록을 지운다 (0 = 안 지움). 지운 자리는 0으로 덮고(secure_delete) WAL 도 비운다.
    /// limit: 보관을 켰을 때 보관이 끝난 시각. 그보다 나중 기록은 기간이 지났어도 남긴다.
    func purge(contentDays: Int, allDays: Int, limit: Double? = nil, now: Double = Date().timeIntervalSince1970) {
        queue.async { [self] in
            var removed = 0
            let cap = limit ?? .infinity
            exec("PRAGMA secure_delete=ON;")
            if contentDays > 0 {
                let list = Store.contentSources.map { "'\($0)'" }.joined(separator: ",")
                removed += delete("DELETE FROM events WHERE ts < ? AND source IN (\(list))", before: min(now - Double(contentDays) * 86400, cap))
            }
            if allDays > 0 {
                removed += delete("DELETE FROM events WHERE ts < ?", before: min(now - Double(allDays) * 86400, cap))
            }
            if removed > 0 {
                exec("PRAGMA wal_checkpoint(TRUNCATE);")
                Log.write("보존 기간 지난 기록 \(removed)건 지움 (글 내용 \(contentDays)일, 전체 \(allDays)일)")
            }
        }
    }

    /// queue 안에서만 부른다.
    private func delete(_ sql: String, before: Double) -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, before)
        guard sqlite3_step(st) == SQLITE_DONE else {
            Log.write("보존 기간 정리 실패: \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }
        return Int(sqlite3_changes(db))
    }

    private func bindText(_ st: OpaquePointer, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    }

    var sizeBytes: Int64 {
        let fm = FileManager.default
        return [path.path, path.path + "-wal"].reduce(Int64(0)) { acc, p in
            acc + ((try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0)
        }
    }
}

enum Log {
    static var url: URL?
    private static let queue = DispatchQueue(label: "actlog.log")

    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        guard let url else { return }
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: false, encoding: .utf8)
            }
        }
    }
}
