import SwiftUI
import UniformTypeIdentifiers

/// [教程注释：通用设置面板 (GeneralSettingsView)]
/// 这个页面负责整个应用程序最基础的核心配置：语言、行为逻辑、外部浏览器等。
/// 所有这里被修改的变量，都会像树根一样，通过 UserDefaults 渗透进 App 的每个角落。
struct GeneralSettingsView: View {
    // [AppStorage: 最纯粹的硬盘绑定]
    // 当你在界面上切换这些变量的值时，SwiftUI 会以毫秒级的速度把它们直接写死在设备的硬盘上。
    // 这也是为什么你杀后台重启，所有的设置依然原封不动的核心原因。
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("memoryMode") var memoryMode: MemoryMode = .saving
    @AppStorage("hibernationTimeoutStr") var hibernationTimeoutStr: String = "20"
    @AppStorage("openInTab") var openInTab: Bool = false
    @AppStorage("externalBrowser") var externalBrowser: ExternalBrowser = .defaultBrowser
    @AppStorage("customBrowserPath") var customBrowserPath: String = ""
    @AppStorage("enableReadingRecord") var enableReadingRecord: Bool = false
    
    // 我们把多语言翻译函数作为外包传入，让这个视图不用关心它是怎么被翻译的，只管显示就行
    let LS: (String) -> String
    
    var body: some View {
        ScrollView {
            // ==========================================
            // [UI整体打包] 这个 VStack 就是当前界面的所有内容
            // 这种套娃一样的结构可以让内容居中而不贴边
            // ==========================================
            VStack {
                // Form 是 SwiftUI 用来绘制苹果标准的“输入表单”的高级组件。
                // 它的底层会自动算好文本标签与输入框之间的对齐，让人感觉非常系统级。
                Form {
                    // [黑科技修复] 强制吸纳系统初始焦点，解决打开设置面板时输入框自动聚焦导致的“白屏闪烁”问题
                    TextField("", text: .constant(""))
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                    
                    // [设置项 1：切换多国语言]
                    Picker(selection: $appLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    } label: {
                        Text(LS("Switch Language") + ":")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .pickerStyle(.menu) // 样式：下拉框
                    .padding(.vertical, 8)
                    
                    // [设置项 1.5：内存运行模式]
                    Picker(selection: $memoryMode) {
                        ForEach(MemoryMode.allCases, id: \.self) { mode in
                            Text(LS(mode == .performance ? "Performance" : "Saving")).tag(mode)
                        }
                    } label: {
                        Text(LS("Memory Mode") + ":")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .pickerStyle(.segmented)
                    .id(appLanguage) // [Fix] Force the Segmented Picker to redraw its labels when language changes
                    .frame(width: 320)
                    .padding(.vertical, 8)
                    
                    // [设置项 2：休眠断电超时设定]
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("", text: $hibernationTimeoutStr)
                                .textFieldStyle(.roundedBorder)
                                #if os(macOS)
                                .focusEffectDisabled()
                                #endif
                                .multilineTextAlignment(.center)
                                // [UI布局] “多少分钟”输入框的绝对宽度
                                .frame(width: 60)
                            Text(LS("Minutes"))
                        }
                    } label: {
                        Text(LS("Hibernation Timeout") + ":")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 12)
                    
                    // [设置项 3：新文档开启方式] (由于 Mac 有强大的窗口管理，这个最有用)
                    Picker(selection: $openInTab) {
                        Text(LS("New Window")).tag(false)
                        Text(LS("New Tab")).tag(true)
                    } label: {
                        Text(LS("New File Opens In") + ":")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .pickerStyle(.segmented) // 样式：像小胶囊一样的分段按钮
                    .id(appLanguage) // [Fix] Force redraw on language change
                    .frame(width: 200) // 调小宽度，防止英文状态下把左边的长标签挤换行
                    .padding(.vertical, 12)
                    
                    // [设置项 4：外部跳转的浏览器] (例如当你搜网页的时候，调用谁)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(selection: $externalBrowser) {
                            ForEach(ExternalBrowser.allCases) { browser in
                                Text(LS(browser.displayName)).tag(browser)
                            }
                        } label: {
                            Text(LS("External Browser") + ":")
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: externalBrowser) { _, newValue in
                            // [底层交互：系统文件选择器 (NSOpenPanel)]
                            // 如果用户选了“自定义 (Other)...” 我们就要弹出一个选择器让他去硬盘找想要的 App。
                            if newValue == .other {
                                #if os(macOS)
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false // 不允许多选
                                panel.canChooseDirectories = false // 不允许选个文件夹当浏览器
                                panel.canCreateDirectories = false
                                // 最强的一句限制：只能选 "UTType.application"，也就是后缀名为 .app 的应用程序文件！
                                panel.allowedContentTypes = [UTType.application]
                                // 把默认打开的路径定位到系统的 Applications 文件夹
                                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                                
                                // 呼出阻塞式模态面板，如果用户点了“OK”
                                if panel.runModal() == .OK, let url = panel.url {
                                    customBrowserPath = url.path // 把路径记忆下来
                                } else {
                                    // 用户半途取消了！
                                    // 检查以前有没有选好过，没有的话，强行帮你切回“默认浏览器”的选项，防止出现漏洞。
                                    if customBrowserPath.isEmpty {
                                        externalBrowser = .defaultBrowser
                                    }
                                }
                                #endif
                            }
                        }
                        
                        // 反馈 UI：如果你确实选好了一个自定义 App，把它的小尾巴名字印在下方。
                        if externalBrowser == .other && !customBrowserPath.isEmpty {
                            Text(URL(fileURLWithPath: customBrowserPath).lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 150)
                        }
                    }
                    .padding(.vertical, 12)
                    
                    // [设置项 5：阅读记录总开关]
                    // 用户在这里只要点一下，就会牵一发而动全身地控制整个 App 里阅读记录和相关菜单的死活。
                    Toggle(isOn: $enableReadingRecord) {
                        Text(LS("Enable Reading Record"))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                        .padding(.vertical, 12)
                }
                // [UI布局] 这里控制了表单内容的最大物理宽度，防止屏幕拉宽时它无限拉长导致很难看
                .frame(maxWidth: 550)
            }
            // ==========================================
            // [UI整体打包结束] 下面两行控制这个“包裹”在屏幕里的绝对位置
            // ==========================================
            
            // 1. padding: 控制包裹上下的留白间距，目前上下留白 40
            .padding(.vertical, 40)
            
            // ==========================================
            // [左右间距/位置微调]
            // 如果您觉得视觉上没有居中，想把它整体向左或向右挪动一点：
            // 修改这里的 x 值：比如 x: -50 就是整体向左移动 50 像素，x: 50 就是向右移动 50 像素
            // ==========================================
            .offset(x: 0)
            
            // 2. alignment: .center 控制包裹在当前界面（无限大的空间）中默认“绝对居中”
            //    如果您想让它靠顶部，可以改成 alignment: .top
            //    如果您想让它靠左上角，可以改成 alignment: .topLeading
            .frame(maxWidth: .infinity, minHeight: 350, alignment: .center)
        }
    }
}
