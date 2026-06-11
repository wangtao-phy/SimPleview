import SwiftUI
import Combine

/// [教程注释：全局作者管理面板]
/// 这是一个复杂的两列经典 Mac 风格面板。
/// 左边是所有的作者列表，支持按照“拼音(A-Z)”或者“著作数量”排序。
/// 右边则是选中后的信息修改详情面板。
/// 这个界面就像是整个学术管理大脑的核心中枢，增删改查无所不能。
struct GlobalAuthorsSettingsView: View {
    // 翻译工具函数外包传入
    let LS: (String) -> String
    
    // 直接接入我们的全局智能大脑（大内总管：GlobalAuthorManager）
    // ObservedObject 意味着只要大脑发出重绘信号，这整个界面都会在一秒内刷新。
    @ObservedObject var globalManager = GlobalAuthorManager.shared
    
    // 左侧列表采用哪种排序模式
    @AppStorage("authorSortMode") var authorSortMode: String = "pinyin"
    
    // UI状态：目前用户选中了哪个作者的 ID
    @State private var selectedAuthorID: UUID? = nil
    
    // [动态计算引擎：实时排序系统]
    // 只要有任何数据改动，或者排序模式被点选切换，这个计算属性就会被重新调用。
    private var sortedAuthors: [GlobalAuthor] {
        if authorSortMode == "works" {
            // [模式 1：按著作数量排序]
            // 如果两位大牛写的论文一样多，那就根据“最后使用时间（谁刚更新的）”来排
            return globalManager.authors.values
                .sorted {
                    if $0.documentIDs.count != $1.documentIDs.count {
                        return $0.documentIDs.count > $1.documentIDs.count // 降序（多的在上面）
                    }
                    return $0.lastUsed > $1.lastUsed
                }
        } else {
            // [模式 2：按拼音字母排序] (类似于通讯录)
            return globalManager.authors.values
                .sorted {
                    if $0.pinyinInitial != $1.pinyinInitial {
                        return $0.pinyinInitial < $1.pinyinInitial // 升序（A在最上面）
                    }
                    return $0.lastUsed > $1.lastUsed
                }
        }
    }
    
    // [数据重组引擎：分组系统 (Grouping)]
    // 当我们用拼音排序时，需要像通讯录一样把人按 [A] [B] [C] 的头衔括起来。
    // 这里把一个扁平的一维数组，变成了一个“数组中的数组（二维结构）”。
    private var groupedAuthors: [(initial: String, authors: [GlobalAuthor])] {
        var groups = [String: [GlobalAuthor]]()
        for author in sortedAuthors {
            groups[author.pinyinInitial, default: []].append(author)
        }
        // 最后把字典按 A-Z 强行排序再输出，否则字典输出是无序混乱的
        return groups.sorted(by: { $0.key < $1.key }).map { (initial: $0.key, authors: $0.value) }
    }
    
    // 把左侧单行名字的 UI 渲染提炼成一个局部小方法，防止后面写出“面条代码”
    @ViewBuilder
    private func authorRow(_ author: GlobalAuthor) -> some View {
        Text(author.name)
            .tag(author.id) // 绑定选中态！
            .contextMenu { // 埋一个隐蔽的右键菜单
                Button(role: .destructive) { // .destructive 角色会让字体自动变红
                    // 彻底删除这个作者
                    globalManager.delete(name: author.name)
                    if selectedAuthorID == author.id {
                        selectedAuthorID = nil // 把焦点也一起清空
                    }
                } label: {
                    Text(LS("Delete"))
                }
            }
    }
    
