import Combine
import Foundation

/// Publishes Low Power Mode changes so tracking behavior can adapt automatically.
final class PowerModeService: ObservableObject {
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var observer: NSObjectProtocol?

    /// Starts observing system power state notifications.
    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// Removes power state observer.
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
