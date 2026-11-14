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
        var gpu: Double = 0           // GPU 를 쓴 시간 비율 0~100 (Apple 칩 내장 GPU 일 때만 앱별로 안다)
    }

    /// 전원·충전 (AppleSmartBattery 가 있는 맥만). 모르면 nil
    struct Power: Equatable {
        var systemW: Double?          // 맥 전체가 지금 쓰는 전력 (PowerTelemetryData SystemLoad)
        var chargeW: Double?          // 배터리로 들어가는 충전 전력 (전원 연결 중일 때만, 안 들어가면 0)
        var adapterW: Int?            // 꽂힌 충전기가 낼 수 있는 최대 전력
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
        var gpu: Double?              // GPU 사용률 0~100. 따로 단 GPU 가 있으면 그것, 없으면 Apple 칩 내장 GPU
        var everyApp: [String: App] = [:]   // apps 는 상위 몇 개뿐이라, 정리 판단은 이걸 본다
        var own: Own? = nil
        var disk: Disk? = nil               // 시동 디스크 (1분에 한 번 읽는다)
        var power: Power? = nil
        var gpuBuiltIn = false              // gpu 가 Apple 칩 내장 GPU 값인지 (화면 그리기도 같이 써서 알림은 안 한다)
        var gpuOthers: [String: Double] = [:]   // 앱 목록에 없는 프로세스(WindowServer 등 시스템)의 GPU 사용률, 이름 → 0~100
    }

    // MARK: GPU

    /// 내장 GPU 클라이언트가 쌓은 GPU 시간(ns, pid 별 합) 두 번 → pid 별 사용률 (GPU 시간 / 걸린 시간 × 100).
    /// 처음 보는 pid 는 비교할 값이 없어 빠지고, 줄었으면 (클라이언트가 닫힘·pid 재사용) 0 이다.
    /// 다 더하면 GPU 자체가 내는 'Device Utilization %' 의 그 사이 평균과 거의 같다 (M5 에서 46% ↔ 48%, 44% ↔ 45%).
    static func gpuShares(prev: [Int32: UInt64], now: [Int32: UInt64], dt: TimeInterval) -> [Int32: Double] {
        guard dt > 0 else { return [:] }
        var out: [Int32: Double] = [:]
        for (pid, t) in now {
            guard let p = prev[pid] else { continue }
            out[pid] = t >= p ? Double(t - p) / (dt * 1e9) * 100 : 0
        }
        return out
    }

    /// 화면에 보일 시스템 프로세스 이름
    static func gpuProcessName(_ name: String) -> String { name == "WindowServer" ? "화면 그리기 (WindowServer)" : name }

    // MARK: 저장공간

    /// 시동 디스크. free 는 Finder·시스템 설정의 '사용 가능'과 같은 값 (지울 수 있는 캐시 포함)
    struct Disk: Equatable {
        var total: UInt64
        var free: UInt64
        var used: UInt64 { total > free ? total - free : 0 }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    /// 0 넉넉 · 1 빠듯 (10% 또는 25GB 밑) · 2 심각 (5% 또는 10GB 밑)
    static func diskLevel(_ d: Disk) -> Int {
        let left = d.total > 0 ? Double(d.free) / Double(d.total) : 1
        if left < 0.05 || d.free < 10_000_000_000 { return 2 }
        if left < 0.10 || d.free < 25_000_000_000 { return 1 }
        return 0
    }

    /// 저장공간은 Finder·시스템 설정처럼 1000 단위로 적는다 (1TB = 1000GB)
    static func diskSize(_ b: UInt64) -> String {
        let gb = Double(b) / 1e9
        if gb >= 1000 {
            let tb = gb / 1000
            return tb >= 10 || abs(tb - tb.rounded()) < 0.05 ? "\(Int(tb.rounded()))TB" : String(format: "%.1fTB", tb)
        }
        return gb >= 10 ? "\(Int(gb.rounded()))GB" : String(format: "%.1fGB", gb)
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
        var cooldown: TimeInterval? = nil   // 다시 말하기까지 쉬는 시간 (없으면 Tracker.cooldown 1시간)
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
                             short: "🧠 메모리 빠듯 (\(Int(s.memUsed))%)", urgent: false, hold: 300, cooldown: 6 * 3600))
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

        // GPU: 따로 단 GPU 만 (내장 GPU 는 화면 그리기·영상만으로도 쉽게 찬다).
        // 앞에 있는 앱이 제일 바쁘면 (게임·렌더링) 말하지 않는다. 앱별 GPU 를 알면 GPU 를 제일 많이 쓰는 앱으로 본다
        let gpuTop = s.apps.contains { $0.gpu > 0 } ? s.apps.max { $0.gpu < $1.gpu } : top
        if let g = s.gpu, !s.gpuBuiltIn, g >= busyGPU, gpuTop?.front != true {
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
                !firedThisTime.contains(a.key) && (fired[a.key].map { now.timeIntervalSince($0) >= (a.cooldown ?? Self.cooldown) } ?? true)
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

    // MARK: 메뉴바 아이콘 색

    static let hotCPU: Double = 95            // 전체, 이 이상이면 빨강 (주황은 busyCPU)
    static let iconWindow: TimeInterval = 30

    /// 메뉴바 고양이 손 색 단계: 0 평소(흰색·검은색은 메뉴 막대가 정함) · 1 주황 · 2 빨강.
    /// CPU 는 최근 30초 평균이라 잠깐 튀는 건 색을 안 바꾼다. 메모리는 macOS 압박 단계 그대로 (빠듯 = 주황, 심각 = 빨강).
    static func iconLevel(_ history: [Sample], now: Date) -> Int {
        guard let last = history.last else { return 0 }
        let recent = history.filter { now.timeIntervalSince($0.at) <= iconWindow }
        let avg = recent.isEmpty ? last.cpu : recent.reduce(0) { $0 + $1.cpu } / Double(recent.count)
        let cpu = avg >= hotCPU ? 2 : (avg >= busyCPU ? 1 : 0)
        return max(cpu, min(max(last.pressure, 0), 2))
    }

    /// 배터리 위험도: 배터리로 쓰는 중에 20% 이하 = 1 (주황), 10% 이하 = 2 (빨강). 전원에 꽂혀 있으면 0
    static func batteryLevel(_ b: Battery) -> Int {
        guard b.onBattery else { return 0 }
        return b.percent <= 10 ? 2 : (b.percent <= 20 ? 1 : 0)
    }

    // MARK: 앱별로 나눈 막대 (맥 상태 카드)

    /// 막대 한 조각. key 가 빈 조각은 '나머지'(그 밖의 앱·시스템)
    struct Slice: Equatable {
        var key: String
        var name: String
        var value: Double             // 원래 단위 (CPU: 코어 하나 = 100, 메모리: 바이트, 전력: W)
        var fraction: Double          // 막대 전체 폭에 대한 비율
    }

    /// whole: 막대 끝(100%)에 해당하는 값. filled: 실제로 찬 양 (모르면 앱들의 합).
    /// 큰 앱 top 개만 따로 칠하고 나머지는 한 조각으로 묶는다. 막대 폭의 1% 도 안 되는 앱은 나머지로 간다.
    /// 앱들의 합이 filled 보다 크면 (메모리: 압축분이 앱 쪽에 잡히는 등) filled 에 맞춰 줄인다.
    static func slices(_ items: [(key: String, name: String, value: Double)], whole: Double, filled: Double? = nil, top: Int = 5) -> [Slice] {
        guard whole > 0 else { return [] }
        let sorted = items.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let big = sorted.prefix(top).filter { $0.value / whole >= 0.01 }
        let sumBig = big.reduce(0) { $0 + $1.value }
        let fill = min(whole, max(0, filled ?? sorted.reduce(0) { $0 + $1.value }))
        let scale = sumBig > fill && sumBig > 0 ? fill / sumBig : 1
        var out = big.map { Slice(key: $0.key, name: $0.name, value: $0.value, fraction: $0.value * scale / whole) }
        let rest = fill - sumBig * scale
        if rest / whole >= 0.005 { out.append(Slice(key: "", name: "", value: rest, fraction: rest / whole)) }
        return out
    }

    /// 여러 막대를 한 화면에 함께 보일 때: 색을 줄 앱은 keep 개까지만 고르고 (막대들에서 차지한 몫의 합이 큰 순),
    /// 나머지 앱 조각은 각 막대의 '나머지' 조각으로 합친다. 색이 모자라 두 앱이 같은 색이 되는 일을 막는다.
    static func fold(_ bars: [[Slice]], keep: Int) -> (keys: [String], bars: [[Slice]]) {
        var share: [String: Double] = [:]
        var order: [String] = []
        for sl in bars.joined() where !sl.key.isEmpty {
            if share[sl.key] == nil { order.append(sl.key) }
            share[sl.key, default: 0] += sl.fraction
        }
        // 몫이 같으면 먼저 나온 앱이 앞 (정렬이 흔들리지 않게)
        let keys = Array(order.enumerated().sorted { (share[$0.element]!, -$0.offset) > (share[$1.element]!, -$1.offset) }
            .map(\.element).prefix(max(0, keep)))
        let kept = Set(keys)
        let out = bars.map { bar -> [Slice] in
            var restValue = 0.0, restFraction = 0.0
            var slices: [Slice] = []
            for sl in bar {
                if !sl.key.isEmpty && kept.contains(sl.key) { slices.append(sl) } else { restValue += sl.value; restFraction += sl.fraction }
            }
            if restFraction > 0 { slices.append(Slice(key: "", name: "", value: restValue, fraction: restFraction)) }
            return slices
        }
        return (keys, out)
    }

    /// 앱마다 색 번호를 정한다. 한 번 받은 색은 계속 쓰고, 지금 보이는 앱끼리는 겹치지 않게 한다.
    /// 처음 받는 앱은 이름에서 나온 번호부터 빈 색을 찾는다 (다시 켜도 같은 앱은 대개 같은 색).
    static func assignColors(_ keys: [String], current: [String: Int], palette: Int) -> [String: Int] {
        guard palette > 0 else { return current }
        var out = current
        var used = Set<Int>()
        var fresh: [String] = []
        for k in keys where !k.isEmpty {
            if let c = current[k], c < palette, !used.contains(c) { used.insert(c) } else if !fresh.contains(k) { fresh.append(k) }
        }
        for k in fresh {
            let start = Int(stableHash(k) % UInt64(palette))
            let free = (0..<palette).map { (start + $0) % palette }.first { !used.contains($0) }
            let c = free ?? start
            out[k] = c
            used.insert(c)
        }
        return out
    }

    /// 실행마다 바뀌지 않는 해시 (FNV-1a). Swift 의 hashValue 는 실행마다 달라서 쓰지 않는다
    static func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
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
