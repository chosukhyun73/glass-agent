import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

@MainActor
final class GlassCameraManager: ObservableObject {

    @Published var streamState: ObjC_StreamState = .stopped
    @Published var lastPhoto: UIImage?
    @Published var errorMessage: String?
    @Published var registrationState: RegistrationState = .unavailable

    var isStreaming: Bool { streamState == .streaming }

    private var deviceSession: ObjC_DeviceSession?
    private var cameraStream: ObjC_Stream?

    // AppDelegate 백그라운드에서 configure 완료 후 true로 설정됨
    private static var configured = false

    static func markConfigured() {
        configured = true
        dlog("Wearables SDK configured")
    }

    static func ensureConfigured() throws {
        guard !configured else { return }
        try Wearables.configure()
        configured = true
        dlog("Wearables SDK 초기화 완료")
    }

    init() {
        dlog("Camera init")
    }

    func start() {
        dlog("Camera.start requested")
        errorMessage = nil

        guard GlassCameraManager.configured else {
            errorMessage = "SDK 초기화 중입니다. 잠시 후 다시 시도하세요."
            dlog("Camera: SDK not configured yet")
            return
        }

        // ObjC_Wearables는 메인 스레드에서만 접근 가능 (백그라운드 접근 시 fatalError)
        // 무거운 BT 통신인 session.start/stream.start만 백그라운드로
        dlog("Camera: sharedInstance 호출 전 isMain=\(Thread.isMainThread)")
        let wearables = ObjC_Wearables.sharedInstance
        dlog("Camera: sharedInstance 완료")

        dlog("Camera: registrationState 호출 전")
        let regState = wearables.registrationState
        dlog("Camera: registrationState=\(regState) 완료")

        dlog("Camera: devices 호출 전")
        let devices = wearables.devices
        dlog("Camera: devices=\(devices) 완료")

        registrationState = regState

        guard regState == .registered else {
            errorMessage = "앱 미등록 — 메뉴 → 글래스 앱 등록 필요"
            return
        }
        guard let deviceId = devices.first else {
            errorMessage = "연결된 글래스 없음"
            return
        }

        dlog("Camera: createSession 호출 전 deviceId=\(deviceId)")
        guard let session = wearables.createSession(forDeviceIdentifier: deviceId) else {
            errorMessage = "세션 생성 실패"
            return
        }
        dlog("Camera: createSession 완료")

        dlog("Camera: addStream 호출 전")
        guard let stream = session.addStream() else {
            errorMessage = "스트림 생성 실패"
            return
        }
        dlog("Camera: addStream 완료")

        stream.onStateChanged = { [weak self] state in
            DispatchQueue.main.async { self?.streamState = state; dlog("Camera state → \(state.rawValue)") }
        }
        stream.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = "카메라 오류 (코드 \(error.rawValue))"
                self?.streamState = .stopped
            }
        }
        stream.onPhotoData = { [weak self] photoData in
            DispatchQueue.main.async { self?.lastPhoto = photoData.image }
        }

        deviceSession = session
        cameraStream = stream
        dlog("Camera: BT start 백그라운드 dispatch")

        // session.start / stream.start는 BT 통신이라 백그라운드
        DispatchQueue.global(qos: .userInitiated).async {
            dlog("Camera: session.start 호출 전 isMain=\(Thread.isMainThread)")
            session.start()
            dlog("Camera: session.start 완료")
            dlog("Camera: stream.start 호출 전")
            stream.start()
            dlog("Camera: stream.start 완료")
        }
    }

    func stop() {
        dlog("Camera.stop")
        cameraStream?.stop()
        deviceSession?.stop()
        cameraStream = nil
        deviceSession = nil
        streamState = .stopped
    }

    func capturePhoto() {
        guard let stream = cameraStream, isStreaming else {
            dlog("Camera: not streaming")
            return
        }
        dlog("Camera capturePhoto")
        stream.capturePhoto(format: .jpeg)
    }
}
