import Foundation
import Combine
import Speech
import AVFoundation

class WakeWordManager: ObservableObject {

    @Published var isListening = false
    @Published var transcript = ""
    @Published var wakeWord: String {
        didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord") }
    }
    @Published var wakeWord2: String {
        didSet { UserDefaults.standard.set(wakeWord2, forKey: "wakeWord2") }
    }

    private static let speechLocale: Locale = {
        let supported = SFSpeechRecognizer.supportedLocales()
        if let pref = Locale.preferredLanguages.first {
            let prefLocale = Locale(identifier: pref)
            if supported.contains(prefLocale) { return prefLocale }
            if let langCode = prefLocale.language.languageCode?.identifier,
               let match = supported.first(where: { $0.language.languageCode?.identifier == langCode }) {
                return match
            }
        }
        return Locale(identifier: "en-US")
    }()

    private let recognizer = SFSpeechRecognizer(locale: WakeWordManager.speechLocale)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var windowTimer: Timer?
    private var isRestarting = false
    private var onWake: ((Int) -> Void)?

    init() {
        self.wakeWord = UserDefaults.standard.string(forKey: "wakeWord") ?? "블루"
        self.wakeWord2 = UserDefaults.standard.string(forKey: "wakeWord2") ?? "라이브블루"
        dlog("WakeWordManager init, wakeWord=\(self.wakeWord) wakeWord2=\(self.wakeWord2) locale=\(WakeWordManager.speechLocale.identifier)")
    }

    private var candidates: [String] {
        let base = wakeWord.lowercased()
        return [base, "hey \(base)", "하이 \(base)", "이봐 \(base)"]
    }

    private var candidates2: [String] {
        let base = wakeWord2.lowercased()
        return [base, "hey \(base)", "하이 \(base)", "이봐 \(base)"]
    }

    // MARK: - 공개 인터페이스

    func start(onWake: @escaping (Int) -> Void) {
        dlog("WakeWord.start wakeWord=\(wakeWord) wakeWord2=\(wakeWord2)")
        self.onWake = onWake
        isRestarting = false
        isListening = true
        startWindow()
    }

    func stop() {
        dlog("WakeWord.stop")
        isListening = false
        isRestarting = false
        windowTimer?.invalidate()
        windowTimer = nil
        teardownEngine()
    }

    // MARK: - 8초 인식 창 반복

    private func startWindow() {
        guard isListening, !isRestarting else {
            dlog("WakeWord.startWindow skip isListening=\(isListening) isRestarting=\(isRestarting)")
            return
        }
        dlog("WakeWord.startWindow")

        // 엔진이 꺼진 경우에만 세션·엔진 초기화
        if !audioEngine.isRunning {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
                try session.setActive(true)
            } catch {
                dlog("WakeWord audioSession error: \(error)")
                scheduleRestart(after: 1.0)
                return
            }

            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            // [weak self] 캡처 — 새 recognitionRequest로 자동 전달됨
            inputNode.installTap(onBus: 0, bufferSize: 1024,
                                 format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                dlog("WakeWord audioEngine error: \(error)")
                audioEngine.inputNode.removeTap(onBus: 0)
                scheduleRestart(after: 1.0)
                return
            }
        }

        // 매 창마다 인식 태스크만 교체 (엔진 유지)
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let text = result?.bestTranscription.formattedString.lowercased() {
                DispatchQueue.main.async {
                    if text != self.transcript { self.transcript = text }
                }
                dlog("WakeWord heard: \(text)")
                if self.candidates2.contains(where: { text.contains($0) }) {
                    dlog("WakeWord2 TRIGGERED by: \(text)")
                    DispatchQueue.main.async { self.triggerWake(index: 1) }
                    return
                }
                if self.candidates.contains(where: { text.contains($0) }) {
                    dlog("WakeWord TRIGGERED by: \(text)")
                    DispatchQueue.main.async { self.triggerWake(index: 0) }
                    return
                }
            }

            if let error {
                let code = (error as NSError).code
                if code == 301 {
                    // 우리가 직접 취소 — 재시작 이미 예약됨, 아무것도 하지 않음
                } else if code == 1110 {
                    // 묵음 — 조용히 재시작
                    DispatchQueue.main.async { self.scheduleRestart(after: 0.3) }
                } else {
                    dlog("WakeWord STT error code=\(code): \(error.localizedDescription)")
                    DispatchQueue.main.async { self.scheduleRestart(after: 0.5) }
                }
            } else if result?.isFinal == true {
                dlog("WakeWord isFinal → restart")
                DispatchQueue.main.async { self.scheduleRestart(after: 0.1) }
            }
        }

        windowTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            dlog("WakeWord 8s window expired")
            self?.scheduleRestart(after: 0.2)
        }
    }

    private func triggerWake(index: Int) {
        dlog("WakeWord.triggerWake index=\(index)")
        windowTimer?.invalidate()
        windowTimer = nil
        // 엔진 정지, 세션 유지 — SpeechManager가 이어서 사용
        stopEngine(deactivateSession: false)
        isListening = false
        isRestarting = false
        onWake?(index)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard isListening, !isRestarting else { return }
        isRestarting = true
        dlog("WakeWord.scheduleRestart after=\(delay)")
        windowTimer?.invalidate()
        windowTimer = nil
        // 인식 태스크만 취소, 엔진·세션 유지
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isRestarting = false
            self?.startWindow()
        }
    }

    private func stopEngine(deactivateSession: Bool) {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func teardownEngine() {
        stopEngine(deactivateSession: true)
    }
}
