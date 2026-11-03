import AppKit
import Carbon

/// 런처에서 꺼내 쓰는 클립보드 기록. 활동 기록과 따로 켜는 기능이고 기본은 꺼짐.
/// 복사한 글만 최근 `limit`개를 이 맥의 clipboard-history.json(0600)에 둔다. 끄면 그 자리에서 지운다.
/// 남기지 않는 것: 비밀번호 관리자 표시가 붙은 복사, 보안 입력 중, 막은 앱·사이트·시크릿 창·주소를 확인 못 한 브라우저에서 한 복사,
/// 키·토큰·카드번호·주민번호처럼 보이는 글 (가려서 남기면 다시 붙여넣을 때 쓸모가 없으니 아예 뺀다).
final class ClipHistory {
    struct Entry: Codable, Equatable {
        var text: String
        var ts: Double
        var app: String?
    }

    static let limit = 100
    static let maxChars = 20_000

    private(set) var entries: [Entry] = []
    private let url: URL
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent("clipboard-history.json")
        if enabled { load() }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: "clipHistoryEnabled") }

    func start() {
        guard enabled, timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "clipHistoryEnabled")
        if on {
            start()
        } else {
            timer?.invalidate()
            timer = nil
            clear()
        }
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0 == e }
        save()
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types?.map(\.rawValue) ?? []
        guard !SystemWatcher.isConcealed(types), !IsSecureEventInputEnabled() else { return }
        let front = NSWorkspace.shared.frontmostApplication
        // 수집기와 같은 기준: 브라우저 주소를 아직(또는 영영) 못 읽은 동안도 막힌 것으로 본다 (fail-closed, Safari 기본 포함)
        guard !Privacy.isBlocked(bundle: front?.bundleIdentifier), !Context.shared.snapshot.blocked else { return }
        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxChars, !Privacy.redact(text).1 else { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, ts: Date().timeIntervalSince1970, app: front?.localizedName), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    private func load() {
        guard let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entry].self, from: d) else { return }
        entries = Array(e.prefix(Self.limit))
    }

    private func save() {
        // 처음부터 0600 으로 만든 임시 파일을 바꿔치기한다 (잠깐이라도 남이 읽을 수 있는 권한으로 두지 않게)
        guard let d = try? JSONEncoder().encode(entries) else { return }
        let tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return }
        rename(tmp.path, url.path)
    }
}
