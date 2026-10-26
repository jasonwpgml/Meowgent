// SPDX-FileCopyrightText: 2026 JSonJh

import Foundation

/// 에이전트 사용 한도(5시간·주간·월)와 리셋권을 보고 "놓치고 있는 것"을 고른다.
/// 파일·화면을 건드리지 않는 순수 로직이라 Tests/logic 에서 그대로 점검한다.
///
/// 알림 원칙 (docs/REMINDERS.md):
///  - 창(window)·단계마다 한 번만. 같은 내용을 두 번 말하지 않는다.
///  - 바로 말할 것(바닥남·리셋권 하루 안 만료)만 급함. 나머지는 하루 한 번 "오늘 챙길 것"에 모은다.
///  - 데이터가 오래됐으면(6시간+) 사용률 기반 알림은 하지 않는다.
enum Quota {
    struct Window {
        var provider: String          // codex · claude · cursor · grok
        var name: String              // 말풍선 이름: "Codex 주간"
        var key: String               // 계정·창 구분 (중복 알림 방지)
        var usedPercent: Double
        var minutes: Int              // 300 = 5시간, 10080 = 주간, 43200 = 월
        var resetsAt: Date
        var capturedAt: Date
        var account: String? = nil    // 같은 계정의 리셋권을 찾을 때

        var isLong: Bool { minutes >= 24 * 60 }
        var isMonthly: Bool { minutes >= 20 * 24 * 60 }
    }

    struct Credit {
        var provider: String
        var account: String
        var accountLabel: String?     // 계정이 여럿일 때만 붙인다
        var id: String
        var title: String             // "전체 재설정(주간 + 5시간)"
        var grantedAt: Date
        var expiresAt: Date
        var capturedAt: Date
    }

    struct Reminder: Equatable {
        let key: String               // 이 키로 한 번만 말한다
        let text: String
        let urgent: Bool
        let validUntil: Date          // 이 시각이 지나면 말해 봐야 소용없다
        let rank: Int                 // 낮을수록 먼저
    }

    static let staleAfter: TimeInterval = 6 * 3600

    // MARK: 규칙

