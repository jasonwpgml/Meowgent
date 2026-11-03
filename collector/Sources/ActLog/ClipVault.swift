import CryptoKit
import Foundation
import Security

/// 클립보드 기록을 디스크에 암호화해서 둔다 (AES-GCM). 열쇠는 키체인에만 있고, 파일은 0600·폴더는 0700.
/// 키체인 열쇠를 잃으면(다른 맥으로 옮기거나 키체인을 지우면) 기록을 못 읽으니 그때는 비우고 새로 시작한다.
final class ClipVault {
    let dir: URL
    private let key: SymmetricKey?

    static let service = "io.github.jasonwpgml.meowgent.clipboard"

    /// service: 키체인 항목 이름 (시험할 때만 바꾼다)
    init(dir: URL, service: String = ClipVault.service) {
        self.dir = dir
        key = Self.loadOrCreateKey(service: service)
        if key == nil { Log.write("클립보드 기록: 열쇠가 없어 기록을 저장하지 않는다") }
    }

    var isReady: Bool { key != nil }

    func write(_ data: Data, name: String) -> Bool {
        guard let key, let sealed = try? AES.GCM.seal(data, using: key).combined else { return false }
        ensureDir()
        // 처음부터 0600 으로 만든 임시 파일을 바꿔치기한다 (잠깐이라도 남이 읽을 수 있는 권한으로 두지 않게)
        let url = dir.appendingPathComponent(name), tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: sealed, attributes: [.posixPermissions: 0o600]) else { return false }
        return rename(tmp.path, url.path) == 0
    }

    func read(_ name: String) -> Data? {
        guard let key, let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 목록에 없는 조각 파일 정리 (지우다 꺼졌을 때 남은 것)
    func removeOrphans(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where !names.contains(f) { remove(f) }
    }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: 키체인

    /// 있으면 읽고, "없다"고 확인될 때만 새로 만든다 (잠겼거나 접근을 거절한 경우에 덮어쓰면 기존 기록을 영영 못 읽는다)
    private static func loadOrCreateKey(service: String) -> SymmetricKey? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "key"]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(base.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data, d.count == 32 { return SymmetricKey(data: d) }
        guard status == errSecItemNotFound else {
            Log.write("클립보드 기록: 키체인 열쇠를 못 읽음 (\(status))")
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        let add = base.merging([kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecAttrLabel as String: "Meowgent 클립보드 기록 열쇠"]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}
