import SwiftUI
import Combine
import MWDATCore

enum PharosMode { case off, waking, active }

struct ContentView: View {

    @StateObject private var bridge = BridgeConnection.shared
    @StateObject private var speech = SpeechManager()
    @StateObject private var wakeWordMgr = WakeWordManager()
    @StateObject private var debugLog = DebugLog.shared
    @StateObject private var camera = GlassCameraManager()
    @State private var serverHost = UserDefaults.standard.string(forKey: "serverHost") ?? "100.112.206.61"
    @State private var mode: PharosMode = .off
    @State private var inactivityTimer: Timer?
    @State private var responseMode = "continuous"
    @State private var showWakeWordSheet = false
    @State private var showServerSheet = false
    @State private var showDebugLog = false
    @Environment(\.scenePhase) private var scenePhase

    private var displayTranscript: String {
        mode == .waking ? wakeWordMgr.transcript : speech.transcript
    }

    var body: some View {
        let _ = print("[Pharos] ContentView.body rendered")
        return NavigationStack {
            VStack(spacing: 0) {
                statusBar

                if let camErr = camera.errorMessage {
                    Text(camErr)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(bridge.messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            if bridge.isThinking {
                                ThinkingBubble()
                            }
                        }
                        .padding()
                    }
                    .onChange(of: bridge.messages.count) { _, _ in
                        if let last = bridge.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if !displayTranscript.isEmpty {
                    Text(displayTranscript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                bottomBar
            }
            .navigationTitle("Pharos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
        }
        .task { _ = await speech.requestPermissions() }
        .onChange(of: bridge.isThinking) { _, thinking in
            guard mode == .active else { return }
            if thinking {
                inactivityTimer?.invalidate()
                inactivityTimer = nil
            } else {
                // "done" 이후 바이너리 오디오가 늦게 도착할 수 있으므로 3초 대기
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard mode == .active, !bridge.isThinking, !bridge.isPlayingAudio else { return }
                    afterAudioFinished()
                }
            }
        }
        .onChange(of: bridge.isPlayingAudio) { _, playing in
            guard mode == .active else { return }
            if !playing && !bridge.isThinking {
                afterAudioFinished()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dlog("App → background, mode=\(mode)")
                camera.stop()
                switch mode {
                case .active:
                    // 대화 중 → 웨이크 대기로 전환해 계속 청취
                    goToWakeMode()
                case .waking:
                    // 이미 웨이크 대기 → 오디오 세션 유지, 그대로 청취 계속
                    break
                case .off:
                    // 꺼진 상태 → 아무것도 안 함
                    break
                }
            } else if phase == .active {
                dlog("App → active, mode=\(mode)")
            }
        }
        .sheet(isPresented: $showWakeWordSheet) {
            WakeWordSettingsSheet(wakeWord: $wakeWordMgr.wakeWord, wakeWord2: $wakeWordMgr.wakeWord2)
        }
        .sheet(isPresented: $showServerSheet) {
            ServerSettingsSheet(host: serverHost) { newHost in
                serverHost = newHost
                UserDefaults.standard.set(newHost, forKey: "serverHost")
            }
        }
        .sheet(isPresented: $showDebugLog) {
            DebugLogSheet(entries: debugLog.entries)
        }
    }

    // MARK: - 상태 바

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if camera.isStreaming {
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if camera.errorMessage != nil {
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: Color {
        switch mode {
        case .off:    return bridge.isConnected ? .green : .gray
        case .waking: return .orange
        case .active: return .red
        }
    }

    private var statusText: String {
        guard bridge.isConnected else { return "연결 안 됨" }
        switch mode {
        case .off:    return "연결됨"
        case .waking: return "「\(wakeWordMgr.wakeWord)」·「\(wakeWordMgr.wakeWord2)」 대기 중"
        case .active: return "대화 중"
        }
    }

    // MARK: - 하단 컨트롤

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button(action: handleButton) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 64, height: 64)
                    Image(systemName: buttonIcon)
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(promptText)
                    .font(.subheadline)
                Text(subText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    private var buttonColor: Color {
        switch mode {
        case .off:    return .accentColor
        case .waking: return .orange
        case .active: return .red
        }
    }

    private var buttonIcon: String {
        switch mode {
        case .off:    return "mic.fill"
        case .waking: return "ear.fill"
        case .active: return "stop.fill"
        }
    }

    private var promptText: String {
        switch mode {
        case .off:    return "버튼을 눌러 시작"
        case .waking: return "「\(wakeWordMgr.wakeWord)」 또는 「\(wakeWordMgr.wakeWord2)」"
        case .active: return "말씀하세요..."
        }
    }

    private var subText: String {
        switch mode {
        case .off:    return ""
        case .waking: return "웨이크워드 감지 대기 중"
        case .active: return responseMode == "brief" ? "답변 후 자동 대기 복귀 (블루)" : "1분 무활동 시 대기 복귀 (라이브블루)"
        }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("웨이크워드 변경", systemImage: "waveform") {
                    showWakeWordSheet = true
                }

                Button("서버 주소 변경", systemImage: "network") {
                    showServerSheet = true
                }

                Button("디버그 로그", systemImage: "ladybug") {
                    showDebugLog = true
                }

                Divider()

                if camera.isStreaming {
                    Button("카메라 정지", systemImage: "camera.fill") {
                        camera.stop()
                    }
                } else {
                    Button("카메라 연결", systemImage: "camera") {
                        camera.start()
                    }
                }

                if camera.registrationState != .registered {
                    Button("글래스 앱 등록", systemImage: "link") {
                        Task {
                            do {
                                try GlassCameraManager.ensureConfigured()
                                try await Wearables.shared.startRegistration()
                            } catch {
                                dlog("Registration error: \(error)")
                            }
                        }
                    }
                }

                Divider()

                if bridge.isConnected {
                    Button("연결 해제", systemImage: "xmark.circle", role: .destructive) {
                        handleStop()
                        bridge.disconnect()
                    }
                } else {
                    Button("연결", systemImage: "wifi") {
                        bridge.connect(host: serverHost)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 액션

    private func handleButton() {
        dlog("Button tapped mode=\(mode)")
        switch mode {
        case .off:
            if !bridge.isConnected { bridge.connect(host: serverHost) }
            mode = .waking
            wakeWordMgr.start { self.wakeWordDetected(wakeIndex: $0) }
        case .waking:
            wakeWordMgr.stop()
            mode = .off
        case .active:
            goToWakeMode()
        }
    }

    private func wakeWordDetected(wakeIndex: Int) {
        // 블루(0)=1문장 단발, 라이브블루(1)=연속 대화
        responseMode = wakeIndex == 0 ? "brief" : "continuous"
        dlog("wakeWordDetected index=\(wakeIndex) responseMode=\(responseMode) → transitioning to active")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !bridge.isConnected { bridge.connect(host: serverHost) }
        let delay: Double = bridge.isConnected ? 0.3 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            mode = .active
            dlog("mode=active, starting speech responseMode=\(responseMode)")
            speech.start { text in bridge.sendChat(text: text, mode: responseMode) }
        }
    }

    private func goToWakeMode() {
        dlog("goToWakeMode")
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        speech.stop()
        mode = .waking
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            wakeWordMgr.start { self.wakeWordDetected(wakeIndex: $0) }
        }
    }

    private func afterAudioFinished() {
        if responseMode == "brief" {
            // 블루: 1문장 단발 → 바로 웨이크 대기로 복귀
            goToWakeMode()
        } else {
            // 라이브블루: 연속 대화 → 1분 무활동 타이머
            startInactivityTimer()
        }
    }

    private func startInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            goToWakeMode()
        }
    }

    private func handleStop() {
        dlog("handleStop")
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        speech.stop()
        wakeWordMgr.stop()
        mode = .off
    }
}

// MARK: - 디버그 로그 시트

struct DebugLogSheet: View {
    let entries: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    if let last = entries.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 웨이크워드 설정 시트

struct WakeWordSettingsSheet: View {
    @Binding var wakeWord: String
    @Binding var wakeWord2: String
    @State private var draft = ""
    @State private var draft2 = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("웨이크워드 1", text: $draft)
                        .autocorrectionDisabled()
                } header: {
                    Text("일반 대화 호출어")
                } footer: {
                    Text("이 단어로 부르면 자세한 대화 모드로 활성화됩니다.\n예: 블루, 파로스, 자비스")
                }

                Section {
                    TextField("웨이크워드 2", text: $draft2)
                        .autocorrectionDisabled()
                } header: {
                    Text("간결 답변 호출어")
                } footer: {
                    Text("이 단어로 부르면 1~2문장의 짧은 답변 모드로 활성화됩니다.\n예: 라이브블루, 퀵파로스")
                }
            }
            .navigationTitle("웨이크워드 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let t1 = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let t2 = draft2.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t1.isEmpty { wakeWord = t1 }
                        if !t2.isEmpty { wakeWord2 = t2 }
                        dismiss()
                    }
                }
            }
            .onAppear {
                draft = wakeWord
                draft2 = wakeWord2
            }
        }
    }
}

// MARK: - 서버 설정 시트

struct ServerSettingsSheet: View {
    let host: String
    let onSave: (String) -> Void
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP 또는 도메인", text: $draft)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                } header: {
                    Text("서버 주소")
                } footer: {
                    Text("LTE에서도 사용하려면 Tailscale IP를 입력하세요.\n현재: \(host)\n포트(8765)는 자동으로 붙습니다.")
                }
            }
            .navigationTitle("서버 주소 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSave(trimmed) }
                        dismiss()
                    }
                }
            }
            .onAppear { draft = host }
        }
    }
}

// MARK: - 서브뷰

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .user ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.role == .assistant { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

struct ThinkingBubble: View {
    @State private var dots = 0
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(repeating: ".", count: dots + 1))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onReceive(timer) { _ in dots = (dots + 1) % 3 }
    }
}

#Preview {
    ContentView()
}