    /// previous: 지난번에 본 같은 키의 창 (리셋을 놓치지 않으려고)
    static func reminders(windows: [Window], credits: [Credit], previous: [String: Window] = [:],
                          now: Date, cal: Calendar) -> [Reminder] {
        var out: [Reminder] = []
        let live = credits.filter { $0.expiresAt > now }

        for w in windows {
            let resetTs = Int(w.resetsAt.timeIntervalSince1970)
            let remain = w.resetsAt.timeIntervalSince(now)
            let left = max(0, 100 - w.usedPercent)
            let mine = live.filter { $0.provider == w.provider && (w.account == nil || $0.account == w.account) }

            // 1) 리셋됐다: 많이 쓰던 창이 다시 채워졌을 때 (시각이 지났거나, 새 창으로 바뀐 걸 봤을 때)
            if remain <= 0, remain > -3 * 3600, w.usedPercent >= 80 {
                out.append(Reminder(key: "\(w.key):\(resetTs):reset", text: "✅ \(w.name) 한도 다시 찼다냥. 이제 마음껏 써도 된다냥.",
                                    urgent: false, validUntil: w.resetsAt.addingTimeInterval(3 * 3600), rank: 2))
            }
            if let p = previous[w.key], p.resetsAt < w.resetsAt.addingTimeInterval(-600), p.usedPercent >= 80,
               w.usedPercent < p.usedPercent, now.timeIntervalSince(p.resetsAt) < 3 * 3600 {
                let pTs = Int(p.resetsAt.timeIntervalSince1970)
                out.append(Reminder(key: "\(w.key):\(pTs):reset", text: "✅ \(w.name) 한도 다시 찼다냥. 이제 마음껏 써도 된다냥.",
                                    urgent: false, validUntil: now.addingTimeInterval(3 * 3600), rank: 2))
            }

            guard remain > 0, now.timeIntervalSince(w.capturedAt) < staleAfter else { continue }
            let when = whenText(w.resetsAt, now: now, cal: cal)
            let rel = relText(remain)

            // 2) 바닥난다: 단계별로 한 번 (가장 높은 단계만)
            let steps: [Double] = w.isLong ? [80, 90, 95, 100] : [90, 100]
            if let step = steps.last(where: { w.usedPercent >= $0 }) {
                let hint = mine.isEmpty || step < 90 ? "" : "\n🎟️ 리셋권 \(mine.count)장 있다냥 (쓰면 바로 풀린다냥)"
                let text = step >= 100
                    ? "⛔ \(w.name) 한도 다 썼다냥. \(rel) 뒤(\(when))에 풀린다냥. 조금만 기다리자냥\(hint)"
                    : "\(w.name) 한도 \(Int(w.usedPercent))% 썼다냥 · \(rel) 뒤(\(when)) 리셋\(hint)"
                out.append(Reminder(key: "\(w.key):\(resetTs):high\(Int(step))", text: text,
                                    urgent: step >= 90, validUntil: w.resetsAt, rank: 0))
            }

            guard w.isLong else { continue }

            // 3) 이 속도면 리셋 전에 바닥난다 (창의 30% 이상 지났고, 리셋 12시간 이상 전에 바닥날 때)
            if let out100 = exhaustAt(w, now: now), w.usedPercent < 80, w.usedPercent >= 10,
               out100 < w.resetsAt.addingTimeInterval(-12 * 3600) {
                let hint = mine.isEmpty ? "" : "\n🎟️ 리셋권 \(mine.count)장 있으니 바닥나면 그때 쓰자냥"
                out.append(Reminder(key: "\(w.key):\(resetTs):pace", text: "📈 이 속도면 \(w.name) 한도가 \(whenText(out100, now: now, cal: cal))쯤 바닥난다냥 (리셋은 \(when))\(hint)",
                                    urgent: false, validUntil: out100, rank: 1))
            }

            // 4) 남는다: 리셋이 가까운데 많이 남았을 때 ("안 쓰면 사라짐")
            let wasteStep: String?
            if w.isMonthly {
                wasteStep = remain <= 24 * 3600 && left >= 30 ? "d1" : (remain <= 3 * 86400 && left >= 50 ? "d3" : nil)
            } else {
                // 이번 창에 손도 안 댄 서비스는 "하루 전" 한 번만
                let touched = w.usedPercent >= 1
                wasteStep = touched && remain <= 6 * 3600 && left >= 25 ? "h6" : (remain <= 24 * 3600 && left >= 40 ? "d1" : nil)
            }
            if let s = wasteStep {
                out.append(Reminder(key: "\(w.key):\(resetTs):waste-\(s)",
                                    text: "⏳ \(w.name) \(Int(left))% 남았는데 \(rel) 뒤(\(when)) 리셋된다냥. 남기면 아깝다냥. 큰 일은 지금 맡기자냥",
                                    urgent: false, validUntil: w.resetsAt, rank: 3))
            }
        }

        // 5) 리셋권: 새로 받음 / 만료 7일·3일·하루·3시간 전
        for c in live {
            let remain = c.expiresAt.timeIntervalSince(now)
            let who = c.accountLabel.map { "(\($0)) " } ?? ""
            let asOf = now.timeIntervalSince(c.capturedAt) > 24 * 3600 ? " (\(dayText(c.capturedAt, cal: cal)) 기준)" : ""
            let name = providerName(c.provider)
            if now.timeIntervalSince(c.grantedAt) < 3 * 86400, remain > 7 * 86400 {
                let n = live.filter { $0.provider == c.provider && $0.account == c.account }.count
                out.append(Reminder(key: "credit:\(c.id):new", text: "🎟️ \(name) 리셋권 새로 받았다냥 \(who)· \(whenText(c.expiresAt, now: now, cal: cal)) 만료 · 지금 \(n)장",
                                    urgent: false, validUntil: c.grantedAt.addingTimeInterval(3 * 86400), rank: 4))
            }
            let step: String? = remain <= 3 * 3600 ? "h3" : remain <= 86400 ? "d1" : remain <= 3 * 86400 ? "d3" : remain <= 7 * 86400 ? "d7" : nil
            guard let step else { continue }
            let weekly = windows.first { $0.provider == c.provider && ($0.account == nil || $0.account == c.account) && $0.isLong && $0.resetsAt > now
                && now.timeIntervalSince($0.capturedAt) < 24 * 3600 }
            let advice: String
            if let w = weekly, w.usedPercent >= 30 {
                advice = "지금 \(w.name) \(Int(w.usedPercent))% 썼으니 지금 쓰면 그만큼 돌려받는다냥"
            } else if let w = weekly, w.resetsAt < c.expiresAt {
                advice = "\(w.name) 리셋(\(whenText(w.resetsAt, now: now, cal: cal))) 전에 많이 쓴 날 쓰자냥"
            } else {
                advice = "만료 전에 한도 많이 쓴 날 쓰자냥. 그냥 날리면 아깝다냥"
            }
            out.append(Reminder(key: "credit:\(c.id):\(step)",
                                text: "🎟️ \(name) 리셋권 \(who)\(relText(remain)) 뒤(\(whenText(c.expiresAt, now: now, cal: cal))) 만료다냥\(asOf)\n\(advice)",
                                urgent: step == "h3" || step == "d1", validUntil: c.expiresAt, rank: step == "h3" || step == "d1" ? 0 : 3))
        }
        return out.sorted { ($0.urgent ? 0 : 1, $0.rank) < ($1.urgent ? 0 : 1, $1.rank) }
    }

