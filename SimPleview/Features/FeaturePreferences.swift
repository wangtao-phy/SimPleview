import Combine
import Foundation

/// macOS 可选模块的统一开关。未保存过的开关默认开启，旧版本升级不改变功能。
/// 开关只控制模块的入口和运行状态，不删除窗口分组、背景选择或已有记录。
@MainActor
final class FeaturePreferences: ObservableObject {
    static let shared = FeaturePreferences()
    private let defaults: UserDefaults

    @Published var windowManagement: Bool { didSet { defaults.set(windowManagement, forKey: "enableWindowManagement") } }
    @Published var pomodoro: Bool { didSet { defaults.set(pomodoro, forKey: "enablePomodoro") } }
    @Published var eyeCare: Bool { didSet { defaults.set(eyeCare, forKey: "enableEyeCare") } }
    @Published var ai: Bool { didSet { defaults.set(ai, forKey: "enableAI") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        windowManagement = defaults.object(forKey: "enableWindowManagement") as? Bool ?? true
        pomodoro = defaults.object(forKey: "enablePomodoro") as? Bool ?? true
        eyeCare = defaults.object(forKey: "enableEyeCare") as? Bool ?? true
        ai = defaults.object(forKey: "enableAI") as? Bool ?? true
    }
}
