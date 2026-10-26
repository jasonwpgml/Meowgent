import Foundation

/// ~/Library/LaunchAgents/<label>.plist 로 로그인 시 자동 실행 + 비정상 종료 시 재시작.
/// (SMAppService는 상태가 꼬였을 때 확인·복구가 어려워 일반 LaunchAgent를 쓴다)
struct LaunchAgent {
    static let label = "io.github.jasonwpgml.meowgent"
    /// 이름을 바꾸기 전(ActLog 시절) 라벨. 남아 있으면 지운다.
    static let oldLabel = "com.jason.actlog"
    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.label).plist")
    }
    private var domain: String { "gui/\(getuid())" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    var isLoaded: Bool { launchctl(["print", "\(domain)/\(LaunchAgent.label)"]) == 0 }

    func install() -> Bool {
        let exe = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": LaunchAgent.label,
            "ProgramArguments": [exe],
            "EnvironmentVariables": ["ACTLOG_LAUNCHD": "1"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // 메뉴의 "종료"(정상 종료)가 아니면 다시 띄운다
            "ThrottleInterval": 5,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            Log.write("LaunchAgent 작성 실패: \(error)")
            return false
        }
        if isLoaded { _ = launchctl(["bootout", "\(domain)/\(LaunchAgent.label)"]) }
        return launchctl(["bootstrap", domain, plistURL.path]) == 0
    }

    func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
        _ = launchctl(["bootout", "\(domain)/\(LaunchAgent.label)"])
    }

    /// 옛 라벨의 LaunchAgent가 남아 있으면 내리고 지운다 (두 개가 같이 뜨는 것을 막는다)
    func removeOld() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.oldLabel).plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = launchctl(["bootout", "\(domain)/\(LaunchAgent.oldLabel)"])
        try? FileManager.default.removeItem(at: url)
        Log.write("옛 LaunchAgent(\(LaunchAgent.oldLabel)) 제거")
    }

    func kickstart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "\(domain)/\(LaunchAgent.label)"]
        try? p.run()
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