    var body: some View {
        HStack(spacing: 0) { // 两栏布局，中间不允许留缝隙
            
            // [左栏：Master List (主列表)]
            VStack(spacing: 0) {
                
                // 顶部的排序切换器
                Picker("", selection: $authorSortMode) {
                    Text(LS("Sort by Pinyin")).tag("pinyin")
                    Text(LS("Sort by Works Count")).tag("works")
                }
                .pickerStyle(.menu)
                .padding(6)
                
                Divider() // 一条冷酷的分割线
                
                // 中部的核心列表
                List(selection: $selectedAuthorID) {
                    if authorSortMode == "pinyin" {
                        // 有 [A] [B] 开头的情况
                        ForEach(groupedAuthors, id: \.initial) { group in
                            Section(header: Text(group.initial).id(group.initial)) {
                                ForEach(group.authors) { author in
                                    authorRow(author)
                                }
                            }
                        }
                    } else {
                        // 按著作量排的情况，没有任何小标题头，就直接渲染
                        ForEach(sortedAuthors) { author in
                            authorRow(author)
                        }
                    }
                }
                .listStyle(.inset)
                
                // 底部的 [+][-] 小操作条，这是非常复古和经典的 Mac 设计
                HStack(spacing: 0) {
                    // [+] 添加按钮
                    Button(action: {
                        // 命令大脑新增一个名叫“Unknown”的无名氏，并自动将其选中。
                        let newName = globalManager.addBlankAuthor()
                        if let author = globalManager.authors[newName] {
                            selectedAuthorID = author.id
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                            .frame(width: 30, height: 30)
                            // [黑客技巧] 用极低极低透明度的黑色当底板，这样就能把 30x30 的框全部变成可点击区域。如果不加，你就必须用针尖一样的准度点击那根细细的加号线条才行。
                            .background(Color.black.opacity(0.001))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain) // 剥去原生边框
                    
                    Divider().frame(height: 14) // 按钮之间的小竖线
                    
                    // [-] 删除按钮
                    Button(action: {
                        if let id = selectedAuthorID, let author = sortedAuthors.first(where: { $0.id == id }) {
                            globalManager.delete(name: author.name)
                            selectedAuthorID = nil
                        }
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 14))
                            .frame(width: 30, height: 30)
                            .background(Color.black.opacity(0.001))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Spacer() // 靠左对齐推手
                }
                // 根据平台的背景颜色调整这根底部栏底色
                #if os(macOS)
                .background(Color(NSColor.controlBackgroundColor))
                #else
                .background(Color(UIColor.secondarySystemBackground))
                #endif
                .overlay(Divider(), alignment: .top) // 在上面再压一条横线盖住列表
            }
            // [UI布局] 这里控制全局作者库框中左侧列表的绝对宽度
            // 您可以通过修改 180 这个值来让左边的作者列表变宽或变窄
            .frame(width: 180)
            
            Divider() // 左右两栏中间的大脊椎线！
            
            // [右栏：Detail View (详情视图)]
            ZStack {
                // 如果有被选中的大佬信息，才渲染编辑板
                if let id = selectedAuthorID, let author = sortedAuthors.first(where: { $0.id == id }) {
                    AuthorDetailEditor(author: author, globalManager: globalManager, selection: $selectedAuthorID, LS: LS)
                        // 用 id 标记，保证当你换一个人点的时候，整个界面会硬刷新状态，不留上一人的残留。
                        .id(author.id) 
                } else {
                    // 没人被选中时的占位空状态
                    Text(LS("Select an author"))
                        .foregroundColor(.secondary)
                }
            }
            // [UI布局] 彻底放弃 GeometryReader，直接使用 SwiftUI 的自动弹簧布局，让右侧吃掉所有剩余空间，解决加载瞬间闪烁的问题。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .border(Color(NSColor.gridColor)) // 给整个大界面外面套一个精装盒子
        #else
        .border(Color.secondary.opacity(0.3))
        #endif
        // [UI布局] 整个全局作者编辑大框的高度，加大到 350 以留出更多 Bio 空间
        .frame(height: 350)
    }
}

/// [教程注释：右侧详情信息编辑黑板]
/// 可以在这里对选中的大佬的名字和生平进行全方位篡改！
struct AuthorDetailEditor: View {
    // 外接传入的原始数据
    var author: GlobalAuthor
    var globalManager: GlobalAuthorManager
    @Binding var selection: UUID?
    let LS: (String) -> String
    
    // [局部状态机：草稿纸]
    // 为什么不直接绑定到 `author.firstName` 上？
    // 因为这是个系统级的设置，一旦名字改错一个字，可能会影响全库数以万计的关联操作。
    // 所以我们用“草稿纸”模式，你在键盘敲的字都在草稿里，按回车的那一瞬间，才“提交 (submit)”给大内总管。
    @State private var draftFirstName: String = ""
    @State private var draftLastName: String = ""
    @State private var draftBio: String = ""
    
    // [回音消除器] 用于过滤我们自己手打触发的全局界面刷新，彻底消灭光标跳动，无需 FocusState
    @State private var recentSubmissions = Set<String>()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // 姓名双拼
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("Last Name")).font(.caption).foregroundColor(.secondary)
                    TextField("", text: $draftLastName)
                        #if os(macOS)
                        .focusEffectDisabled()
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit { update() }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("First Name")).font(.caption).foregroundColor(.secondary)
                    TextField("", text: $draftFirstName)
                        #if os(macOS)
                        .focusEffectDisabled()
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit { update() }
                }
            }
            
            // 生平传记框
            VStack(alignment: .leading, spacing: 4) {
                // 如果翻译词典里没有 Bio 的翻译，默认会返回原文，这里我们可以用 "Bio"
                Text(LS("Bio")).font(.caption).foregroundColor(.secondary)
                // 0延迟即时保存 + 回音消除机制
                if #available(macOS 12.0, iOS 15.0, *) {
                    TextEditor(text: $draftBio)
                        .font(.body)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                } else {
                    TextEditor(text: $draftBio)
                        .font(.body)
                        .border(Color.secondary.opacity(0.2), width: 1)
                }
            }
            
            // 光荣榜：显示这人目前被几篇论文署名了。
            Text("\(author.documentIDs.count) \(LS("Works"))")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding()
        // [生命周期钩子] 这个界面“一睁眼出现(appear)”的时候，立刻照着传进来的大牛抄一份数据进草稿本。
        .onAppear {
            draftFirstName = author.firstName
            draftLastName = author.lastName
            draftBio = author.bio
        }
        // 兼容所有 macOS 版本的无警告数据流监听
        .onReceive(Just(draftBio)) { newValue in
            // 如果草稿跟当前全局的一样，说明我们没改，忽略
            if newValue == author.bio { return }
            
            // 记录下我们发出去的文本
            recentSubmissions.insert(newValue)
            update()
        }
        .onReceive(Just(author)) { newAuthor in
            // 外部（例如侧边栏）发生更新时，收到了新的 author 对象
            
            // 只有当名字有外部变动时才同步名字
            if draftFirstName != newAuthor.firstName { draftFirstName = newAuthor.firstName }
            if draftLastName != newAuthor.lastName { draftLastName = newAuthor.lastName }
            
            // 【核心防跳器】如果这个 bio 恰好是我们不久前自己发出去的“回音”，就忽略它！
            if recentSubmissions.contains(newAuthor.bio) {
                recentSubmissions.remove(newAuthor.bio)
                return
            }
            
            // 如果不是我们的回音，说明侧边栏真真切切被别人改了！乖乖同步并抹除跳动。
            if draftBio != newAuthor.bio {
                draftBio = newAuthor.bio
                recentSubmissions.removeAll()
            }
        }
        .onDisappear {
            // 兜底保存，防止直接关掉窗口
            update()
        }
    }
    
    // [大内核心：发令改名]
    private func update() {
        let newFirst = draftFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLast = draftLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        globalManager.updateAuthor(oldName: author.name, newFirstName: newFirst, newLastName: newLast, newBio: draftBio)
    }
}
