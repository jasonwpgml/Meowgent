import Foundation

/// 맥 상태(CPU·메모리·발열·에너지·GPU)를 보고 고양이가 알려 줄 것을 고른다.
/// 파일·화면을 건드리지 않는 순수 로직이라 Tests/logic 에서 그대로 점검한다.
///
/// 알림 원칙 (docs/REMINDERS.md "맥 상태"):
///  - 잠깐 튀는 건 무시한다. 조건이 정해진 시간(hold) 동안 이어질 때만 말한다.
///  - 지금 쓰고 있는 앱 때문이면 말하지 않는다 (사용자가 이미 안다). 뒤에서 쓰는 앱만.
///  - 같은 일은 한 번만. 조건이 풀렸다가 다시 생겨도 1시간 안에는 또 말하지 않는다.
enum Resource {
    struct App: Equatable {
        var key: String               // 앱 경로 (.app 이 없으면 프로세스 이름) — 무시 목록도 이 키로
        var name: String
        var cpu: Double               // 코어 하나 = 100 (활성 상태 보기와 같은 단위)
        var watts: Double
        var memBytes: UInt64
        var front: Bool               // 지금 앞에 있는 앱 (또는 그 앱이 띄운 프로세스)
    }

    struct Battery: Equatable {
        var percent: Int
        var onBattery: Bool
        var charging: Bool
        var minutesLeft: Int?         // 배터리로 쓸 때 macOS 가 계산한 남은 시간
        var lowPower: Bool
    }

    struct Sample {
        var at: Date
        var cpu: Double               // 전체 0~100
        var cores: Int
        var apps: [App]
        var memUsed: Double           // 0~100
        var pressure: Int             // 0 보통 · 1 빠듯 · 2 심각
        var swapBytes: UInt64
        var thermal: Int              // ProcessInfo.ThermalState 0~3
        var battery: Battery?
        var watts: Double?            // 배터리에서 끌어 쓰는 전력 (배터리로 쓸 때만)
        var gpu: Double?              // 따로 단 GPU 가 있을 때만 0~100 (Apple 칩 내장 GPU 는 안 본다)
        var everyApp: [String: App] = [:]   // apps 는 상위 몇 개뿐이라, 정리 판단은 이걸 본다
        var own: Own? = nil
    }

    // MARK: 묘전트 자신

    /// 묘전트를 이루는 프로세스 묶음. 각자 자식(codex 등)까지 포함한다.
    enum OwnPart: Int, CaseIterable {
        case app, brain, mind
        var title: String { ["앱", "브레인", "말하는 고양이"][rawValue] }
    }

    struct OwnPartUsage: Equatable { var part: OwnPart; var cpu: Double; var memBytes: UInt64 }

    /// 네트워크는 대시보드가 열려 있는 동안만 잰다. 합계도 연 뒤부터다.
    struct OwnNet: Equatable {
        var inRate: Double = 0, outRate: Double = 0
        var inTotal: UInt64 = 0, outTotal: UInt64 = 0
        var failed = false
    }

    struct Own: Equatable {
        var cpu: Double               // 코어 하나 = 100
        var memBytes: UInt64
        var readRate: Double, writeRate: Double       // 초당 바이트
        var readTotal: UInt64, writeTotal: UInt64     // 지금 떠 있는 프로세스들이 시작한 뒤 합계
        var processes: Int
        var parts: [OwnPartUsage]
        var net: OwnNet? = nil
        var dataBytes: UInt64? = nil
    }

    /// 실행 인자로 브레인·말하는 고양이를 알아본다 (둘 다 launchd 가 띄운 python 이라 부모로는 못 찾는다)
    static func helperPart(args: [String]) -> OwnPart? {
        for a in args {
            if a.hasSuffix("/brain/actlog_brain.py") { return .brain }
            if a.hasSuffix("/brain/cat_mind.py") { return .mind }
        }
        return nil
    }

    /// pid → 어느 묶음인지. 부모를 따라 올라가 가장 가까운 뿌리(앱·도우미)에 붙인다. 뿌리에 안 닿으면 묘전트 것이 아니다.
    static func ownMembers(root: Int32, helpers: [Int32: OwnPart], parents: [Int32: Int32]) -> [Int32: OwnPart] {
        var out: [Int32: OwnPart] = [:]
        for pid in parents.keys {
            var cur = pid
            for _ in 0..<32 {
                if cur == root { out[pid] = .app; break }
                if let h = helpers[cur] { out[pid] = h; break }
                guard let up = parents[cur], up != cur else { break }
                cur = up
            }
        }
        return out
    }

