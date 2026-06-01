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
        dlog("AppDelegate open url scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                dlog("Wearables URL 처리 오류: \(error)")
            }
        }
        return true
    }

    // Universal Link 콜백 (Meta AI 앱이 등록 완료 후 https URL로 우리 앱을 깨움)
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return false }
        dlog("AppDelegate universal link url=\(url.absoluteString)")
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                dlog("Wearables universal link 처리 오류: \(error)")
            }
        }
        return true
    }
}
