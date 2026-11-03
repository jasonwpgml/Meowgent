import AppKit
import Carbon
import CryptoKit
import Vision

/// 런처에서 꺼내 쓰는 클립보드 기록. 활동 기록과 따로 켜는 기능이고 기본은 꺼짐. 끄면 그 자리에서 다 지운다.
/// 글·링크·색·이미지·파일을 남기고, 글은 서식(RTF·HTML)도 같이 둔다. 디스크엔 ClipVault 로 암호화해서 `clipboard/` 에만.
/// 고정한 것은 계속 두고, 나머지는 보관 기간(기본 30일)과 최근 `maxCount`개 안에서만 둔다.
/// 남기지 않는 것: 비밀번호 관리자 표시가 붙은 복사, 보안 입력 중, 막은 앱·사이트·시크릿 창·주소를 확인 못 한 브라우저에서 한 복사,
/// "기록 안 할 앱"에서 한 복사, 키·토큰·카드번호·주민번호처럼 보이는 글 (이미지는 글자를 읽어 같은 규칙으로 거른다.
/// 글자를 못 읽은 이미지는 확인할 수 없으니 남기지 않는다).
final class ClipHistory {
    struct Entry: Codable, Equatable {
        var id: String
        var kind: ClipRules.Kind
        /// 글·링크·색: 내용 · 파일: 경로들(줄바꿈) · 이미지: 비어 있음
        var text: String
        /// 이미지 속 글자 (검색용)
        var ocr: String?
        var ts: Double
        var app: String?
        var bundle: String?
        var pinned = false
        var bytes: Int?
        var width: Int?
        var height: Int?
        /// 서식 조각(id.rich)이 따로 있나
        var rich = false
        /// 같은 이미지를 다시 복사했는지 알아보는 지문
        var hash: String?

        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
        var paths: [String] { kind == .file ? text.split(separator: "\n").map(String.init) : [] }
    }

    private struct Rich: Codable {
        var rtf: Data?
        var html: Data?
    }

    static let maxCount = 500
    static let maxChars = 100_000
    static let maxImageBytes = 20_000_000
    static let maxRichBytes = 2_000_000

    private(set) var entries: [Entry] = []
    private let dir: URL
    private let legacy: URL
    private var vault: ClipVault?
    private var timer: Timer?
    private var pruneTimer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var thumbs: [String: NSImage] = [:]
    private let ocrQueue = DispatchQueue(label: "meowgent.clip.ocr", qos: .utility)