    /// 지금까지의 평균 속도로 쓰면 언제 100%가 되나 (창의 30% 이상 지났을 때만)
    static func exhaustAt(_ w: Window, now: Date) -> Date? {
        let length = Double(w.minutes) * 60
        let elapsed = length - w.resetsAt.timeIntervalSince(now)
        guard length > 0, elapsed >= length * 0.3, w.usedPercent > 0, w.usedPercent < 100 else { return nil }
        let rate = w.usedPercent / elapsed
        return now.addingTimeInterval((100 - w.usedPercent) / rate)
    }

    // MARK: 하루 한 번 브리핑 · 메뉴 요약

    /// "오늘 챙길 것": 긴 창(주간·월)과 리셋권. 챙길 게 없으면 nil
    static func digest(windows: [Window], credits: [Credit], now: Date, cal: Calendar) -> String? {
        var lines: [String] = []
        let fresh = windows.filter { $0.resetsAt > now && now.timeIntervalSince($0.capturedAt) < staleAfter }
        for w in fresh.filter({ $0.isLong }).sorted(by: { $0.resetsAt < $1.resetsAt }) {
            let left = max(0, 100 - w.usedPercent)
            let days = w.resetsAt.timeIntervalSince(now) / 86400
            var line = "· \(w.name) \(Int(left))% 남음 · \(whenText(w.resetsAt, now: now, cal: cal)) 리셋"
            if let e = exhaustAt(w, now: now), e < w.resetsAt {
                line += "\n   이 속도면 \(whenText(e, now: now, cal: cal))쯤 바닥"
            } else if left >= 30, w.usedPercent >= 1, days >= 1 {
                line += "\n   하루 \(Int((left / days).rounded()))%씩 쓰면 딱 맞다냥"
            }
            lines.append(line)
        }
        for w in fresh.filter({ !$0.isLong && $0.usedPercent >= 80 }) {
            lines.append("· \(w.name) \(Int(w.usedPercent))% 씀 · \(whenText(w.resetsAt, now: now, cal: cal)) 리셋")
        }
        let live = credits.filter { $0.expiresAt > now }.sorted { $0.expiresAt < $1.expiresAt }
        for group in Dictionary(grouping: live, by: { "\($0.provider)|\($0.account)" }).values.sorted(by: { $0[0].expiresAt < $1[0].expiresAt }) {
            let c = group[0]
            let who = c.accountLabel.map { "(\($0)) " } ?? ""
            lines.append("· 🎟️ \(providerName(c.provider)) 리셋권 \(who)\(group.count)장 · 가장 빠른 만료 \(whenText(c.expiresAt, now: now, cal: cal))")
        }
        return lines.isEmpty ? nil : "☀️ 오늘 챙길 것\n" + lines.joined(separator: "\n")
    }

