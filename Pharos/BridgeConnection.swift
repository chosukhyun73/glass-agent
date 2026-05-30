import Foundation
import Combine
import AVFoundation

// MARK: - 메시지 모델

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()

    enum Role { case user, assistant }
}

struct AIModel: Identifiable {
    let id: String
    let name: String
}

// MARK: - WebSocket 연결 관리

class BridgeConnection: NSObject, ObservableObject {

    @Published var isConnected = false
    @Published var isThinking = false
    @Published var isPlayingAudio = false
    @Published var messages: [ChatMessage] = []
    @Published var availableModels: [AIModel] = [
        AIModel(id: "anthropic/claude-sonnet-4-6", name: "Claude Sonnet"),
        AIModel(id: "anthropic/claude-opus-4-7", name: "Claude Opus"),
        AIModel(id: "openai/gpt-4o", name: "GPT-4o"),
        AIModel(id: "google/gemini-2.0-flash", name: "Gemini Flash"),
    ]
    @Published var selectedModel = "anthropic/claude-sonnet-4-6"

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var pendingResponse = ""
    private var lastHost = ""

    static let shared = BridgeConnection()

    private override init() {
        super.init()
        // audioPlayer delegate는 playAudioData에서 설정
    }

    // MARK: - 연결

    func connect(host: String) {
        guard let url = URL(string: "ws://\(host):8765/pharos") else { return }
        lastHost = host
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveLoop()
        startPing()
        DispatchQueue.main.async { self.isConnected = true }
        dlog("[연결] \(host)")
    }

    func disconnect() {
        lastHost = ""
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        pingTimer?.invalidate()
        audioPlayer?.stop()
        DispatchQueue.main.async {
            self.isConnected = false
            self.isThinking = false
            self.isPlayingAudio = false
        }
    }

    // MARK: - 메시지 전송

    func sendChat(text: String, mode: String = "default") {
        guard isConnected else { return }
        let payload: [String: String] = [
            "type": "chat",
            "text": text,
            "model": selectedModel,
            "response_mode": mode
        ]
        send(payload)
        DispatchQueue.main.async {
            self.messages.append(ChatMessage(role: .user, text: text))
        }
    }

    // MARK: - 수신 루프

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    DispatchQueue.main.async { self.handleMessage(text) }
                case .data(let data):
                    DispatchQueue.main.async { self.playAudioData(data) }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                dlog("[수신 오류] \(error)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isThinking = false
                    self.isPlayingAudio = false
                    guard !self.lastHost.isEmpty else { return }
                    let host = self.lastHost
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        guard !self.lastHost.isEmpty else { return }
                        dlog("[자동 재연결] \(host)")
                        self.connect(host: host)
                    }
                }
            }
        }
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "thinking":
            isThinking = true
            pendingResponse = ""

        case "chunk":
            if let chunk = json["text"] as? String {
                pendingResponse += (pendingResponse.isEmpty ? "" : " ") + chunk
            }

        case "done":
            isThinking = false
            if !pendingResponse.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: pendingResponse))
            }
            pendingResponse = ""

        case "timeout":
            isConnected = false
            messages.append(ChatMessage(role: .assistant, text: "⏱ 5분 무활동으로 세션이 종료되었습니다."))

        case "models":
            if let list = json["data"] as? [[String: String]] {
                let models = list.compactMap { d -> AIModel? in
                    guard let id = d["id"], let name = d["name"] else { return nil }
                    return AIModel(id: id, name: name)
                }
                availableModels = models
            }

        default:
            break
        }
    }

    // MARK: - 오디오 재생 (edge-tts MP3)

    private func playAudioData(_ data: Data) {
        dlog("Audio received: \(data.count) bytes")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlayingAudio = true
            dlog("Audio playing")
        } catch {
            dlog("Audio playback error: \(error)")
            isPlayingAudio = false
        }
    }

    // MARK: - 유틸

    private func send(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error { dlog("[전송 오류] \(error)") }
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.send(["type": "ping"])
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension BridgeConnection: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        dlog("Audio finished (success=\(flag))")
        DispatchQueue.main.async { self.isPlayingAudio = false }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        dlog("Audio decode error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async { self.isPlayingAudio = false }
    }
}
