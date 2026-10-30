import Foundation

/// 앱을 정리할지 판단한다. 파일·화면을 건드리지 않는 순수 로직이라 Tests/logic 에서 그대로 점검한다.
///
/// 잘못 끄면 작업을 잃으므로 (docs/REMINDERS.md "앱 정리"):
///  - 처음 보는 앱은 절대 알아서 끄지 않는다. 사용자가 "앞으로 자동 정리"를 고른 앱만 자동이다.
///  - 자동은 창이 하나도 없을 때만. 창이 없으면 잃을 작업이 없다.
///  - 지금 쓰는 앱, 일하는 중인 앱(CPU), 보호 목록(시스템·개발·AI·통화·보안 앱 등)은 묻지도 않는다.
///  - 창 없는 프로세스(데몬)는 대상이 아니다. launchd 가 다시 띄우거나 다른 앱이 깨진다.
enum Cleanup {
    struct Candidate {
        var key: String               // 앱 경로
        var bundleID: String
        var name: String
        var regular: Bool             // Dock 에 뜨는 앱. false 면 메뉴바 앱
        var front: Bool
        var hasWindows: Bool
        var idle: TimeInterval        // 마지막으로 쓴 뒤 지난 시간
        var tracked: TimeInterval     // 지켜본 시간
        var avgCPU: Double            // 최근 몇 분 평균 (코어 하나 = 100)
        var memBytes: UInt64
    }

    struct Prefs {
        var always: Set<String> = []
        var never: Set<String> = []
        var snoozedUntil: [String: Date] = [:]
    }

    struct Limits {
        var minTracked: TimeInterval = 10 * 60
        var askIdle: TimeInterval = 2 * 3600        // 이만큼 안 쓴 앱만 묻는다
        var quietIdle: TimeInterval = 6 * 3600      // 창 없는 앱은 이만큼 안 써야 묻거나 자동으로 끈다
        var busyCPU: Double = 5                     // 평균 이상이면 일하는 중으로 본다
        var autoCPU: Double = 1                     // 자동은 이보다 조용해야 한다
        var bigMem: UInt64 = 1_073_741_824
        var tightMem: UInt64 = 300 * 1_048_576      // 메모리가 빠듯할 때는 이 정도도 묻는다
        var hogCPU: Double = 30                     // 메뉴바 앱이 이만큼 쓰면 묻는다
    }

    enum Verdict: Equatable {
        case keep
        case ask(String)
        case auto(String)
    }

    /// 묻지도 끄지도 않는 앱 (번들 ID 앞부분, 소문자).
    /// 시스템, 개발 도구·터미널, AI 에이전트, 통화·메신저, 보안, 음악·녹화, 원격·입력 공유, 네트워크, 동기화
    static let protected = [
        "com.apple.", "io.github.jasonwpgml.",
        "com.anthropic.", "com.openai.", "com.anysphere.", "com.todesktop.230313mzl4w4u92", "com.stablyai.",
        "com.microsoft.vscode", "com.jetbrains.", "com.googlecode.iterm2", "dev.warp.", "com.github.wez", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "com.orbstack.", "com.docker.", "com.usebruno.",
        "us.zoom.", "com.microsoft.teams", "com.hnc.discord", "com.tinyspeck.slackmacgap", "com.kakao.", "ru.keepcoder.telegram",
        "com.1password.", "com.agilebits.", "com.bitwarden.",
        "com.spotify.", "com.colliderli.iina", "com.obsproject.", "com.meetily.", "com.chidiwilliams.buzz",
        "com.microsoft.rdc", "com.google.chromeremotedesktop", "com.squirrels.", "org.deskflow.", "de.feschber.", "local.inkbridge.",
        "io.tailscale.", "org.pqrs.", "pro.betterdisplay.", "com.raycast.", "eu.exelban.", "com.steipete.", "com.setapp.",
        "com.google.drivefs", "com.dropbox.", "com.getdropbox.",
    ]

    static func isProtected(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return id.isEmpty || protected.contains { id.hasPrefix($0) }
    }

    static func decide(_ c: Candidate, pressure: Int, prefs: Prefs, now: Date, limits l: Limits = Limits()) -> Verdict {
        if isProtected(c.bundleID) || prefs.never.contains(c.key) || c.front || c.tracked < l.minTracked { return .keep }
        let mem = Resource.bytes(c.memBytes)
        let snoozed = prefs.snoozedUntil[c.key].map { now < $0 } ?? false

        // 메뉴바 앱은 뒤에서 일하는 게 본업이라 안 썼다는 걸로는 판단할 수 없다. 많이 쓸 때만 묻고 자동은 없다
        guard c.regular else {
            if snoozed { return .keep }
            if c.memBytes >= l.bigMem { return .ask("메뉴바에서 메모리를 \(mem)나 쓴다냥") }
            if c.avgCPU >= l.hogCPU { return .ask("메뉴바에서 CPU를 \(Int(c.avgCPU))%나 계속 쓴다냥") }
            return .keep
        }

        if c.avgCPU >= l.busyCPU { return .keep }
        if snoozed { return .keep }   // 부탁했는데 안 꺼진 앱도 여기 걸린다. 자동이라도 반복하지 않는다
        let quietly = !c.hasWindows && c.idle >= l.quietIdle
        if quietly, c.avgCPU < l.autoCPU, prefs.always.contains(c.key) {
            return .auto("창도 없이 \(hours(c.idle))시간 넘게 안 썼다냥")
        }
        if quietly { return .ask("창도 없이 \(hours(c.idle))시간 넘게 안 썼다냥 (메모리 \(mem))") }
        guard c.idle >= l.askIdle else { return .keep }
        if c.memBytes >= l.bigMem { return .ask("\(hours(c.idle))시간 넘게 안 썼는데 메모리를 \(mem)나 쓴다냥") }
        if pressure >= 1, c.memBytes >= l.tightMem { return .ask("메모리가 빠듯한데 \(hours(c.idle))시간 넘게 안 쓰면서 \(mem)를 쓴다냥") }
        return .keep
    }

    private static func hours(_ t: TimeInterval) -> Int { max(1, Int(t / 3600)) }
}
