import Foundation
import Combine

final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    @Published private(set) var entries: [String] = []

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ msg: String) {
        let entry = "[\(df.string(from: Date()))] \(msg)"
        print(entry)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 300 { self.entries.removeFirst() }
        }
    }
}

func dlog(_ msg: String) {
    DebugLog.shared.add(msg)
}
