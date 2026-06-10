import SwiftUI

#if os(macOS)
import AppKit

/// [教程注释：快捷键录制组件 (macOS 专属)]
/// 这个组件是我们在“设置-快捷键”页面里的核心黑科技。
/// 苹果官方没有提供一个让用户随意敲键盘并把这套组合键录制下来的 SwiftUI 控件，
/// 所以我们必须用 AppKit 底层的 NSEvent 监听机制，自己徒手捏一个！
struct ShortcutRecorderView: View {
    
    // 双向绑定：我们把录制好的快捷键结构体传回给上层保存
    @Binding var shortcut: AppShortcut
    var onSave: () -> Void
    
    // 当前是不是正处于“录制中(监听用户按键盘)”的状态
    @State private var isRecording = false
    // NSEvent 全局事件监听器的句柄 (用来在结束录制时拔掉监听器)
    @State private var monitor: Any?
    
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    var body: some View {
        Button(action: {
            if isRecording {
                stopRecording() // 如果正在录，再点一下就取消
            } else {
                startRecording() // 开始截获键盘
            }
        }) {
            // 根据状态切换显示的文字
            Text(isRecording ? LS("Press any key...") : shortcut.displayString)
                .frame(minWidth: 80, alignment: .center)
                // 录制中变成蓝色，提示用户“现在敲键盘！”
                .foregroundColor(isRecording ? .accentColor : .primary)
        }
        .onDisappear {
            // [防内存泄漏] 如果还没录完用户就把这页面关了，必须强制拔掉监听器
            stopRecording()
        }
    }
    
    // [黑科技：挂载全局键盘钩子]
    private func startRecording() {
        isRecording = true
        
        // NSEvent.addLocalMonitorForEvents: 截获发给这个 App 的所有按键事件
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 提取修饰键 (Shift, Command, Option, Control)
            // intersection 是滤除一些系统无关的底层干扰信号
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            
            // charactersIgnoringModifiers: 提取真正的字母。
            // 比如你按 Shift + A，它的字符可能是大写 A。我们要的是那个干净的按键。
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
                return event // 如果不是正常字符，放行这个事件，给系统处理
            }
            
            // 把底层的 NSEvent 修饰键枚举，翻译成我们在 SwiftUI 里通用的格式
            var swiftUIMods: EventModifiers = []
            if modifiers.contains(.command) { swiftUIMods.insert(.command) }
            if modifiers.contains(.control) { swiftUIMods.insert(.control) }
            if modifiers.contains(.option) { swiftUIMods.insert(.option) }
            if modifiers.contains(.shift) { swiftUIMods.insert(.shift) }
            
            let char = chars.first!
            
            // [防反人类设计] 
            // 如果用户敲的是 "Esc" 键 (ASCII: \u{1B}) 并且没带任何修饰键，
            // 他的意思通常是：“啊我不小心点到了录制，我要退出”，而不是“我要把快捷键绑在 Esc 上”。
            if char == "\u{1B}" && modifiers.isEmpty {
                stopRecording()
                return nil
            }
            
            // 回归主线程，更新 UI 和数据
            DispatchQueue.main.async {
                self.shortcut = AppShortcut(key: char, modifiers: swiftUIMods)
                self.onSave() // 触发存盘
                self.stopRecording() // 录完了，收工
            }
            
            // 返回 nil 意味着：我把这个按键吃掉了 (Consume)！
            // 系统将不会收到这个按键（比如它不会去触发系统哔哔叫的声音）
            return nil 
        }
    }
    
    private func stopRecording() {
        isRecording = false
        if let monitor = monitor {
            // 拔掉监听器，把键盘还给系统
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
#endif
