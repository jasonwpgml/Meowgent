import AppKit

/// 고양이 모듈이 없을 때(비공개 저장소 `pet/`가 비어 있을 때) 대신 들어가는 빈 껍데기.
/// 앱은 고양이 없이 수집기·단축키 힌트·한도 알림 로직만 돈다. 말풍선으로 갈 알림은 로그에만 남긴다.
/// 공개 쪽(main.swift)이 쓰는 표면만 갖는다. 진짜 PetController 의 표면이 바뀌면 여기도 맞춘다.
final class PetController: NSObject {
    var agentSummary: () -> String = { "" }
    var extraMenu: ((NSMenu) -> Void)?
    var hasToys: Bool { false }
    var isPaused: () -> Bool = { false }
    var setPaused: (Bool) -> Void = { _ in }
    var contextLine: () -> String? = { nil }
    var isHidden: Bool { true }
    /// 고양이 머리(Codex) 피곤함 0~100 (진짜 고양이는 졸고, 껍데기는 쓰지 않는다)
    static var tirednessSource: () -> Double = { 0 }

    init(dataDir: URL) {
        super.init()
        Log.write("고양이 모듈 없음 (pet/ 비어 있음) → 고양이 없이 수집기만 돈다")
    }

    func start() {}
    func onKey() {}
    func notify(_ text: String, urgent: Bool = false, validUntil: Date? = nil) {
        Log.write("알림 (고양이 없음): " + text.replacingOccurrences(of: "\n", with: " / "))
    }
    func keyHint(_ keys: String, _ title: String) -> Bool { false }
    func trick(_ name: String) {}
    func toggleHidden() {}
}
