import AppKit
import Darwin
import IOKit
import IOKit.ps

/// CPU·메모리·발열·에너지(배터리)·GPU 를 10초마다 읽어서, 오래 이어지는 문제만 고양이 말풍선으로 알린다 (규칙: ResourceRules).
/// 말풍선을 2초 올려 두거나 누르면 ResourceDashboard 가 열린다. 대시보드가 떠 있는 동안은 2초마다 읽는다.
/// 관리자 권한 없이 읽히는 것만 쓴다: 다른 사용자·시스템(root) 프로세스는 앱 목록에서 빠진다. 외부로 보내는 것 없음.
final class ResourceWatch: NSObject {
    struct Notice { let text: String; let urgent: Bool; let validUntil: Date; let detail: NoticeDetail }
    var notify: ((Notice) -> Void)?

    private let queue = DispatchQueue(label: "meowgent.resource", qos: .utility)
    private let sampler = Sampler()       // queue 에서만 만진다
    private var timer: Timer?
    private var lastCalmNotice = Date.distantPast
    private var tracker = Resource.Tracker()
    private lazy var dashboard = ResourceDashboard(watch: self)
    private let netMeter = NetMeter()
    let cleaner = AppCleaner()
    /// 데이터 폴더 크기를 잴 곳
    var dataDir: URL? { didSet { let d = dataDir; queue.async { [sampler] in sampler.dataDir = d } } }

    // 메인 스레드에서만 만진다
    private(set) var latest: Resource.Sample?
    private(set) var history: [Resource.Sample] = []
    private(set) var active: [Resource.Alert] = []

    static let interval: TimeInterval = 10
    static let fastInterval: TimeInterval = 2
    static let historySpan: TimeInterval = 10 * 60
    /// 급하지 않은 알림은 15분에 하나까지 (나머지는 다음 차례)
    static let calmGap: TimeInterval = 15 * 60

