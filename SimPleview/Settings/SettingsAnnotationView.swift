import SwiftUI

#if os(macOS)
/// [教程注释：ColorImageCache (颜色图片缓存机制)]
/// 在 macOS 上，如果要用 SwiftUI 原生的 Color 画一个带有边框的小圆圈放进菜单里，
/// 在旧版本中会引发奇怪的 UI 错位和拉伸。
/// 所以我们这里采用了底层 AppKit 技术：用 NSImage 直接把彩色小圆圈“画”出来并缓存。
/// 这样既保证了绝对的像素完美，又能极大地节省重复画图的 CPU 开销。
class ColorImageCache {
    // 单例模式，全局共享同一个缓存池
    static let shared = ColorImageCache()
    private var cache: [String: NSImage] = [:]
    
    // 传入名字和颜色，返回画好的圆点图片
    func image(for colorName: String, swiftColor: Color) -> NSImage {
        // 如果之前已经画过了，直接拿现成的 (空间换时间)
        if let img = cache[colorName] { return img }
        
        let color = NSColor(swiftColor)
        let size = NSSize(width: 12, height: 12) // 小圆点的物理尺寸
        let image = NSImage(size: size)
        
        // [底层绘图黑科技]
        image.lockFocus() // 告诉显卡：“我要在这个图片里作画了！”
        
        // 第一步：填充内部颜色
        color.setFill()
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        path.fill()
        
        // 第二步：给外边缘画上一圈淡淡的灰色描边，防止遇到白色的背景时看不清楚边缘
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        
        image.unlockFocus() // 告诉显卡：“我画完了！”
        
        // 关键属性：禁止系统把它当成单色模板图标，必须原汁原味显示彩色
        image.isTemplate = false 
        
        // 存入缓存字典
        cache[colorName] = image
        return image
    }
}
#endif

/// [教程注释：颜色选择器的一整行组件]
/// 我们把所有涉及“选择颜色”的逻辑提炼出来，做成了这个高度复用的下拉框组件。
/// 它不仅支持选择我们预设的五种基础颜色，还能接纳用户通过自定义调色板填写的 Hex 值（如 #FF0000）。
struct ColorPickerRow: View {
    // 标签名称（比如“高亮颜色”）
    let title: String
    // 双向绑定外部的数据状态
    @Binding var selection: String
    // 预设的颜色列表 ("Blue", "Red" ...)
    let colors: [String]
    // 将字符串 ("Blue") 转换成 SwiftUI Color 对象的方法
    let colorMapper: (String) -> Color
    // 多语言翻译的方法
    let LS: (String) -> String
    
    // [动态数据源]
    // 这是我们在下拉菜单里最终呈现的选项列表
    var displayColors: [String] {
        var list = colors
        // 如果当前选中的颜色是一个十六进制字符串 (意味着它不在基础五色里)，
        // 我们需要把这个特殊颜色强行塞入选项列表中，不然系统会因为找不到对应选项而显示空白。
        if selection.hasPrefix("#") && !list.contains(selection) {
            list.append(selection)
        }
        // 永远在最底部追加一个“其他颜色”的入口
        list.append("Other Color...")
        return list
    }
    
