import Foundation
import Combine
import Speech
import AVFoundation

class SpeechManager: ObservableObject {

    @Published var isListening = false
    @Published var transcript = ""

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

    private let recognizer = SFSpeechRecognizer(locale: SpeechManager.speechLocale)
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onFinal: ((String) -> Void)?
    private var silenceTimer: Timer?
    private var isRestarting = false

    // MARK: - 권한 요청

    func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        dlog("Speech permissions: mic=\(mic) speech=\(speech)")
        return mic && speech
    }

    // MARK: - 녹음 시작

    func start(onFinal: @escaping (String) -> Void) {
        dlog("Speech.start")
        self.onFinal = onFinal
        isRestarting = false
        beginSession()
    }

    func stop() {
        dlog("Speech.stop")
        silenceTimer?.invalidate()
        silenceTimer = nil
        isRestarting = false
        isListening = false
        transcript = ""
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 내부

    private func beginSession() {
        dlog("Speech.beginSession")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            dlog("Speech audioSession error: \(error)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.inputFormat(forBus: 0)
        dlog("Speech installTap format=\(format.sampleRate)Hz ch=\(format.channelCount)")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            dlog("Speech audioEngine error: \(error)")
            audioEngine.inputNode.removeTap(onBus: 0)
            return
        }

        isListening = true
        isRestarting = false

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.transcript = text

                    if isFinal {
                        dlog("Speech isFinal: \(text)")
                        self.silenceTimer?.invalidate()
                        self.silenceTimer = nil
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.transcript = ""
                        if !trimmed.isEmpty { self.onFinal?(trimmed) }
                        self.scheduleRestart()
                    } else {
                        self.silenceTimer?.invalidate()
                        self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                            guard let self else { return }
                            let trimmed = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            dlog("Speech silenceTimer fired: \(trimmed)")
                            self.transcript = ""
                            if !trimmed.isEmpty { self.onFinal?(trimmed) }
                            self.scheduleRestart()
                        }
                    }
                }
            }

            if let error {
                let code = (error as NSError).code
                DispatchQueue.main.async { [weak self] in
                    if code != 301 {
                        dlog("Speech STT error code=\(code): \(error.localizedDescription)")
                        self?.scheduleRestart()
                    }
                }
            }
        }
    }

    private func scheduleRestart() {
        guard !isRestarting else { return }
        isRestarting = true
        dlog("Speech.scheduleRestart")
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        // 엔진을 먼저 멈춰야 재시작 시 start()가 정상 작동함
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard self.isListening else {
                self.isRestarting = false
                return
            }
            self.beginSession()
        }
    }
}
