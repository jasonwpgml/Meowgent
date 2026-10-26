import Foundation

/// 지금 활성 문맥. 메인 스레드가 갱신하고, 클릭 해석·저장 큐 등 다른 스레드가 읽는다.
struct Snapshot {
    var app: String?
    var bundle: String?
    var pid: Int32?
    var window: String?
    var url: String?
    var appBlocked = false
    var urlBlocked = false
    var incognito = false
    var paused = false

    var blocked: Bool { appBlocked || urlBlocked || incognito }
}

final class Context {
    static let shared = Context()
    private let lock = NSLock()
    private var s = Snapshot()

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return s
    }

    func update(_ f: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        f(&s)
    }
}

struct Config: Codable {
    /// 내장 목록(Privacy.builtin…)에 더해 추가로 막을 앱 bundle id
    var blockedBundles: [String] = []
    /// 내장 목록에 더해 추가로 막을 도메인 (하위 도메인 포함)
    var blockedDomains: [String] = []
    /// 입력 텍스트를 읽지 않을 앱 (터미널은 화면 전체가 값이라 출력과 섞이고, 셸 기록이 따로 있음).
    var textSkipBundles: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty",
    ]
    /// 이 앱들에선 Enter가 "줄바꿈"이라 Enter로 커밋하지 않는다 (정지 시간으로만 커밋).
    var editorBundles: [String] = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed",
        "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.google.android.studio",
        "md.obsidian", "com.apple.TextEdit", "com.apple.Notes", "com.microsoft.Word", "com.apple.iWork.Pages",
    ]
    var captureClipboard = true
    /// 입력하다 이만큼 멈추면 저장 (AI 대화창은 Enter·입력창 이동 때만, 안전장치로 60초)
    var textIdlePauseSeconds = 8.0
    /// 복사·붙여넣기 내용 저장 길이
    var maxClipboardChars = 5000
    var afkSeconds = 180.0
    var maxTextChars = 4000
    var largeDocumentChars = 20000
    /// AI에게 질문한 뒤 화면에 나온 답변도 저장
    var captureAIResponses = true
    /// Claude·ChatGPT 데스크톱 앱의 답변도 저장할지 (대화 기록은 AI hub가 따로 모으므로 기본은 끔, 질문은 항상 저장)
    var aiResponsesFromDesktopApps = false
    var maxAIResponseChars = 30000

    init() {}

    /// 파일에 없는 키는 기본값을 쓴다 (설정 키가 늘어나도 기존 config.json이 깨지지 않게).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        blockedBundles = try c.decodeIfPresent([String].self, forKey: .blockedBundles) ?? d.blockedBundles
        blockedDomains = try c.decodeIfPresent([String].self, forKey: .blockedDomains) ?? d.blockedDomains
        textSkipBundles = try c.decodeIfPresent([String].self, forKey: .textSkipBundles) ?? d.textSkipBundles
        editorBundles = try c.decodeIfPresent([String].self, forKey: .editorBundles) ?? d.editorBundles
        captureClipboard = try c.decodeIfPresent(Bool.self, forKey: .captureClipboard) ?? d.captureClipboard
        textIdlePauseSeconds = try c.decodeIfPresent(Double.self, forKey: .textIdlePauseSeconds) ?? d.textIdlePauseSeconds
        maxClipboardChars = try c.decodeIfPresent(Int.self, forKey: .maxClipboardChars) ?? d.maxClipboardChars
        afkSeconds = try c.decodeIfPresent(Double.self, forKey: .afkSeconds) ?? d.afkSeconds
        maxTextChars = try c.decodeIfPresent(Int.self, forKey: .maxTextChars) ?? d.maxTextChars
        largeDocumentChars = try c.decodeIfPresent(Int.self, forKey: .largeDocumentChars) ?? d.largeDocumentChars
        captureAIResponses = try c.decodeIfPresent(Bool.self, forKey: .captureAIResponses) ?? d.captureAIResponses
        aiResponsesFromDesktopApps = try c.decodeIfPresent(Bool.self, forKey: .aiResponsesFromDesktopApps) ?? d.aiResponsesFromDesktopApps
        maxAIResponseChars = try c.decodeIfPresent(Int.self, forKey: .maxAIResponseChars) ?? d.maxAIResponseChars
    }

    static func load(dir: URL) -> Config {
        let url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url) {
            do {
                return try JSONDecoder().decode(Config.self, from: data)
            } catch {
                Log.write("config.json 해석 실패, 기본값 사용 (파일은 그대로 둠): \(error)")
                return Config()
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(Config()) { try? data.write(to: url) }
        return Config()
    }
}