    /// 메뉴·마우스 올림용 짧은 줄들
    static func summaryLines(windows: [Window], credits: [Credit], now: Date, cal: Calendar) -> [String] {
        var lines: [String] = []
        let shown = windows.filter { $0.resetsAt > now && now.timeIntervalSince($0.capturedAt) < 24 * 3600 }
        for w in shown.sorted(by: { ($0.provider, $0.minutes) < ($1.provider, $1.minutes) }) {
            let stale = now.timeIntervalSince(w.capturedAt) >= staleAfter ? " (오래된 값)" : ""
            lines.append("⏳ \(w.name) \(Int(w.usedPercent))% · \(whenText(w.resetsAt, now: now, cal: cal)) 리셋\(stale)")
        }
        let live = credits.filter { $0.expiresAt > now }.sorted { $0.expiresAt < $1.expiresAt }
        for group in Dictionary(grouping: live, by: { "\($0.provider)|\($0.account)" }).values.sorted(by: { $0[0].expiresAt < $1[0].expiresAt }) {
            let c = group[0]
            let who = c.accountLabel.map { "(\($0)) " } ?? ""
            lines.append("🎟️ \(providerName(c.provider)) 리셋권 \(who)\(group.count)장 · \(whenText(c.expiresAt, now: now, cal: cal)) 만료")
        }
        return lines
    }

    // MARK: 이름 · 시각 글자

    static func providerName(_ p: String) -> String {
        ["codex": "Codex", "claude": "Claude", "cursor": "Cursor", "grok": "Grok"][p] ?? p.capitalized
    }

    static func periodName(_ minutes: Int) -> String {
        if minutes <= 0 { return "" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분" }
        if minutes >= 20 * 24 * 60 { return "월" }
        if minutes >= 6 * 24 * 60 { return "주간" }
        return "\(minutes / (24 * 60))일"
    }

    /// "3시간 12분", "2일 4시간", "40분"
    static func relText(_ s: TimeInterval) -> String {
        let m = max(1, Int((s / 60).rounded()))
        if m < 60 { return "\(m)분" }
        if m < 24 * 60 { return m % 60 == 0 || m >= 6 * 60 ? "\(m / 60)시간" : "\(m / 60)시간 \(m % 60)분" }
        let h = m / 60
        return h % 24 == 0 ? "\(h / 24)일" : "\(h / 24)일 \(h % 24)시간"
    }

    /// "오늘 오후 3:44", "내일 오전 1:13", "목 오후 3:44", "10/30(금) 오전 1:34"
    static func whenText(_ d: Date, now: Date, cal: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = cal.timeZone
        f.dateFormat = "a h:mm"
        let time = f.string(from: d)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99
        switch days {
        case 0: return "오늘 " + time
        case 1: return "내일 " + time
        case 2...6: f.dateFormat = "E"; return f.string(from: d) + " " + time
        default: return dayText(d, cal: cal) + " " + time
        }
    }

    /// "10/30(금)"
    static func dayText(_ d: Date, cal: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = cal.timeZone
        f.dateFormat = "M/d(E)"
        return f.string(from: d)
    }
}
