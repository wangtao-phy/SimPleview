import SwiftUI
import PDFKit

/// [教程注释：阅读记录仪表盘面板]
/// 这个页面就像是你打游戏通关后的“结算画面”。
/// 能够让你查看看这篇论文花了多长时间，并且有一张类似 Github 提交记录的“阅读热力图(Heatmap)”。
struct ReadingRecordView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker = ReadingTracker.shared
    
    // 使用 @AppStorage 直接连通底层沙盒里的 UserDefaults。
    // 如果你在设置里改了热力图颜色，这里会像施了魔法一样自动改变。
    @AppStorage("heatmapSegments") var heatmapSegments: Double = 50.0
    @AppStorage("heatmapColorTheme") var heatmapColorTheme: String = "Red"
    
    @State private var ratingInput: String = ""
    
    // [动态数据绑定引擎]
    // 这是 SwiftUI 数据流里非常高级的技巧。
    // 因为这篇文档的数据原本藏在 `tracker` 字典里的一角，我们用闭包动态查字典生成了一个 Binding 对象，
    // 把里面的值像水管一样导出来，供给下方的各种输入框直接双向修改。
    private var currentRecordBinding: Binding<DocumentRecord>? {
        guard let url = state.pdfView.document?.documentURL else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        guard tracker.recordsCache[title] != nil else { return nil }
        
        return Binding<DocumentRecord>(
            get: { tracker.recordsCache[title] ?? DocumentRecord(documentID: title, documentTitle: title) },
            set: { tracker.updateRecord($0) }
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 如果成功查到了当前这篇文档的数据管道，就把界面画出来
            if let binding = currentRecordBinding {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        // [上层：时间统计与热力图]
                        VStack(spacing: 0) {
                            // 格式化输出阅读总时长
                            Text(state.L("Total Time") + ": \(formatTime(binding.wrappedValue.totalReadingTime))")
                                .font(.headline)
                                .padding()
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 10) {
                                Text(state.L("Reading Heatmap"))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    
                                // [核心渲染技术：GeometryReader]
                                // GeometryReader 就像一把尺子，它能在渲染前量出外层给你分配的宽高有多少，
                                // 然后我们根据测出来的宽度 (geometry.size.width) 和预设的分段数 (segments)，
                                // 动态算出一个个彩色小方块的精准宽度，保证刚好填满整个屏幕。
                                GeometryReader { geometry in
                                    let segments = Int(heatmapSegments)
                                    let pageCount = state.pdfView.document?.pageCount ?? 1
                                    
                                    // 计算每个彩色小块在逻辑上代表了多少页
                                    let pagesPerSegment = max(1.0, Double(pageCount) / Double(segments))
                                    
                                    let segmentData = calculateSegments(record: binding.wrappedValue, segments: segments, pagesPerSegment: pagesPerSegment)
                                    let maxDuration = segmentData.max() ?? 1.0
                                    let itemWidth = geometry.size.width / CGFloat(segments) // 尺子开始计算了
                                    
                                    HStack(spacing: 0) {
                                        ForEach(0..<segments, id: \.self) { i in
                                            let duration = segmentData[i]
                                            Rectangle()
                                                // 看这块越久，它这儿涂得就越深，就好像颜料堆积一样
                                                .fill(heatmapColor(for: duration, maxTime: maxDuration))
                                                .frame(width: itemWidth) // 这里注入尺子算出来的宽度
                                                .onTapGesture { // 提供隐藏的交互：点击热力图上的色块，就可以直接跳到那块对应的页码！
                                                    let targetPage = Int(Double(i) * pagesPerSegment)
                                                    state.goToPage(min(targetPage, pageCount - 1))
                                                }
                                        }
                                    }
                                    .cornerRadius(6)
                                    // 在外面套一层若有若无的线框，更有设计感
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                }
                                .frame(height: 40)
                            }
                            .padding()
                        }
                        
                        Divider()
                        
                        // [下层：文档人工备注区]
                        metadataSection(binding: binding)
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                        
                    }
                }
                
            } else {
                // [空数据占位图 (Empty State)]
                VStack {
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)
                    Text(state.L("No Reading Record"))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // [模块化：把长长的界面切分]
    @ViewBuilder
    private func metadataSection(binding: Binding<DocumentRecord>) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            
            // Article Date
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Article Date"))
                    .font(.headline)
                // TextField 绑定到 binding 以后，你在键盘敲的每一个字都会瞬间写到底层硬盘里
                TextField("", text: binding.articleDate)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            // Authors 列表渲染区
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.L("Authors"))
                        .font(.headline)
                    Spacer()
                    // 添加新作者按钮
                    Button(action: {
                        binding.wrappedValue.authors.append(AuthorInfo(firstName: "", lastName: "", bio: ""))
                        ReadingTracker.shared.saveAllRecords()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text(state.L("Add Author"))
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.blue)
                }
                
                // 渲染已经添加的所有作者（如果是合著论文就会有很多个）
                ForEach(binding.wrappedValue.authors) { author in
                    if let index = binding.wrappedValue.authors.firstIndex(where: { $0.id == author.id }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Spacer()
                                if binding.wrappedValue.authors.count > 1 { // 如果只剩一个作者了，不让删
                                    Button(action: {
                                        binding.wrappedValue.authors.removeAll(where: { $0.id == author.id })
                                        ReadingTracker.shared.saveAllRecords()
                                    }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            // 调用我们下面定义的封装组件
                            AuthorInputView(author: binding.authors[index], state: state) {
                                ReadingTracker.shared.saveAllRecords()
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                        .padding(.bottom, 4)
                    }
                }
            }
            
            // Article Summary (摘要框)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Article Summary"))
                    .font(.headline)
                
                // 为了兼容低版本操作系统的不同边框风格而写的丑陋的分支逻辑
                if #available(macOS 12.0, iOS 15.0, *) {
                    TextEditor(text: binding.articleSummary) // TextEditor 是能输入多行文本的大文本框
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                } else {
                    TextEditor(text: binding.articleSummary)
                        .frame(minHeight: 120)
                        .border(Color.secondary.opacity(0.2), width: 1)
                }
            }
            
            Divider()
            
            // [遗忘曲线打分系统] (Rating System)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.L("Rating"))
                        .font(.headline)
                    Spacer()
                    TextField(state.L("Score (0-100)"), text: $ratingInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit { // 当你敲下回车的那一瞬间
                            // 安全检查：只能填 0-100 的数字
                            if let score = Int(ratingInput), score >= 0, score <= 100 {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "yyyy-MM-dd"
                                let dateStr = formatter.string(from: Date())
                                // 以今天为 Key，把分数存进字典
                                binding.wrappedValue.ratings[dateStr] = score
                                ReadingTracker.shared.saveAllRecords()
                                
                                // 回车打分后，强制让键盘自动收起 (降维打击底层 API 调用)
                                #if os(macOS)
                                DispatchQueue.main.async {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                }
                                #else
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                #endif
                            }
                        }
                }
                
                // 把打分的字典丢进画折线图的组件里渲染出来
                RatingLineChartView(ratings: binding.wrappedValue.ratings)
                    .frame(height: 150)
            }
        }
    }
    
    // [算法模块] 将成百上千页分散零碎的每页阅读时间，压缩合并成指定数量个小格子数据
    private func calculateSegments(record: DocumentRecord, segments: Int, pagesPerSegment: Double) -> [TimeInterval] {
        var data = [TimeInterval](repeating: 0, count: segments)
        for (pageIndex, duration) in record.pageDurations {
            let segmentIndex = Int(Double(pageIndex) / pagesPerSegment)
            if segmentIndex >= 0 && segmentIndex < segments {
                data[segmentIndex] += duration
            }
        }
        return data
    }
    
    // [颜色引擎] 根据数值大小，输出不同深浅浓淡的渐变颜色 (Opacity 处理)
    private func heatmapColor(for duration: TimeInterval, maxTime: TimeInterval) -> Color {
        guard duration > 0 else { return Color.clear } // 没看过的直接透明色
        
        // 把时长映射到 0.1 ~ 1.0 的透明度范围内
        let intensity = min(1.0, max(0.1, duration / maxTime))
        
        // 如果是从高级设置里填了 "#RRGGBB" 这种十六进制密码进来，得手动给它剥皮解析成原生 RGB 色值
        if heatmapColorTheme.hasPrefix("#") {
            let hex = heatmapColorTheme.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var int: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&int)
            let a, r, g, b: UInt64
            switch hex.count {
            case 3: // RGB (12-bit)
                (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
            case 6: // RGB (24-bit)
                (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
            case 8: // ARGB (32-bit)
                (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
            default:
                (a, r, g, b) = (255, 0, 0, 0)
            }
            let baseColor = Color(red: Double(r) / 255, green: Double(g) / 255, blue:  Double(b) / 255, opacity: Double(a) / 255)
            return baseColor.opacity(intensity) // 叠加涂层浓度！
        }
        
        // 普通枚举颜色的简单分支处理
        switch heatmapColorTheme {
        case "Red": return Color.red.opacity(intensity)
        case "Blue": return Color.blue.opacity(intensity)
        case "Green": return Color.green.opacity(intensity)
        case "Purple": return Color.purple.opacity(intensity)
        case "Yellow": return Color.yellow.opacity(intensity)
        default: return Color.red.opacity(intensity)
        }
    }
    
    // 把例如 4500 秒，转化成 "1h 15m" 人能看懂的漂亮字符串
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

/// [教程注释：智能作者联想输入框组件]
struct AuthorInputView: View {
    @Binding var author: AuthorInfo
    @ObservedObject var state: AppState
    var onCommit: () -> Void
    // 我们在这个组件里接入了我们在 Managers 里写的全局大脑数据库
    @ObservedObject var globalManager = GlobalAuthorManager.shared
    
    @State private var suggestions: [GlobalAuthor] = [] // 搜出来的人会装在这个数组里
    
    // [黑魔法拦截器] 当你在姓氏栏里每敲一个字的时候，我们偷偷拦下这个字，跑去数据库里进行模糊查询。
    private var lastNameBinding: Binding<String> {
        Binding<String>(
            get: { author.lastName },
            set: { newValue in
                author.lastName = newValue
                updateSuggestions(query: newValue) // 偷偷查
            }
        )
    }
    
    private var firstNameBinding: Binding<String> {
        Binding<String>(
            get: { author.firstName },
            set: { newValue in
                author.firstName = newValue
                updateSuggestions(query: newValue)
            }
        )
    }
    
    var body: some View {
        
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // 使用我们刚刚加工过的带有“监听窃听器”的数据管线
                TextField(state.L("Last Name"), text: lastNameBinding)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit { handleCommit() }
                
                TextField(state.L("First Name"), text: firstNameBinding)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit { handleCommit() }
            }
            
            // 如果底层大数据库搜出东西来了，我们在输入框下方把它像列表一样弹出来 (类似于百度搜索下拉框)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button(action: {
                            // 当你点击提示项，立刻把那个大佬的数据一键填入你的框里
                            author.firstName = suggestion.firstName
                            author.lastName = suggestion.lastName
                            author.bio = suggestion.bio
                            suggestions.removeAll() // 填好后销毁联想弹窗
                            onCommit()
                        }) {
                            VStack(alignment: .leading) {
                                Text(suggestion.name).bold()
                                Text(suggestion.bio).font(.caption).lineLimit(1).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        if suggestion != suggestions.last {
                            Divider()
                        }
                    }
                }
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .padding(.bottom, 4)
            }
            
            TextField(state.L("Author Bio"), text: $author.bio)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onSubmit {
                    onCommit()
                }
        }
    }
    
    private func handleCommit() {
        onCommit()
        suggestions.removeAll()
    }
    
    // 执行模糊搜索
    private func updateSuggestions(query: String) {
        let results = globalManager.search(query: query)
        // [防呆设计] 如果搜出来的那个人已经一字不差的显示在你框里了，那就别弹出来了，不然显得傻
        if results.count == 1 && results[0].firstName == author.firstName && results[0].lastName == author.lastName && author.bio == results[0].bio {
            suggestions = []
        } else {
            suggestions = results
        }
    }
}

