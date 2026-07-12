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
                // [原生化重构] 使用 macOS 原生 Grid (六列高级自适应布局) 替代手工计算宽度的 HStack
                Grid(horizontalSpacing: 12, verticalSpacing: 14) {
                    // [表头] 每个表头跨越 2 列 (名称列 + 录制按钮列)
                    GridRow {
                        Text(LS("File Operations")).font(.headline).gridCellColumns(2).padding(.bottom, 8)
                        Text(LS("Navigation")).font(.headline).gridCellColumns(2).padding(.bottom, 8)
                        Text(LS("Annotations")).font(.headline).gridCellColumns(2).padding(.bottom, 8)
                    }
                    
                    // 第 1 行
                    GridRow {
                        labelView(LS("Open File"))
                        recorderView($shortcutManager.open)
                        
                        labelView(LS("Find..."))
                        recorderView($shortcutManager.search)
                        
                        labelView(LS("highlight"))
                        recorderView($shortcutManager.highlight)
                    }
                    
                    // 第 2 行
                    GridRow {
                        labelView(LS("Save"))
                        recorderView($shortcutManager.save)
                        
                        labelView(LS("Open in Browser"))
                        recorderView($shortcutManager.openInBrowser)
                        
                        labelView(LS("underline"))
                        recorderView($shortcutManager.underline)
                    }
                    
                    // 第 3 行
                    GridRow {
                        labelView(LS("Close Window"))
                        recorderView($shortcutManager.closeWindow)
                        
                        labelView(LS("Toggle Left Sidebar"))
                        recorderView($shortcutManager.toggleLeftSidebar)
                        
                        labelView(LS("strikeout"))
                        recorderView($shortcutManager.strikeout)
                    }
                    
                    // 第 4 行
                    GridRow {
                        labelView(LS("Undo"))
                        recorderView($shortcutManager.undo)
                        
                        labelView(LS("Toggle Right Sidebar"))
                        recorderView($shortcutManager.toggleRightSidebar)
                        
                        labelView(LS("none"))
                        recorderView($shortcutManager.none)
                    }
                    
                    // 第 5 行
                    GridRow {
                        labelView(LS("Redo"))
                        recorderView($shortcutManager.redo)
                        
                        Color.clear; Color.clear
                        Color.clear; Color.clear
                    }
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: 350, alignment: .center)
            }
            
            Divider()
            
            // [底部复位安全锁]
            HStack {
                Spacer()
                Button(LS("Restore Defaults")) {
                    shortcutManager.resetToDefaults()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        #else
        Text("Shortcuts not supported on iOS")
        #endif
    }
    
    #if os(macOS)
    // 自动向右对齐的文字标签单元格
    private func labelView(_ text: String) -> some View {
        Text(text + ":")
            .foregroundColor(.secondary)
            .gridColumnAlignment(.trailing)
    }
    
    // 自动向左对齐的录制按钮单元格
    private func recorderView(_ binding: Binding<AppShortcut>) -> some View {
        ShortcutRecorderView(shortcut: binding, onSave: {
            ShortcutManager.shared.saveToDefaults()
        })
        .gridColumnAlignment(.leading)
        .padding(.trailing, 20) // 在每组结尾加点空隙
    }
    #endif
}
