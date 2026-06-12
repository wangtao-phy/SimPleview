import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// [原生化重构] 移除了繁杂的 ColorImageCache, ColorPickerRow 和 ColorPanelManager。
// 现在的 macOS/iOS 均原生支持 ColorPicker，性能更好，体验更系统化。

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
    
    // [原生化] 构建原生的 Binding<Color> 以对接系统的 ColorPicker
    private func colorBinding(for colorString: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { self.swiftColor(for: colorString.wrappedValue) },
            set: { newColor in
                #if os(macOS)
                colorString.wrappedValue = NSColor(newColor).hexString
                #else
                let uiColor = UIColor(newColor)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
                let red = Int(round(r * 255)), green = Int(round(g * 255)), blue = Int(round(b * 255))
                colorString.wrappedValue = String(format: "#%02X%02X%02X", red, green, blue)
                #endif
            }
        )
    }
    
    var body: some View {
        Form {
            // 第一个设置项：多少秒后手写工具自动复原
            LabeledContent(LS("Revert to Selection After") + ":") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("", text: $annotationRevertTimeoutStr)
                        .textFieldStyle(.roundedBorder) // 使用原生圆角框，自动适配高度
                        #if os(macOS)
                        .focusEffectDisabled()
                        #endif
                        .multilineTextAlignment(.center) // 文字居中
                        .frame(width: 60) // [UI布局] “多少秒” 输入框的宽度
                    Text(LS("Seconds"))
                }
            }
            .padding(.vertical, 4)
            
            // 下面的三个全部替换为原生 ColorPicker
            ColorPicker(LS("Highlight Default Color") + ":", selection: colorBinding(for: $defaultHighlightColor), supportsOpacity: false)
                .padding(.vertical, 4)
            ColorPicker(LS("Underline Default Color") + ":", selection: colorBinding(for: $defaultUnderlineColor), supportsOpacity: false)
                .padding(.vertical, 4)
            ColorPicker(LS("Strikeout Default Color") + ":", selection: colorBinding(for: $defaultStrikeoutColor), supportsOpacity: false)
                .padding(.vertical, 4)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .frame(width: 450, height: 350) // 适配设置面板的尺寸
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
#endif
