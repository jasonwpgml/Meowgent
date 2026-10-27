import AVFoundation
import Speech

/// 마이크로 한국어를 받아 적는다. 오디오는 맥 밖으로 나가지 않고, 받아 적은 글만 대화로 간다.
///  - macOS 26+: SpeechAnalyzer + SpeechTranscriber (기기 안, 받아 적는 중인 글도 실시간)
///  - 그 이전: SFSpeechRecognizer 기기 안 인식
/// 콜백은 모두 메인 스레드에서 부른다.
final class MindVoice {
    var onText: ((String) -> Void)?             // 지금까지 받아 적은 글 (확정 + 받아 적는 중)
    var onFinish: ((String?) -> Void)?          // 끝: 최종 글, 실패하면 nil
    var onError: ((String) -> Void)?
    /// 인식에 힌트로 주는 말 (고양이 이름, 프로젝트 이름 등)
    var hints: [String] = []

    private(set) var listening = false
    private let engine = AVAudioEngine()
    private var session: VoiceSession?

    static let locale = Locale(identifier: "ko-KR")

    func start() {
        guard !listening else { return }
        listening = true
        Self.askMicrophone { [weak self] ok in
            guard let self, self.listening else { return }
            guard ok else {
                self.fail("마이크 권한이 없다냥. 시스템 설정 › 개인정보 보호 › 마이크에서 Meowgent 를 켜 줘라냥.")
                return
            }
            let s: VoiceSession
            if #available(macOS 26, *) {
                // SpeechAnalyzer 가 마이크 입력에 음성 인식 권한을 요구하는지 문서로 확인되지 않아 처음 한 번 같이 묻는다
                if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
                s = AnalyzerSession(hints: self.hints)
            } else {
                s = RecognizerSession()
            }
            s.onText = { [weak self] t in DispatchQueue.main.async { self?.onText?(t) } }
            self.session = s
            s.begin(engine: self.engine) { [weak self] err in
                DispatchQueue.main.async { if let err { self?.fail(err) } }
            }
        }
    }

    /// 말을 마쳤다: 남은 소리를 마저 받아 적고 onFinish
    func stop() {
        guard listening else { return }
        listening = false
        stopEngine()
        guard let s = session else { onFinish?(nil); return }
        session = nil
        s.end { [weak self] text in DispatchQueue.main.async { self?.onFinish?(text) } }
    }

    func cancel() {
        listening = false
        stopEngine()
        session?.cancel()
        session = nil
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func fail(_ msg: String) {
        Log.write("음성 입력 실패: \(msg)")
        cancel()
        onError?(msg)
        onFinish?(nil)
    }

    private static func askMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// 마이크 버퍼를 탭으로 받아 넘긴다 (형식은 마이크 그대로)
    fileprivate static func tap(_ engine: AVAudioEngine, _ each: @escaping (AVAudioPCMBuffer) -> Void) throws -> AVAudioFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "MindVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크를 찾지 못했다냥."]) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buf, _ in each(buf) }
        engine.prepare()
        try engine.start()
        return format
    }
}

private protocol VoiceSession: AnyObject {
    var onText: ((String) -> Void)? { get set }
    func begin(engine: AVAudioEngine, failed: @escaping (String?) -> Void)
    func end(_ done: @escaping (String?) -> Void)
    func cancel()
}

// MARK: macOS 26+: SpeechAnalyzer

@available(macOS 26, *)
private final class AnalyzerSession: VoiceSession {
    var onText: ((String) -> Void)?
    private let hints: [String]
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var reader: Task<Void, Never>?
    private var confirmed = ""
    private var volatile = ""
    private var stopped = false   // 준비가 끝나기 전에 그만두면 마이크를 열지 않는다

    init(hints: [String]) { self.hints = hints }