/// 디스크에 쓰기 "전"에 거르는 프라이버시 규칙. 정규식 마스킹은 2차 방어일 뿐이다.
enum Privacy {
    static var config = Config()

    /// 항상 막는 앱 (config.json의 blockedBundles는 여기에 "추가"된다)
    static let builtinBlockedBundles: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]
    /// 항상 막는 도메인 (config.json의 blockedDomains는 여기에 "추가"된다)
    static let builtinBlockedDomains: [String] = [
        // 은행
        "kbstar.com", "shinhan.com", "wooribank.com", "hanabank.com", "ibk.co.kr", "nonghyup.com",
        "kakaobank.com", "tossbank.com", "kbanknow.com", "citibank.co.kr", "standardchartered.co.kr",
        "busanbank.co.kr", "knbank.co.kr", "imbank.co.kr", "dgb.co.kr", "kjbank.com", "jbbank.co.kr",
        "suhyup-bank.com", "epostbank.go.kr", "kfcc.co.kr", "cu.co.kr",
        // 증권·코인
        "kiwoom.com", "samsungpop.com", "miraeasset.com", "truefriend.com", "nhqv.com", "kbsec.com",
        "shinhansec.com", "hanaw.com", "daishin.com", "toss.im", "upbit.com", "bithumb.com", "coinone.co.kr", "korbit.co.kr",
        // 결제·카드
        "paypal.com", "pay.naver.com", "kakaopay.com", "payco.com",
        "shinhancard.com", "kbcard.com", "samsungcard.com", "hyundaicard.com", "lottecard.co.kr", "bccard.com", "hanacard.co.kr", "wooricard.com",
        // 공공·의료·계정
        "hometax.go.kr", "gov.kr", "nhis.or.kr", "nps.or.kr", "hira.or.kr",
        "accounts.google.com", "appleid.apple.com", "account.apple.com", "login.microsoftonline.com",
        "1password.com", "bitwarden.com", "lastpass.com",
        // 로그인·인증 화면
        "accounts.kakao.com", "kauth.kakao.com", "nid.naver.com", "auth.openai.com",
    ]

    static func isBlocked(bundle: String?) -> Bool {
        guard let bundle else { return false }
        return builtinBlockedBundles.contains(bundle) || config.blockedBundles.contains(bundle)
    }

    static func isBlocked(url: String?) -> Bool {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return false }
        return (builtinBlockedDomains + config.blockedDomains).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 주소에 붙은 로그인 코드·토큰·서명 같은 값을 가린다 (예: OAuth 로그인 후 ?code=…).
    private static let sensitiveParams: Set<String> = [
        "code", "token", "access_token", "id_token", "refresh_token", "auth", "authorization", "key", "api_key", "apikey",
        "secret", "client_secret", "password", "passwd", "pwd", "session", "sessionid", "session_id", "sid", "sig",
        "signature", "state", "ticket", "otp", "jwt", "x-amz-signature", "x-amz-credential", "x-amz-security-token",
        "auth_tran_id", "nonce", "assertion", "samlresponse",
    ]

    static func sanitize(url: String?) -> String? {
        guard let url, var c = URLComponents(string: url) else { return url }
        var changed = false
        if let items = c.queryItems {
            c.queryItems = items.map { item in
                if sensitiveParams.contains(item.name.lowercased()) || item.name.lowercased().hasSuffix("token") {
                    changed = true
                    return URLQueryItem(name: item.name, value: "REDACTED")
                }
                return item
            }
        }
        // 암묵적 OAuth 흐름은 #access_token=… 으로 온다
        if let f = c.fragment?.lowercased(), f.contains("token=") || f.contains("code=") {
            c.fragment = "REDACTED"
            changed = true
        }
        // 로그인 후 돌아갈 주소(continue=…) 안에 또 코드가 들어 있는 경우까지는 풀지 않고 통째로 가린다
        if let items = c.queryItems, items.contains(where: { ["continue", "redirect_uri", "returnurl", "return_to", "next"].contains($0.name.lowercased()) && ($0.value ?? "").count > 80 }) {
            c.queryItems = c.queryItems?.map { ["continue", "redirect_uri", "returnurl", "return_to", "next"].contains($0.name.lowercased()) ? URLQueryItem(name: $0.name, value: "REDACTED") : $0 }
            changed = true
        }
        return changed ? (c.string ?? url) : url
    }

    private static let patterns: [(String, NSRegularExpression)] = [
        ("private_key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
        ("api_key", #"\bsk-[A-Za-z0-9_\-]{20,}"#),
        ("github_token", #"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        ("aws_key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("slack_token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("google_key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("jwt", #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
        ("rrn", #"\b\d{6}-?[1-4]\d{6}\b"#),
        ("password", #"(?i)(password|passwd|pwd|비밀번호|비번)\s*[:=]\s*\S+"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    private static let cardPattern = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){13,19}\b"#)

    /// 마스킹된 문자열과 마스킹 여부.
    static func redact(_ input: String) -> (String, Bool) {
        var s = input
        var hit = false
        for (name, re) in patterns {
            let range = NSRange(s.startIndex..., in: s)
            if re.firstMatch(in: s, range: range) != nil {
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: "[REDACTED:\(name)]")
                hit = true
            }
        }
        // 카드번호: Luhn 검사를 통과하는 13~19자리만
        let ns = s as NSString
        for m in cardPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            if luhn(digits) {
                s = (s as NSString).replacingCharacters(in: m.range, with: "[REDACTED:card]")
                hit = true
            }
        }
        return (s, hit)
    }

    private static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static let aiDesktopApps: [String: String] = [
        "com.anthropic.claudefordesktop": "claude", "com.openai.chat": "chatgpt", "com.openai.codex": "chatgpt",
    ]

    /// 이 입력이 AI에게 보낸 질문인지: 웹 주소 또는 데스크톱 앱으로 판별. 아니면 nil.
    static func aiChat(url: String?, bundle: String?) -> String? {
        if let bundle, let name = aiDesktopApps[bundle] { return name }
        guard let url, let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return nil }
        if (host == "google.com" || host.hasSuffix(".google.com") || host.contains(".google.")) && comps.path.hasPrefix("/search"),
           comps.queryItems?.contains(where: { $0.name == "udm" && $0.value == "50" }) == true {
            return "google_ai_mode"
        }
        let sites: [(String, String)] = [
            ("gemini.google.com", "gemini"), ("aistudio.google.com", "gemini"), ("notebooklm.google.com", "notebooklm"),
            ("chatgpt.com", "chatgpt"), ("chat.openai.com", "chatgpt"), ("claude.ai", "claude"),
            ("perplexity.ai", "perplexity"), ("grok.com", "grok"), ("copilot.microsoft.com", "copilot"),
            ("chat.deepseek.com", "deepseek"), ("wrtn.ai", "wrtn"), ("clova-x.naver.com", "clova"),
        ]
        return sites.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }

    /// 검색 엔진 URL에서 검색어를 꺼낸다.
    static func searchQuery(from url: String) -> (engine: String, query: String)? {
        guard var comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return nil }
        // 폼 인코딩의 '+'는 공백 (URLComponents는 바꿔 주지 않는다)
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let path = comps.path
        let rules: [(host: String, path: String?, param: String, engine: String)] = [
            ("google.", "/search", "q", "google"),
            ("search.naver.com", nil, "query", "naver"),
            ("m.search.naver.com", nil, "query", "naver"),
            ("search.daum.net", nil, "q", "daum"),
            ("bing.com", "/search", "q", "bing"),
            ("duckduckgo.com", nil, "q", "duckduckgo"),
            ("youtube.com", "/results", "search_query", "youtube"),
            ("github.com", "/search", "q", "github"),
            ("perplexity.ai", "/search", "q", "perplexity"),
            ("namu.wiki", "/Search", "q", "namuwiki"),
            ("coupang.com", "/np/search", "q", "coupang"),
            ("amazon.", "/s", "k", "amazon"),
            ("stackoverflow.com", "/search", "q", "stackoverflow"),
            ("huggingface.co", "/search", "q", "huggingface"),
            ("x.com", "/search", "q", "x"),
            ("reddit.com", "/search", "q", "reddit"),
        ]
        for r in rules {
            let hostMatch = r.host.hasSuffix(".") ? (host.hasPrefix(r.host) || host.contains("." + r.host))
                                                  : (host == r.host || host.hasSuffix("." + r.host))
            guard hostMatch else { continue }
            if let p = r.path, !path.hasPrefix(p) { continue }
            if let q = comps.queryItems?.first(where: { $0.name == r.param })?.value, !q.isEmpty {
                // 구글 검색창의 "AI 모드"(udm=50)는 Gemini와 대화하는 것이라 따로 표시
                if r.engine == "google", comps.queryItems?.contains(where: { $0.name == "udm" && $0.value == "50" }) == true {
                    return ("google_ai_mode", q)
                }
                return (r.engine, q)
            }
        }
        return nil
    }
}