// MARK: - Rating Line Chart View
/// [教程注释：纯手工打造的评分折线图引擎]
/// 为什么不引入第三方图表库（比如 Swift Charts）？为了极简和向后兼容旧系统。
/// 所以这个组件完全使用 SwiftUI 最底层的 Path (画笔引擎) 从零开始画出的一个走势图。
struct RatingLineChartView: View {
    // 字典格式： ["2023-10-01": 80, "2023-11-05": 90]
    var ratings: [String: Int]
    @AppStorage("ratingChartColorTheme") var ratingChartColorTheme: String = "Blue"
    
    // 解析用户设置的主题色
    private var themeColor: Color {
        if ratingChartColorTheme.hasPrefix("#") {
            #if os(macOS)
            return Color(nsColor: NSColor(hex: ratingChartColorTheme) ?? .blue)
            #else
            return .blue
            #endif
        }
        switch ratingChartColorTheme {
        case "Red": return .red
        case "Yellow": return .yellow
        case "Green": return .green
        case "Purple": return .purple
        case "Blue": fallthrough
        default: return .blue
        }
    }
    
    var body: some View {
        // 先按时间字符串排序，这样折线在 X 轴上才能按时序展开
        let sortedEntries = ratings.sorted { $0.key < $1.key }
        
        if sortedEntries.isEmpty {
            Text("No Data")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
        } else {
            // GeometryReader：图表渲染必须精确知道长宽才能算坐标系统
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                
                // 定制画布边距，给周围留白给坐标轴文字留位子
                let leftMargin: CGFloat = 30
                let bottomMargin: CGFloat = 20
                let topMargin: CGFloat = 10
                let rightMargin: CGFloat = 10
                
                // 真正的图表可画范围
                let chartWidth = width - leftMargin - rightMargin
                let chartHeight = height - topMargin - bottomMargin
                
                // [数学与坐标系转换核心]
                // 预先算好每一个打分记录在屏幕上落在哪个 (x,y) 像素点上
                let stepX = sortedEntries.count > 1 ? chartWidth / CGFloat(sortedEntries.count - 1) : 0
                let points: [CGPoint] = sortedEntries.enumerated().map { index, entry in
                    let x = sortedEntries.count > 1 ? leftMargin + CGFloat(index) * stepX : leftMargin + chartWidth / 2
                    // 算出这个分数的相对高度百分比 (满分100)，再算在 chartHeight 里占比多少，再扣除边距的落差。
                    // 注意：屏幕上的 Y 轴 0 是在最上面！所以要反着减去。
                    let y = topMargin + chartHeight - CGFloat(entry.value) / 100.0 * chartHeight
                    return CGPoint(x: x, y: y)
                }
                
                // 像汉堡一样层叠把图层盖上来
                ZStack {
                    // [最底层：网格刻度线与虚线]
                    // 画出 0, 20, 40, 60, 80, 100 五根横线
                    ForEach(0...5, id: \.self) { i in
                        let score = i * 20
                        let y = topMargin + chartHeight - CGFloat(score) / 100.0 * chartHeight
                        
                        // 举起画笔，在这个坐标系里画一条横的虚线
                        Path { path in
                            path.move(to: CGPoint(x: leftMargin, y: y))
                            path.addLine(to: CGPoint(x: width - rightMargin, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])) // dash:[5] 也就是每画5像素停一下，形成了虚线！
                        
                        // 写在虚线旁边的分数标签
                        Text("\(score)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .position(x: leftMargin / 2, y: y)
                    }
                    
                    // [中层：折线主干]
                    // 拿着刚才算好的 points 数组，一笔连成线！
                    if points.count > 1 {
                        Path { path in
                            path.addLines(points)
                        }
                        .stroke(themeColor, lineWidth: 2) // 用 2 的线宽画出来
                    }
                    
                    // [顶层：拐点的小圆圈 和 X轴的时间标签]
                    ForEach(Array(zip(sortedEntries.indices, sortedEntries)), id: \.0) { index, entry in
                        let point = points[index]
                        
                        // 盖在拐点上的实心小圆点
                        Circle()
                            .fill(themeColor)
                            .frame(width: 6, height: 6)
                            .position(point)
                        
                        // 优化逻辑：如果记录有成千上百个，字挤在一起肯定变黑煤球了。
                        // 这里做个判断，只有总数较少，或者是首尾、最中央那几条线才配在底部打字显示日期。
                        if sortedEntries.count <= 7 || index == 0 || index == sortedEntries.count - 1 || index == sortedEntries.count / 2 {
                            Text(String(entry.key.suffix(5))) // suffix(5) 就是只显示月日(MM-dd)，把冗长的年份切掉
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                                .position(x: point.x, y: height - bottomMargin / 2)
                        }
                    }
                }
            }
        }
    }
}
