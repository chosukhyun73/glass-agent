import UIKit
import MWDATCore

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        dlog("AppDelegate didFinishLaunching")
        // ObjC API를 먼저 직접 초기화 (sharedInstance 접근에 필요)
        var objcError: NSError?
        ObjC_Wearables.configure(&objcError)
        if let objcError {
            dlog("ObjC_Wearables configure 실패: code=\(objcError.code) \(objcError.localizedDescription)")
        } else {
            dlog("ObjC_Wearables configure OK")
            GlassCameraManager.markConfigured()
        }
        // Swift API도 별도로 초기화 (handleUrl 등에서 사용)
        do {
            try Wearables.configure()
            dlog("Wearables(Swift) configure OK")
        } catch WearablesError.alreadyConfigured {
            dlog("Wearables(Swift) 이미 configured")
        } catch {
            dlog("Wearables(Swift) configure 실패: \(error)")
        }
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                print("Wearables URL 처리 오류: \(error)")
            }
        }
        return true
    }
}