    var alertsOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "resourceAlertsOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "resourceAlertsOff") }
    }
    /// 알리지 않을 앱: 키(경로) → 이름
    private(set) var ignored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "resourceIgnored") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "resourceIgnored") }
    }

    func start() {
        cleaner.notify = { [weak self] text, until in
            guard let self else { return }
            self.notify?(Notice(text: text, urgent: false, validUntil: until, detail: self.detail(for: nil)))
        }
        cleaner.changed = { [weak self] in self?.dashboard.refresh() }
        cleaner.start()
        schedule(Self.interval)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.poll() }
    }

    /// 대시보드가 열려 있으면 2초, 아니면 10초
    func setFast(_ fast: Bool) {
        schedule(fast ? Self.fastInterval : Self.interval)
        setNetMeter(fast)
        if fast { poll() }
    }

    /// 네트워크는 nettop 을 띄워야 읽히므로 대시보드가 떠 있는 동안만 잰다
    private func setNetMeter(_ on: Bool) {
        guard on != netMeter.isRunning else { return }
        queue.async { [sampler] in sampler.setNet(on: on) }
        guard on else { netMeter.stop(); return }
        netMeter.start(
            line: { [queue, sampler] l in queue.async { sampler.netLine(l) } },
            ended: { [queue, sampler] secs in queue.async { sampler.netRunEnded(seconds: secs) } },
            failed: { [queue, sampler] in queue.async { sampler.netFailed() } })
    }

    private func schedule(_ every: TimeInterval) {
        guard timer?.timeInterval != every else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = every * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let front = NSWorkspace.shared.frontmostApplication.map { ($0.bundleURL?.path, $0.processIdentifier) }
        queue.async { [weak self] in
            guard let self, let s = self.sampler.sample(frontPath: front?.0 ?? nil, frontPID: front?.1) else { return }
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    private func apply(_ s: Resource.Sample) {
        latest = s
        history.append(s)
        history.removeAll { s.at.timeIntervalSince($0.at) > Self.historySpan }

        let alerts = Resource.alerts(s, ignored: Set(ignored.keys))
        var due = tracker.due(alerts, now: s.at)
        active = tracker.held(alerts, now: s.at)
        cleaner.observe(s, canAsk: alertsOn)
        dashboard.refresh()
        guard alertsOn else { return }
        if s.at.timeIntervalSince(lastCalmNotice) < Self.calmGap { due = due.filter(\.urgent) }
        guard let a = due.first else { return }
        tracker.markFired(a.key, now: s.at)
        if !a.urgent { lastCalmNotice = s.at }
        Log.write("맥 상태 알림: \(a.text.replacingOccurrences(of: "\n", with: " / "))")
        notify?(Notice(text: a.text, urgent: a.urgent, validUntil: s.at.addingTimeInterval(10 * 60), detail: detail(for: a)))
    }

    /// 말풍선에 붙일 자세히 보기: 2초 올려 두면 미리보기, 누르면 고정
    func detail(for a: Resource.Alert?) -> NoticeDetail {
        NoticeDetail(show: { [weak self] anchor, pinned in self?.dashboard.show(focus: a, anchor: anchor, pinned: pinned) },
                     hide: { [weak self] in self?.dashboard.hidePreview() })
    }

    func ignore(_ app: Resource.App) {
        var m = ignored
        m[app.key] = app.name
        ignored = m
        Log.write("맥 상태 알림 끔: \(app.name)")
    }

    // MARK: 메뉴 · 요약

    /// 고양이에 마우스를 올렸을 때 붙일 것: 지금 이어지고 있는 문제만
    var attention: String { active.map(\.short).joined(separator: "\n") }

    func addMenuItems(to menu: NSMenu) {
        let top = NSMenuItem(title: "🖥️ 맥 상태", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i) }
        if let s = latest {
            info("CPU \(Int(s.cpu))% · 메모리 \(Int(s.memUsed))% (\(Resource.pressureName[min(s.pressure, 2)])) · 발열 \(Resource.thermalName[min(s.thermal, 3)])")
            if let b = s.battery { info(ResourceDashboard.batteryLine(b, watts: s.watts)) }
            if let g = s.gpu { info("GPU \(Int(g))%") }
            if let o = s.own { info("묘전트 CPU \(String(format: "%.1f", o.cpu))% · 메모리 \(Resource.bytes(o.memBytes))") }
        } else {
            info("아직 읽는 중이다냥")
        }
        for a in active { info(a.short) }
        sub.addItem(.separator())
        sub.addItem("📊 대시보드 열기", #selector(openDashboard), target: self)
        sub.addItem("활성 상태 보기 열기", #selector(openActivityMonitor), target: self)
        sub.addItem(.separator())
        sub.addItem(alertsOn ? "🔕 맥 상태 알림 끄기" : "🔔 맥 상태 알림 켜기", #selector(toggleAlerts), target: self)
        let list = ignored
        if !list.isEmpty {
            let it = NSMenuItem(title: "알리지 않는 앱 (누르면 다시 알림)", action: nil, keyEquivalent: "")
            let m = NSMenu()
            for (k, name) in list.sorted(by: { $0.value < $1.value }) {
                m.addItem(name, #selector(unignore(_:)), target: self).representedObject = k
            }
            it.submenu = m
            sub.addItem(it)
        }
        sub.addItem(.separator())
        cleaner.addMenuItems(to: sub)
        top.submenu = sub
        menu.addItem(top)
    }

    @objc func openDashboard() {
        let m = NSEvent.mouseLocation
        dashboard.show(focus: nil, anchor: CGRect(x: m.x, y: m.y, width: 1, height: 1), pinned: true)
    }

    @objc func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func toggleAlerts() { alertsOn.toggle() }

    @objc private func unignore(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        var m = ignored
        m[k] = nil
        ignored = m
    }
}

// MARK: - 네트워크

/// 프로세스별 네트워크 양은 공개 API 가 없어서 nettop 으로 읽는다. 대시보드가 떠 있는 동안만 돈다.
/// 계속 띄워 두지 않고 5초씩 재고 끝나게 해서 다시 띄운다. 이 앱이 죽어도 nettop 이 남지 않아야 하기 때문이다.
///  - 입력을 /dev/null 로 주거나 입력이 닫히면 nettop 이 코어 하나를 다 쓴다. 그래서 열어 둔 파이프를 준다.
///  - 파이프로 받으면 끝날 때 한꺼번에 나오므로 끝난 뒤 줄 단위로 넘긴다.
private final class NetMeter {
    static let span = 5
    private var process: Process?
    private var line: ((String) -> Void)?
    private var ended: ((Double) -> Void)?
    private var failed: (() -> Void)?
    var isRunning: Bool { line != nil }

    func start(line: @escaping (String) -> Void, ended: @escaping (Double) -> Void, failed: @escaping () -> Void) {
        self.line = line
        self.ended = ended
        self.failed = failed
        runOnce()
    }

    func stop() {
        line = nil; ended = nil; failed = nil
        process?.terminate()
        process = nil
    }

    private func runOnce() {
        let p = Process(), out = Pipe(), stdin = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "2", "-s", "\(Self.span)", "-d", "-n", "-x", "-J", "bytes_in,bytes_out"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = stdin
        p.terminationHandler = nil
        do { try p.run() } catch { failed?(); stop(); return }
        process = p
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = out.fileHandleForReading.readDataToEndOfFile()   // 끝날 때까지 기다린다
            p.waitUntilExit()
            withExtendedLifetime(stdin) {}
            DispatchQueue.main.async {
                guard let self, self.process === p, let line = self.line else { return }   // stop() 으로 끈 것
                guard p.terminationStatus == 0 else { self.failed?(); self.stop(); return }
                String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { line(String($0)) }
                self.ended?(Double(Self.span))
                self.runOnce()
            }
        }
    }
}

// MARK: - 읽기 (백그라운드 queue 전용)

private final class Sampler {
    private var lastTicks: [UInt32]?
    private var lastProc: [pid_t: Proc] = [:]
    private var lineage: [pid_t: (start: UInt64, parent: pid_t, helper: Resource.OwnPart?)] = [:]
    private var ownPids: Set<pid_t> = []
    var dataDir: URL?
    private var dataBytes: UInt64?
    private var dataMeasuredAt: TimeInterval = -.infinity
    private var net: Resource.OwnNet?
    private var netIn: UInt64 = 0, netOut: UInt64 = 0
    private var netBatches = 0
    private var lastAt: TimeInterval = 0
    private var names: [pid_t: (start: UInt64, key: String, name: String)] = [:]
    private let timebase: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()

    /// 앱이 띄운 도우미·터미널에서 돌린 명령을 그 앱으로 묶는다 (활성 상태 보기도 쓰는 함수, 없으면 자기 자신)
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    /// 처음 한 번은 비교할 이전 값이 없어서 nil
    func sample(frontPath: String?, frontPID: pid_t?) -> Resource.Sample? {
        let now = ProcessInfo.processInfo.systemUptime
        let ticks = cpuTicks()
        let procs = processes()
        defer { lastTicks = ticks; lastProc = procs; lastAt = now }
        guard let prev = lastTicks, now - lastAt > 0.5 else { return nil }
        let dt = now - lastAt

        let d = zip(ticks, prev).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        let cpu = total > 0 ? (d[0] + d[1] + d[3]) / total * 100 : 0   // user + system + nice

        var apps: [String: Resource.App] = [:]
        for (pid, p) in procs {
            let (key, name) = owner(pid, start: p.start)
            var a = apps[key] ?? Resource.App(key: key, name: name, cpu: 0, watts: 0, memBytes: 0, front: false)
            if let q = lastProc[pid], q.start == p.start {
                a.cpu += Double(p.cpuNs &- q.cpuNs) * timebase / (dt * 1e9) * 100
                a.watts += Double(p.energyNj &- q.energyNj) / (dt * 1e9)
            }
            a.memBytes += p.mem
            if let fp = frontPath, key == fp { a.front = true }
            if let fpid = frontPID, pid == fpid { a.front = true }
            apps[key] = a
        }
        names = names.filter { procs[$0.key] != nil }

        // 표에 쓸 만큼만: CPU·전력·메모리 상위 6개씩
        let all = Array(apps.values)
        var keep: [String: Resource.App] = [:]
        for sort in [{ (a: Resource.App, b: Resource.App) in a.cpu > b.cpu }, { $0.watts > $1.watts }, { $0.memBytes > $1.memBytes }] {
            for a in all.sorted(by: sort).prefix(6) { keep[a.key] = a }
        }

        let own = ownUsage(procs, dt: dt, now: now)
        let bat = battery()
        return Resource.Sample(at: Date(), cpu: cpu, cores: ProcessInfo.processInfo.activeProcessorCount,
                               apps: keep.values.sorted { $0.cpu > $1.cpu }, memUsed: 100 - Double(sysctlInt("kern.memorystatus_level") ?? 100),
                               pressure: [1: 0, 2: 1, 4: 2][sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1] ?? 0,
                               swapBytes: swapUsed(), thermal: ProcessInfo.processInfo.thermalState.rawValue,
                               battery: bat, watts: bat?.onBattery == true ? batteryWatts() : nil, gpu: discreteGPU(),
                               everyApp: apps, own: own)
    }

    // MARK: 묘전트 자신

    private func ownUsage(_ procs: [pid_t: Proc], dt: TimeInterval, now: TimeInterval) -> Resource.Own {
        var parents: [Int32: Int32] = [:]
        var helpers: [Int32: Resource.OwnPart] = [:]
        for (pid, p) in procs {
            if lineage[pid]?.start != p.start { lineage[pid] = (p.start, Self.parent(pid), Self.helper(pid)) }
            parents[pid] = lineage[pid]?.parent
            if let h = lineage[pid]?.helper { helpers[pid] = h }
        }
        lineage = lineage.filter { procs[$0.key] != nil }
        let members = Resource.ownMembers(root: getpid(), helpers: helpers, parents: parents)
        ownPids = Set(members.keys)

        var o = Resource.Own(cpu: 0, memBytes: 0, readRate: 0, writeRate: 0, readTotal: 0, writeTotal: 0, processes: members.count, parts: [])
        var parts: [Resource.OwnPart: Resource.OwnPartUsage] = [:]
        for (pid, part) in members {
            guard let p = procs[pid] else { continue }
            var u = parts[part] ?? Resource.OwnPartUsage(part: part, cpu: 0, memBytes: 0)
            if let q = lastProc[pid], q.start == p.start {
                u.cpu += Double(p.cpuNs &- q.cpuNs) * timebase / (dt * 1e9) * 100
                o.readRate += Double(p.diskRead &- q.diskRead) / dt
                o.writeRate += Double(p.diskWrite &- q.diskWrite) / dt
            }
            u.memBytes += p.mem
            o.readTotal += p.diskRead
            o.writeTotal += p.diskWrite
            parts[part] = u
        }
        o.parts = Resource.OwnPart.allCases.compactMap { parts[$0] }
        o.cpu = o.parts.reduce(0) { $0 + $1.cpu }
        o.memBytes = o.parts.reduce(0) { $0 + $1.memBytes }

        if net != nil {
            if now - dataMeasuredAt >= 60, let dir = dataDir {   // 열어 둔 동안 1분에 한 번만
                dataBytes = Self.folderSize(dir)
                dataMeasuredAt = now
            }
        }
        o.net = net
        o.dataBytes = dataBytes
        return o
    }

    func setNet(on: Bool) {
        net = on ? Resource.OwnNet() : nil
        netIn = 0; netOut = 0; netBatches = 0
    }

    func netFailed() {
        guard net != nil else { return }
        net?.failed = true
    }

    /// 한 번 재기가 끝났을 때: 그동안의 평균을 다음 결과까지 보여 준다
    func netRunEnded(seconds: Double) {
        guard var n = net else { return }
        n.inRate = Double(netIn) / seconds
        n.outRate = Double(netOut) / seconds
        n.inTotal += netIn
        n.outTotal += netOut
        netIn = 0; netOut = 0; netBatches = 0
        net = n
    }

    /// nettop 첫 묶음은 이미 쌓인 값이라 버리고, 그 뒤 묶음(직전과의 차이)만 더한다
    func netLine(_ line: String) {
        guard net != nil else { return }
        if line.hasPrefix(",") { netBatches += 1; return }
        guard netBatches >= 2, let r = Resource.nettopLine(line), ownPids.contains(r.pid) else { return }
        netIn += r.input
        netOut += r.output
    }

    private static func parent(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
    }

    /// python 프로세스만 실행 인자를 읽어 브레인·말하는 고양이인지 본다
    private static func helper(_ pid: pid_t) -> Resource.OwnPart? {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, 256)
        guard String(cString: buf).lowercased().hasPrefix("python") else { return nil }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var raw = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &raw, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = raw.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc, 실행 파일 경로, 0들, 인자들, 환경 변수 순서. 환경 변수는 보지 않는다
        let strings = raw[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Resource.helperPart(args: Array(strings.prefix(Int(argc) + 1)))
    }

    private static func folderSize(_ dir: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func cpuTicks() -> [UInt32] {
        var c = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &c) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) }
        }
        // CPU_STATE_USER, SYSTEM, IDLE, NICE
        return [c.cpu_ticks.0, c.cpu_ticks.1, c.cpu_ticks.2, c.cpu_ticks.3]
    }

    private struct Proc { var start: UInt64; var cpuNs: UInt64; var energyNj: UInt64; var mem: UInt64; var diskRead: UInt64; var diskWrite: UInt64 }

    /// 읽을 수 있는 프로세스(내 사용자 것)의 누적 CPU 시간·에너지·메모리
    private func processes() -> [pid_t: Proc] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        var out: [pid_t: Proc] = [:]
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var r = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &r) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }
            out[pid] = Proc(start: r.ri_proc_start_abstime, cpuNs: r.ri_user_time + r.ri_system_time,
                            energyNj: r.ri_energy_nj, mem: r.ri_phys_footprint,
                            diskRead: r.ri_diskio_bytesread, diskWrite: r.ri_diskio_byteswritten)
        }
        return out
    }

    /// pid → (앱 경로, 보이는 이름). 같은 pid 라도 시작 시각이 다르면 다른 프로세스다
    private func owner(_ pid: pid_t, start: UInt64) -> (String, String) {
        if let c = names[pid], c.start == start { return (c.key, c.name) }
        let who = Self.responsible?(pid) ?? pid
        var key: String, name: String
        if let path = Self.path(who > 0 ? who : pid), let r = path.range(of: ".app/") {
            key = String(path[..<r.lowerBound]) + ".app"
            name = FileManager.default.displayName(atPath: key).replacingOccurrences(of: ".app", with: "")
        } else {
            var buf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buf, 256)
            name = String(cString: buf)
            key = name.isEmpty ? "pid:\(pid)" : name
            if name.isEmpty { name = "pid \(pid)" }
        }
        names[pid] = (start, key, name)
        return (key, name)
    }

    private static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    private func swapUsed() -> UInt64 {
        var s = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 ? s.xsu_used : 0
    }

    /// 내장 배터리가 없으면 (데스크톱 맥) nil
    private func battery() -> Resource.Battery? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        for src in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let left = d[kIOPSTimeToEmptyKey] as? Int
            return Resource.Battery(percent: cur * 100 / max, onBattery: onBattery, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                    minutesLeft: onBattery && (left ?? 0) > 0 ? left : nil,
                                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        return nil
    }

    /// 배터리에서 지금 끌어 쓰는 전력 (mA × mV)
    private func batteryWatts() -> Double? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        func num(_ k: String) -> NSNumber? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber }
        guard let a = num("InstantAmperage"), let v = num("Voltage") else { return nil }
        let mA = abs(Double(Int32(truncatingIfNeeded: a.int64Value)))
        return mA * v.doubleValue / 1e6
    }

    /// 따로 단 GPU(AMD·NVIDIA·인텔·eGPU)의 사용률. Apple 칩 내장 GPU(AGX…)는 보지 않는다
    private func discreteGPU() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(s, &cls)
            guard !String(cString: cls).hasPrefix("AGX"),
                  let st = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let u = (st["Device Utilization %"] ?? st["GPU Activity(%)"]) as? NSNumber else { continue }
            best = max(best ?? 0, u.doubleValue)
        }
        return best
    }
}