    init(dataDir: URL) {
        dir = dataDir.appendingPathComponent("clipboard", isDirectory: true)
        legacy = dataDir.appendingPathComponent("clipboard-history.json")
        if enabled { open() }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: "clipHistoryEnabled") }

    /// 고정 안 한 기록을 며칠 둘지 (0 = 기간 제한 없이 개수만)
    var retentionDays: Int {
        get { UserDefaults.standard.object(forKey: "clipRetentionDays") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "clipRetentionDays"); prune() }
    }

    /// 기록 안 할 앱 bundle id
    var ignored: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "clipIgnoredBundles") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "clipIgnoredBundles") }
    }

    func start() {
        guard enabled, timer == nil else { return }
        if vault == nil { open() }
        lastCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.prune() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "clipHistoryEnabled")
        if on {
            start()
        } else {
            timer?.invalidate(); timer = nil
            pruneTimer?.invalidate(); pruneTimer = nil
            clear()
            vault = nil
        }
    }

    /// 고정한 것까지 전부 지운다
    func clear() {
        entries = []
        thumbs = [:]
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: legacy)
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0 == e }
        dropBlobs(e)
        save()
    }

    func togglePin(_ e: Entry) {
        guard let i = entries.firstIndex(of: e) else { return }
        entries[i].pinned.toggle()
        save()
    }

    // MARK: 읽기

    func image(_ e: Entry) -> NSImage? {
        guard e.kind == .image, let d = vault?.read(e.id + ".img") else { return nil }
        return NSImage(data: d)
    }

    /// 목록용 작은 그림 (한 번 풀면 기억해 둔다)
    func thumbnail(_ e: Entry) -> NSImage? {
        if let t = thumbs[e.id] { return t }
        guard let img = image(e) else { return nil }
        let t = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { r in
            let s = img.size, k = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
            let w = s.width * k, h = s.height * k
            img.draw(in: NSRect(x: (r.width - w) / 2, y: (r.height - h) / 2, width: w, height: h))
            return true
        }
        thumbs[e.id] = t
        return t
    }

    // MARK: 붙여넣기용으로 클립보드에 올리기

    /// plain: 서식 없이 글만. 올린 항목은 맨 위로 (방금 쓴 것)
    @discardableResult
    func put(_ e: Entry, plain: Bool) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        var ok = true
        switch e.kind {
        case .image:
            guard let d = vault?.read(e.id + ".img") else { ok = false; break }
            pb.setData(d, forType: .png)
            if let tiff = NSImage(data: d)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        case .file:
            ok = pb.writeObjects(e.paths.map { URL(fileURLWithPath: $0) as NSURL })
        case .text, .link, .color:
            if !plain, e.rich, let d = vault?.read(e.id + ".rich"), let r = try? JSONDecoder().decode(Rich.self, from: d) {
                if let rtf = r.rtf { pb.setData(rtf, forType: .rtf) }
                if let html = r.html { pb.setData(html, forType: .html) }
            }
            pb.setString(e.text, forType: .string)
        }
        lastCount = pb.changeCount   // 내가 올린 것을 새 복사로 다시 담지 않게
        if ok, let i = entries.firstIndex(of: e) {
            var moved = entries.remove(at: i)
            moved.ts = Date().timeIntervalSince1970
            entries.insert(moved, at: 0)
            save()
        }
        return ok
    }

    // MARK: 담기

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard vault?.isReady == true else { return }
        let types = pb.types?.map(\.rawValue) ?? []
        guard !SystemWatcher.isConcealed(types), !IsSecureEventInputEnabled() else { return }
        let front = NSWorkspace.shared.frontmostApplication
        // 수집기와 같은 기준: 브라우저 주소를 아직(또는 영영) 못 읽은 동안도 막힌 것으로 본다 (fail-closed, Safari 기본 포함)
        guard !Privacy.isBlocked(bundle: front?.bundleIdentifier), !Context.shared.snapshot.blocked,
              !ignored.contains(front?.bundleIdentifier ?? "") else { return }
        let base = Entry(id: UUID().uuidString, kind: .text, text: "", ts: Date().timeIntervalSince1970,
                         app: front?.localizedName, bundle: front?.bundleIdentifier)

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var e = base
            e.kind = .file
            e.text = urls.map(\.path).joined(separator: "\n")
            add(e)
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard text.count <= Self.maxChars, !Privacy.redact(text).1 else { return }
            var e = base
            e.kind = ClipRules.classify(text)
            e.text = text
            let rich = Rich(rtf: pb.data(forType: .rtf), html: pb.data(forType: .html))
            let size = (rich.rtf?.count ?? 0) + (rich.html?.count ?? 0)
            let richData = size > 0 && size <= Self.maxRichBytes ? try? JSONEncoder().encode(rich) : nil
            e.rich = richData != nil
            add(e, rich: richData)
        } else if let png = Self.pngData(pb), png.count <= Self.maxImageBytes, let rep = NSBitmapImageRep(data: png), let cg = rep.cgImage {
            var e = base
            e.kind = .image
            e.bytes = png.count
            e.width = rep.pixelsWide
            e.height = rep.pixelsHigh
            e.hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            // 글자를 읽어 키·토큰 같은 게 보이면 버린다. 다 읽은 뒤에야 담는다
            ocrQueue.async { [weak self] in
                let text = Self.recognize(cg)
                DispatchQueue.main.async {
                    guard let self, let text else { Log.write("클립보드 기록: 이미지 글자 인식 실패 → 남기지 않음"); return }
                    guard !Privacy.redact(text).1 else { Log.write("클립보드 기록: 이미지에 민감한 글자 → 남기지 않음"); return }
                    var e = e
                    e.ocr = text.isEmpty ? nil : text
                    self.add(e, image: png)
                }
            }
        }
    }

    private func add(_ new: Entry, rich: Data? = nil, image: Data? = nil) {
        guard enabled, let vault else { return }
        // 같은 것을 다시 복사하면 새로 만들지 않고 맨 위로 (고정 여부는 지킨다)
        if let i = entries.firstIndex(where: { $0.kind == new.kind && (new.kind == .image ? $0.hash == new.hash : $0.text == new.text) }) {
            var old = entries.remove(at: i)
            old.ts = new.ts
            old.app = new.app
            old.bundle = new.bundle
            entries.insert(old, at: 0)
            save()
            return
        }
        if let rich, !vault.write(rich, name: new.id + ".rich") { return }
        if let image, !vault.write(image, name: new.id + ".img") { return }
        entries.insert(new, at: 0)
        prune()
        save()
    }

    private static func pngData(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 이미지 속 글자 (한국어·영어). 인식 자체가 실패하면 nil
    private static func recognize(_ cg: CGImage) -> String? {
        var out: String?
        let req = VNRecognizeTextRequest { r, err in
            guard err == nil else { return }
            out = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ko-KR", "en-US"]
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { return nil }
        return out
    }

    // MARK: 저장

    private func open() {
        vault = ClipVault(dir: dir)
        if let d = vault?.read("index.bin"), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
        importLegacy()
        prune()
        var names: Set<String> = ["index.bin"]
        for e in entries {
            if e.kind == .image { names.insert(e.id + ".img") }
            if e.rich { names.insert(e.id + ".rich") }
        }
        vault?.removeOrphans(keeping: names)
    }

    /// 예전(평문 clipboard-history.json, 글만) 기록을 옮기고 평문 파일은 지운다
    private func importLegacy() {
        struct Old: Codable { var text: String; var ts: Double; var app: String? }
        guard let d = try? Data(contentsOf: legacy) else { return }
        if let old = try? JSONDecoder().decode([Old].self, from: d) {
            for o in old where !entries.contains(where: { $0.kind != .image && $0.text == o.text }) {
                entries.append(Entry(id: UUID().uuidString, kind: ClipRules.classify(o.text), text: o.text, ts: o.ts, app: o.app))
            }
            entries.sort { $0.ts > $1.ts }
            save()
        }
        try? FileManager.default.removeItem(at: legacy)
    }

    private func prune() {
        let gone = ClipRules.expired(entries.map { .init(id: $0.id, ts: $0.ts, pinned: $0.pinned) },
                                     now: Date().timeIntervalSince1970, days: retentionDays, maxCount: Self.maxCount)
        guard !gone.isEmpty else { return }
        for e in entries where gone.contains(e.id) { dropBlobs(e) }
        entries.removeAll { gone.contains($0.id) }
        save()
    }

    private func dropBlobs(_ e: Entry) {
        thumbs[e.id] = nil
        vault?.remove(e.id + ".img")
        vault?.remove(e.id + ".rich")
    }

    private func save() {
        guard let vault, let d = try? JSONEncoder().encode(entries) else { return }
        _ = vault.write(d, name: "index.bin")
    }
}