    /// nettop -x 한 줄 "이름.pid,받은,보낸," → 머리글이나 깨진 줄은 nil. 이름에 점이 있어도 마지막 점 뒤가 pid 다.
    static func nettopLine(_ line: String) -> (pid: Int32, input: UInt64, output: UInt64)? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 3, let dot = f[0].lastIndex(of: "."), let pid = Int32(f[0][f[0].index(after: dot)...]),
              let i = UInt64(f[1]), let o = UInt64(f[2]) else { return nil }
        return (pid, i, o)
    }

    enum Kind: String { case cpu, memory, thermal, energy, gpu }

    struct Alert: Equatable {
        let key: String               // 이 키로 한 번만 말한다
        let kind: Kind
        let text: String              // 말풍선
        let short: String             // 고양이에 마우스 올렸을 때 한 줄
        let urgent: Bool
        let hold: TimeInterval        // 이만큼 이어져야 말한다
        var app: App? = nil           // 원인 앱 (대시보드에서 "알리지 않기")
    }

    // 문턱값
    static let hogCPU: Double = 90            // 뒤에 있는 앱 하나가 코어 0.9개 넘게
    static let busyCPU: Double = 85           // 전체
    static let hogWatts: Double = 2           // 배터리일 때 뒤에 있는 앱 하나가 2W 넘게
    static let busyGPU: Double = 90

    // MARK: 규칙

    /// 지금 표본에서 성립하는 조건들. 실제로 말할지는 Tracker 가 hold·한 번만 규칙으로 고른다.
    static func alerts(_ s: Sample, ignored: Set<String> = []) -> [Alert] {
        var out: [Alert] = []
        let apps = s.apps.filter { !ignored.contains($0.key) }
        let byCPU = apps.sorted { $0.cpu > $1.cpu }
        let top = s.apps.max { $0.cpu < $1.cpu }

        // CPU: 뒤에서 혼자 많이 쓰는 앱, 아니면 여럿이 나눠서 꽉 채운 경우
        let hogs = byCPU.filter { !$0.front && $0.cpu >= hogCPU }
        for a in hogs {
            out.append(Alert(key: "cpu:" + a.key, kind: .cpu,
                             text: "🔥 뒤에 있는 \(a.name), CPU를 3분째 많이 쓰고 있다냥 (코어 \(cores(a.cpu))개만큼)\n멈춘 건 아닌지 봐 달라냥",
                             short: "🔥 \(a.name) CPU 코어 \(cores(a.cpu))개", urgent: false, hold: 180, app: a))
        }
        if hogs.isEmpty, s.cpu >= busyCPU, let t = top, !t.front, !ignored.contains(t.key) {
            out.append(Alert(key: "cpu:total", kind: .cpu,
                             text: "💻 CPU가 2분째 거의 꽉 찼다냥 (\(Int(s.cpu))%)\n많이 쓰는 앱: " + names(byCPU.prefix(3).filter { $0.cpu >= 10 }.map(\.name)),
                             short: "💻 CPU \(Int(s.cpu))%", urgent: false, hold: 120, app: t))
        }

        // 메모리: 사용률보다 압박 단계가 실제 느려짐과 맞는다 (스왑만 큰 건 맥에선 흔하다)
        let bigMem = apps.sorted { $0.memBytes > $1.memBytes }.prefix(2).map { "\($0.name) \(bytes($0.memBytes))" }
        if s.pressure == 1 {
            out.append(Alert(key: "memory:tight", kind: .memory,
                             text: "🧠 메모리가 빠듯하다냥. 느려질 수 있다냥\n제일 큰 앱: " + names(bigMem),
                             short: "🧠 메모리 빠듯 (\(Int(s.memUsed))%)", urgent: false, hold: 60))
        } else if s.pressure >= 2 {
            out.append(Alert(key: "memory:critical", kind: .memory,
                             text: "🧠 메모리가 바닥났다냥! 안 쓰는 앱을 닫아 달라냥\n제일 큰 앱: " + names(bigMem),
                             short: "🧠 메모리 심각", urgent: true, hold: 20))
        }

        // 발열: serious 부터 macOS 가 속도를 낮춘다
        let busy = byCPU.first.map { "\n제일 바쁜 앱: \($0.name)" } ?? ""
        if s.thermal == 2 {
            out.append(Alert(key: "thermal:serious", kind: .thermal,
                             text: "🌡️ 맥이 뜨겁다냥. 스스로 속도를 낮추는 중이다냥" + busy,
                             short: "🌡️ 맥 뜨거움", urgent: false, hold: 60))
        } else if s.thermal >= 3 {
            out.append(Alert(key: "thermal:critical", kind: .thermal,
                             text: "🌡️ 맥이 너무 뜨겁다냥! 무거운 작업을 잠깐 멈추자냥" + busy,
                             short: "🌡️ 맥 매우 뜨거움", urgent: true, hold: 10))
        }

        // 에너지: 배터리로 쓸 때만
        if let b = s.battery, b.onBattery, !b.charging {
            let byWatts = apps.sorted { $0.watts > $1.watts }
            for a in byWatts where !a.front && a.watts >= hogWatts {
                out.append(Alert(key: "energy:" + a.key, kind: .energy,
                                 text: "🔋 배터리로 쓰는 중인데 뒤에 있는 \(a.name), 전기를 많이 먹는다냥 (약 \(watts(a.watts)))",
                                 short: "🔋 \(a.name) \(watts(a.watts))", urgent: false, hold: 300, app: a))
            }
            if let m = b.minutesLeft, m < 60, b.percent > 25 {
                out.append(Alert(key: "energy:drain", kind: .energy,
                                 text: "⚡ 이대로면 배터리가 \(duration(m)) 뒤 바닥난다냥\n전기 많이 먹는 앱: " + names(byWatts.prefix(3).filter { $0.watts >= 0.3 }.map(\.name)),
                                 short: "⚡ 배터리 \(duration(m)) 남음", urgent: false, hold: 120, app: byWatts.first))
            }
            let lpm = b.lowPower ? "" : "\n저전력 모드를 켜면 더 버틴다냥"
            if b.percent <= 10 {
                out.append(Alert(key: "battery:10", kind: .energy,
                                 text: "🪫 배터리 \(b.percent)%다냥! 지금 충전기 꽂자냥" + lpm,
                                 short: "🪫 배터리 \(b.percent)%", urgent: true, hold: 10))
            } else if b.percent <= 20 {
                out.append(Alert(key: "battery:20", kind: .energy,
                                 text: "🔋 배터리 \(b.percent)% 남았다냥. 충전기 꽂자냥" + lpm,
                                 short: "🔋 배터리 \(b.percent)%", urgent: false, hold: 30))
            }
        }

        // GPU: 따로 단 GPU 만. 앞에 있는 앱이 제일 바쁘면 (게임·렌더링) 말하지 않는다
        if let g = s.gpu, g >= busyGPU, top?.front != true {
            out.append(Alert(key: "gpu:busy", kind: .gpu,
                             text: "🎮 GPU가 5분째 꽉 차 있다냥 (\(Int(g))%)\n뒤에서 뭔가 돌고 있는지 봐 달라냥",
                             short: "🎮 GPU \(Int(g))%", urgent: false, hold: 300))
        }
        return out
    }

    /// 조건이 hold 만큼 이어졌는지, 이번에 이미 말했는지를 기억한다.
    /// 표본 하나쯤 문턱 아래로 내려가도(30초 안) 이어진 것으로 본다.
    struct Tracker {
        var since: [String: Date] = [:]
        var seen: [String: Date] = [:]
        var fired: [String: Date] = [:]         // 마지막으로 말한 시각 (조건이 풀려도 남는다)
        var firedThisTime: Set<String> = []     // 조건이 풀릴 때까지 다시 말하지 않는다

        static let grace: TimeInterval = 30
        static let cooldown: TimeInterval = 3600

        /// 지금 말해도 되는 것 (급한 것 먼저)
        mutating func due(_ alerts: [Alert], now: Date) -> [Alert] {
            for a in alerts { seen[a.key] = now; if since[a.key] == nil { since[a.key] = now } }
            for (k, t) in seen where now.timeIntervalSince(t) > Self.grace {
                seen[k] = nil; since[k] = nil; firedThisTime.remove(k)
            }
            return held(alerts, now: now).filter { a in
                !firedThisTime.contains(a.key) && (fired[a.key].map { now.timeIntervalSince($0) >= Self.cooldown } ?? true)
            }.sorted { $0.urgent && !$1.urgent }
        }

        /// hold 를 채운 조건 (말했든 안 했든) — 메뉴·마우스 올림 요약용
        func held(_ alerts: [Alert], now: Date) -> [Alert] {
            alerts.filter { a in since[a.key].map { now.timeIntervalSince($0) >= a.hold } ?? false }
        }

        mutating func markFired(_ key: String, now: Date) {
            fired[key] = now
            firedThisTime.insert(key)
        }
    }

    // MARK: 글자

    static let thermalName = ["보통", "조금 따뜻", "뜨거움", "매우 뜨거움"]
    static let pressureName = ["보통", "빠듯", "심각"]

    static func cores(_ cpu: Double) -> String { String(format: "%.1f", cpu / 100) }
    static func watts(_ w: Double) -> String { String(format: w < 10 ? "%.1fW" : "%.0fW", w) }

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1fGB", gb) : "\(Int(Double(b) / 1_048_576))MB"
    }

    /// 작은 값까지 읽히는 크기 (디스크·네트워크용)
    static func size(_ b: UInt64) -> String {
        if b < 1024 { return "\(b)B" }
        if b < 1_048_576 { return "\(Int(Double(b) / 1024))KB" }
        return String(format: b < 1_073_741_824 ? "%.1fMB" : "%.1fGB", Double(b) / (b < 1_073_741_824 ? 1_048_576 : 1_073_741_824))
    }
    static func rate(_ perSecond: Double) -> String { size(UInt64(max(perSecond, 0))) + "/s" }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)시간" + (minutes % 60 > 0 ? " \(minutes % 60)분" : "") : "\(minutes)분"
    }

    private static func names(_ list: [String]) -> String { list.isEmpty ? "?" : list.joined(separator: " · ") }
}