    var body: some View {
        Picker(title + ":", selection: $selection) {
            // 循环遍历渲染下拉菜单的每一项
            ForEach(displayColors, id: \.self) { color in
                if color == "Other Color..." {
                    Text(LS(color)).tag(color)
                } else {
                    HStack {
                        #if os(macOS)
                        // Mac 上使用我们写的图片缓存黑科技
                        Image(nsImage: ColorImageCache.shared.image(for: color, swiftColor: colorMapper(color)))
                        #else
                        // iOS 上直接用 SwiftUI 即可完美渲染
                        Circle()
                            .fill(colorMapper(color))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.secondary, lineWidth: 0.5))
                        #endif
                        // 如果是十六进制，直接显示原文；如果是预设颜色名，翻译成多语言
                        Text(color.hasPrefix("#") ? color : LS(color))
                    }.tag(color) // tag 的作用是绑定这行数据对应的值是什么
                }
            }
        }
        .pickerStyle(.menu) // 样式设为下拉菜单式
        .padding(.vertical, 12) // [UI布局] 控制颜色选择器上下行间距
        // 监听变化：如果用户点到了“其他颜色”这个奇兵选项...
        .onChange(of: selection) { _, newValue in
            if newValue == "Other Color..." {
                #if os(macOS)
                // 唤起 macOS 系统级原生调色板面板，并通过闭包(Closure)接收用户最终选的颜色
                ColorPanelManager.shared.show(initialColor: nil) { newColor in
                    selection = newColor.hexString // 转换成 Hex 字符串保存回设置
                }
                #endif
            }
        }
    }
}

/// [教程注释：设置面板的【批注】模块主视图]
/// 负责管理各种默认颜色的设置，以及“撤销手写时间”的时长设定。
struct AnnotationSettingsView: View {
    // 连通底层硬盘数据库(UserDefaults)的快捷方式：用户只要一改，立即写入硬盘，杀后台也不怕
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("annotationRevertTimeoutStr") var annotationRevertTimeoutStr: String = "15"
    @AppStorage("defaultHighlightColor") var defaultHighlightColor: String = "Yellow"
    @AppStorage("defaultUnderlineColor") var defaultUnderlineColor: String = "Blue"
    @AppStorage("defaultStrikeoutColor") var defaultStrikeoutColor: String = "Red"
    
    // 基础颜色列表
    let colors = ["Blue", "Red", "Yellow", "Green", "Purple"]
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    // [颜色引擎] 根据名字输出真正的颜料
    private func swiftColor(for name: String) -> Color {
        // 如果是外部引入的 Hex (例如 #FFAABB)，调用下面的扩展进行反解析
        if name.hasPrefix("#") {
            #if os(macOS)
            return Color(nsColor: NSColor(hex: name) ?? .clear)
            #else
            return .clear
            #endif
        }
        // 普通基础颜色的快速翻译
        switch name {
        case "Blue": return .blue
        case "Red": return .red
        case "Yellow": return .yellow
        case "Green": return .green
        case "Purple": return .purple
        default: return .clear
        }
    }
    
    var body: some View {
        ScrollView {
            // [UI整体打包] 将所有表单放入一个垂直容器中以便控制整体宽度
            VStack {
                Form {
                    // 第一个设置项：多少秒后手写工具自动复原
                    LabeledContent(LS("Revert to Selection After") + ":") {
                        HStack(spacing: 8) {
                            TextField("", text: $annotationRevertTimeoutStr)
                                .textFieldStyle(.plain) // 扒掉系统默认的白底圆角框，防止聚焦时闪白
                                #if os(macOS)
                                .focusEffectDisabled()
                                .background(Color.clear)
                                #endif
                                .multilineTextAlignment(.center) // 文字居中
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                                )
                                .frame(width: 60) // [UI布局] “多少秒” 输入框的宽度
                            Text(LS("Seconds"))
                        }
                    }
                    .padding(.vertical, 16)
                    
                    // 下面的三个调用了我们上面封装好的神级下拉框组件
                    ColorPickerRow(title: LS("Highlight Default Color"), selection: $defaultHighlightColor, colors: colors, colorMapper: swiftColor, LS: LS)
                    ColorPickerRow(title: LS("Underline Default Color"), selection: $defaultUnderlineColor, colors: colors, colorMapper: swiftColor, LS: LS)
                    ColorPickerRow(title: LS("Strikeout Default Color"), selection: $defaultStrikeoutColor, colors: colors, colorMapper: swiftColor, LS: LS)
                }
                // [UI布局] 设置标注选项表单的最大宽度，防止在宽屏显示器上被拉成一个面条导致很难看
                .frame(maxWidth: 450)
            }
            // 1. padding: 控制包裹上下的留白间距，目前上下留白 40
            .padding(.vertical, 40)
            
            // ==========================================
            // [左右间距/位置微调]
            // 如果您觉得视觉上没有居中，想把它整体向左或向右挪动一点：
            // 修改这里的 x 值：比如 x: -50 就是整体向左移动 50 像素，x: 50 就是向右移动 50 像素
            // ==========================================
            .offset(x: -20) // 微妙地偏左对齐一点，让 Mac 原生的设置弹窗视觉平衡
            
            // 2. alignment: .center 控制包裹在当前界面（无限大的空间）中默认“绝对居中”
            .frame(maxWidth: .infinity, minHeight: 350, alignment: .center)
        }
        // [广播机制]
        // 由于这几个默认颜色直接影响到了右边侧边栏的界面渲染，
        // 只要这里的数据一变动，立刻发射一颗“信号弹(Notification)”，所有订阅了这个信号的组件就会立刻响应并重绘。
        .onChange(of: defaultHighlightColor) { _, _ in postColorChangeNotification() }
        .onChange(of: defaultUnderlineColor) { _, _ in postColorChangeNotification() }
        .onChange(of: defaultStrikeoutColor) { _, _ in postColorChangeNotification() }
    }
    
    private func postColorChangeNotification() {
        // NotificationCenter.default: 就是系统的“大喇叭”。只要你吼一声，全 app 都能听到。
        NotificationCenter.default.post(name: NSNotification.Name("DefaultColorsChanged"), object: nil)
    }
}

