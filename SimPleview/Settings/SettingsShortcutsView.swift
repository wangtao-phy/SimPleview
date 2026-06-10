import SwiftUI

/// [教程注释：快捷键设定中心 (仅 macOS)]
/// 这个页面负责汇总所有可以被修改的快捷键，它采用了极其优雅的三列式排版。
/// 由于 iOS 设备平时没有实体键盘（除非外接），所以这个页面在 iOS 上被屏蔽了。
struct ShortcutsSettingsView: View {
    // 接入快捷键管家，它的任何变动都会立刻让这个页面上的按钮显示最新的字母组合
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ScrollView {
                // [教程注释：高级三列布局引擎]
                // 为什么要用 HStack 包三个 VStack？这就像是一张桌子上放了三个书架。
                // HStack(alignment: .top) 确保所有的书架顶部都对齐，无论里面书有多少。
                HStack(alignment: .top, spacing: 30) {
                    
                    // [第 1 列：文件与基础操作]
                    VStack(alignment: .center, spacing: 0) {
                        Text(LS("File Operations")).font(.headline).padding(.bottom, 10)
                        
                        // 每一个 ShortcutRow 就是我们抽象出来的一行：“文字标签 + 黑客录制按钮”
                        ShortcutRow(label: LS("Open File"), shortcut: $shortcutManager.open)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("Save"), shortcut: $shortcutManager.save)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("Close Window"), shortcut: $shortcutManager.closeWindow)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("Undo"), shortcut: $shortcutManager.undo)
                            .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    
                    // [第 2 列：导航与视图操作]
                    VStack(alignment: .center, spacing: 0) {
                        Text(LS("Navigation")).font(.headline).padding(.bottom, 10)
                        
                        ShortcutRow(label: LS("Find..."), shortcut: $shortcutManager.search)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("Open in Browser"), shortcut: $shortcutManager.openInBrowser)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("Toggle Left Sidebar"), shortcut: $shortcutManager.toggleLeftSidebar)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("Toggle Right Sidebar"), shortcut: $shortcutManager.toggleRightSidebar)
                            .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    
                    // [第 3 列：PDF 专属标注操作]
                    VStack(alignment: .center, spacing: 0) {
                        Text(LS("Annotations")).font(.headline).padding(.bottom, 10)
                        
                        ShortcutRow(label: LS("highlight"), shortcut: $shortcutManager.highlight)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("underline"), shortcut: $shortcutManager.underline)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("strikeout"), shortcut: $shortcutManager.strikeout)
                            .padding(.vertical, 12)
                        ShortcutRow(label: LS("none"), shortcut: $shortcutManager.none)
                            .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                // 控制整个三列大桌子距上下的留白
                .padding(.vertical, 40)
                
                // ==========================================
                // [左右间距/位置微调]
                // 如果您觉得视觉上没有居中，想把它整体向左或向右挪动一点：
                // 修改这里的 x 值：比如 x: -50 就是整体向左移动 50 像素，x: 50 就是向右移动 50 像素
                // ==========================================
                .offset(x: -20)
                
                // [注释/COMMENT] 如果您发现文字被折叠，可以把下面的 minWidth 改大，或者改变外层窗口大小
                .frame(maxWidth: .infinity, minHeight: 350, alignment: .center)
            }
            
            Divider()
            
            // [底部复位安全锁]
            // 如果用户乱改一通导致键盘冲突崩溃了，随时提供一个一键复原的后悔药机制。
            HStack {
                Spacer() // 把按钮推到最右边
                Button(LS("Restore Defaults")) {
                    shortcutManager.resetToDefaults() // 调用管家的杀手锏
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor)) // 给底部栏铺上一层底色，防止它和滚动条重叠
        }
        #else
        Text("Shortcuts not supported on iOS")
        #endif
    }
}

// MARK: - 行组件包装器
#if os(macOS)
/// [教程注释：单一快捷键的一行组件 (ShortcutRow)]
/// 左边是灰色的说明文字，右边是我们自己手写的那个黑客级别按键录制按钮。
struct ShortcutRow: View {
    // 快捷键的作用名字
    let label: String
    // 对应的按键实体，加了 @Binding 说明按钮里按下的键会直接同步回管家的数据库里
    @Binding var shortcut: AppShortcut
    
    var body: some View {
        HStack(spacing: 16) { // 左边字和右边按钮隔开 16 个像素
            
            // 左半边：文字描述
            Text(label + ":")
                // [注释/COMMENT] 这个 130 决定了左侧标签的绝对固定宽度
                // 如果您觉得各种快捷键的名字长短不一导致没对齐，或者太长被折叠，可以把 130 统一改大
                .frame(width: 130, alignment: .trailing) // trailing 代表右对齐，这样所有的冒号都能排在一条竖线上！
                .foregroundColor(.secondary)
            
            // 右半边：黑科技录制按钮
            ShortcutRecorderView(shortcut: $shortcut, onSave: {
                // 每当你在按钮里敲完一次键盘保存后，顺手也保存到硬盘文件里
                ShortcutManager.shared.saveToDefaults()
            })
            // [注释/COMMENT] 右侧录制按钮区域的绝对固定宽度，同样可以根据需要调整
            .frame(width: 130, alignment: .leading) // leading 代表左对齐，这样所有录制按钮按键都能排在一条线上！
        }
        .padding(.vertical, 4)
    }
}
#endif