    func begin(engine: AVAudioEngine, failed: @escaping (String?) -> Void) {
        Task {
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: MindVoice.locale) else {
                    return failed("이 맥은 한국어 받아 적기를 지원하지 않는다냥.")
                }
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
                if !(await SpeechTranscriber.installedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }),
                   let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()   // 한국어 모델이 없으면 한 번 내려받는다
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                if !hints.isEmpty {
                    let ctx = AnalysisContext()
                    ctx.contextualStrings[.general] = hints
                    try? await analyzer.setContext(ctx)
                }
                guard let want = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    return failed("받아 적기 형식을 정하지 못했다냥.")
                }
                try await analyzer.prepareToAnalyze(in: want)
                self.analyzer = analyzer
                self.reader = Task {
                    do {
                        for try await r in transcriber.results {
                            let t = String(r.text.characters)
                            if r.isFinal { self.confirmed += t; self.volatile = "" } else { self.volatile = t }
                            self.onText?(self.text)
                        }
                    } catch {
                        Log.write("받아 적기 결과 오류: \(error)")
                    }
                }
                guard !self.stopped else { return failed(nil) }
                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
                self.input = cont
                var converter: AVAudioConverter?
                let mic = try MindVoice.tap(engine) { buf in
                    if converter == nil { converter = AVAudioConverter(from: buf.format, to: want) }
                    guard let c = converter, let out = Self.convert(buf, with: c, to: want) else { return }
                    cont.yield(AnalyzerInput(buffer: out))
                }
                Log.write("음성 입력 시작 (SpeechTranscriber \(locale.identifier), 마이크 \(Int(mic.sampleRate))Hz → \(Int(want.sampleRate))Hz)")
                try await analyzer.start(inputSequence: stream)
                failed(nil)
            } catch {
                failed(self.stopped ? nil : "받아 적기를 시작하지 못했다냥: \(error.localizedDescription)")
            }
        }
    }

    private var text: String { (confirmed + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    func end(_ done: @escaping (String?) -> Void) {
        stopped = true
        guard let input else { return done(nil) }
        input.finish()
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await reader?.value
            done(text)
        }
    }

    func cancel() {
        stopped = true
        input?.finish()
        reader?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private static func convert(_ buf: AVAudioPCMBuffer, with c: AVAudioConverter, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buf.format == fmt { return buf }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        c.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buf
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

// MARK: macOS 14~25: SFSpeechRecognizer 기기 안 인식

private final class RecognizerSession: VoiceSession {
    var onText: ((String) -> Void)?
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished: ((String?) -> Void)?

    func begin(engine: AVAudioEngine, failed: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else { return failed("음성 인식 권한이 없다냥. 시스템 설정 › 개인정보 보호 › 음성 인식에서 켜 줘라냥.") }
                guard let rec = SFSpeechRecognizer(locale: MindVoice.locale), rec.isAvailable else { return failed("한국어 음성 인식을 쓸 수 없다냥.") }
                self.request.shouldReportPartialResults = true
                self.request.addsPunctuation = true
                if rec.supportsOnDeviceRecognition { self.request.requiresOnDeviceRecognition = true }
                self.task = rec.recognitionTask(with: self.request) { [weak self] result, error in
                    guard let self else { return }
                    if let result {
                        self.latest = result.bestTranscription.formattedString
                        self.onText?(self.latest)
                    }
                    if result?.isFinal == true || error != nil {
                        self.finished?(self.latest)
                        self.finished = nil
                    }
                }
                do {
                    _ = try MindVoice.tap(engine) { [weak self] buf in self?.request.append(buf) }
                    Log.write("음성 입력 시작 (SFSpeechRecognizer, 기기 안 \(rec.supportsOnDeviceRecognition))")
                    failed(nil)
                } catch {
                    failed("마이크를 열지 못했다냥: \(error.localizedDescription)")
                }
            }
        }
    }

    func end(_ done: @escaping (String?) -> Void) {
        finished = done
        request.endAudio()
        // 결과가 끝내 안 오면 지금까지 들은 것으로
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let f = self.finished else { return }
            self.finished = nil
            f(self.latest)
        }
    }

    func cancel() { task?.cancel() }
}