// MARK: - macOS 颜色处理黑科技扩展
#if os(macOS)
import AppKit

/// [教程注释：十六进制颜色(Hex)与苹果原生颜色(NSColor)相互转化的炼金术]
extension NSColor {
    // [解析器] 将 "#FF0000" 变为纯正的系统红色
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        // 像扫描仪一样扫描十六进制里的字符，塞进我们准备好的内存变量里
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b, a: CGFloat
        
        // R G B 每通道分别进行复杂的位移运算，解析出真色彩
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // [反解析器] 将纯正系统红色变为 "#FF0000" 字符串
    var hexString: String {
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        // 使用 String(format:) 像 printf 一样强行格式化输出大写的 16 进制码
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

/// [教程注释：原生调色板守护神 (ColorPanelManager)]
/// NSColorPanel 是一个古老且强大的 macOS 系统级面板。
/// 最大的坑在于：它不是像普通的提示框一样即用即消的，而是永远悬浮在屏幕边缘。
/// 因此必须封装一个单例 Manager，由它负责全权接管这个调色盘的交互和生命周期。
class ColorPanelManager: NSObject {
    static let shared = ColorPanelManager()
    private var onColorChange: ((NSColor) -> Void)?
    
    private override init() {
        super.init()
    }
    
    // 打开调色盘的方法
    func show(initialColor: NSColor?, onColorChange: @escaping (NSColor) -> Void) {
        // 保存外界传进来的回调闭包
        self.onColorChange = onColorChange
        
        let panel = NSColorPanel.shared
        // 如果调用前已经有一种颜色被选中，把它扔给面板
        if let initialColor = initialColor {
            panel.color = initialColor
        }
        // 强行把面板的透明度调节滑块关掉，因为我们的 PDF 批注系统目前没有透明度这个维度的设定
        panel.showsAlpha = false
        
        // 夺取目标权：规定用户在这块面板上点的每一笔动作，都会转发给下面定义的 colorChanged 方法
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        
        // 使其成为最前方的关键窗口并显示给用户
        panel.makeKeyAndOrderFront(nil)
    }
    
    // 当调色盘上的颜色值发生一丁点改变时，就会触发这个 objc 方法
    @objc private func colorChanged(_ sender: NSColorPanel) {
        // 调用之前的回调闭包，把最新颜色传回给外界正在苦苦等待的 SwiftUI 视图！
        onColorChange?(sender.color)
    }
}
#endif
