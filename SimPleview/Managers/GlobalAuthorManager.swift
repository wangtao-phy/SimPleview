import Foundation
import Combine

/// [教程注释：全局作者数据结构]
/// 这个结构体是用来抽象和存储“跨越多篇 PDF”的全局作者实体。
/// 它不仅包含了基本的姓名和履历，还通过 `documentIDs` 关联了该作者参与过的所有文献。
struct GlobalAuthor: Codable, Identifiable, Equatable {
    var id = UUID()
    var firstName: String
    var lastName: String
    /// 作者个人简介或科研方向
    var bio: String
    /// 上次该作者被检索或修改的时间，用于在搜索时把“最近热点”作者排在最上面
    var lastUsed: Date
    /// 这个作者参与写了哪些文章？（存放 Document ID 集合）
    var documentIDs: Set<String> = []
    
    // [动态计算属性：智能姓名拼接]
    // 这是个很有意思的细节：中文习惯姓在前名在后（如 王涛），而英文习惯名在前姓在后（如 John Doe）。
    // 这个属性会自动侦测如果是中文字符，就去掉中间的空格。
    nonisolated var name: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return last }
        if last.isEmpty { return first }
        
        let hasChinese = (last + first).range(of: "\\p{Han}", options: .regularExpression) != nil
        if hasChinese {
            return "\(last)\(first)"
        } else {
            return "\(last) \(first)" // 英文名字中间加空格
        }
    }
    
    // [底层转换：拼音首字母提取]
    // 为了实现类似通讯录右侧边栏那种 A-Z 导航条的需求。
    nonisolated var pinyinInitial: String {
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameToUse = last.isEmpty ? firstName : last
        guard !nameToUse.isEmpty else { return "#" }
        
        // 使用苹果极其强大但极其底层的 CoreFoundation 库进行拼音和变音符号剥离
        let mutableString = NSMutableString(string: String(nameToUse.prefix(1)))
        CFStringTransform(mutableString, nil, kCFStringTransformToLatin, false) // 转拼音
        CFStringTransform(mutableString, nil, kCFStringTransformStripDiacritics, false) // 剥离音调
        let firstChar = String(mutableString).uppercased().prefix(1)
        
        let initial = String(firstChar)
        let letters = CharacterSet.letters
        if initial.unicodeScalars.allSatisfy({ letters.contains($0) }) {
            return initial
        }
        return "#" // 数字和特殊符号统归于 #
    }
    
    // 为了满足 Codable 的自定义序列化，指定我们要存入 JSON 硬盘里的字段
    enum CodingKeys: String, CodingKey {
        case firstName, lastName, bio, lastUsed, documentIDs, name
    }
    
    init(id: UUID = UUID(), firstName: String, lastName: String, bio: String, lastUsed: Date, documentIDs: Set<String> = []) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.bio = bio
        self.lastUsed = lastUsed
        self.documentIDs = documentIDs
    }
    
    // [版本兼容适配器：解码器 (Decoder)]
    // 因为这套数据结构之前重构过（原来只有一个 name，后来拆成了 firstName 和 lastName）。
    // 为了兼容用户硬盘里的老版本数据，我们在解码时写了“向后兼容逻辑”。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bio = try container.decode(String.self, forKey: .bio)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        documentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .documentIDs) ?? []
        id = UUID()
        
        // 尝试解析新的字段
        if let fName = try? container.decode(String.self, forKey: .firstName),
           let lName = try? container.decode(String.self, forKey: .lastName) {
            firstName = fName
            lastName = lName
        } else {
            // 解析失败？说明是老格式，咱们自己把老的字符串以空格切开，强行转成新格式。
            let oldName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            let parts = oldName.split(separator: " ")
            if parts.count > 1 {
                lastName = String(parts.last!)
                firstName = parts.dropLast().joined(separator: " ")
            } else {
                lastName = oldName
                firstName = ""
            }
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(bio, forKey: .bio)
        try container.encode(lastUsed, forKey: .lastUsed)
        try container.encode(documentIDs, forKey: .documentIDs)
    }
}

/// [教程注释：全局作者管理器]
/// 负责操作储存在硬盘上的那个巨型 `GlobalAuthors.json` 文件。
/// 这个文件记录了你这辈子看过的所有文献背后的科学家，为你在录入新文献时提供输入法般的自动补全！
class GlobalAuthorManager: ObservableObject {
    // 典型的单例模式 (Singleton)，全 App 只有一个管家婆
    static let shared = GlobalAuthorManager()
    
    // 存放在内存里的数据库核心。键 (Key) 是作者的全名。
    @Published var authors: [String: GlobalAuthor] = [:]
    
    private init() {
        loadAuthors()
    }
    
    // 这个数据库存放在哪儿？和阅读记录在同一个文件夹下
    private var fileURL: URL {
        ReadingTracker.shared.saveDirectoryURL.appendingPathComponent("GlobalAuthors.json")
    }
    
    // [加载数据]
    // 必须同步加载！否则如果在 App 启动初期用户立刻关闭标签页触发 upsert，
    // 后台加载还没完成，此时内存为 [:]，upsert 会直接覆盖并清空整个硬盘的旧数据！这是极其危险的 Race Condition！
    func loadAuthors() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: GlobalAuthor].self, from: data)
            
            // 为了防止部分旧数据的 Key 不对齐，我们做一次重新映射。
            var migrated: [String: GlobalAuthor] = [:]
            for (_, author) in decoded {
                migrated[author.name] = author
            }
            
            self.authors = migrated
            // 校验并在后台统计
            self.recalculateArticleCounts()
        } catch {
            print("Failed to load GlobalAuthors.json: \(error)")
        }
    }
    
    // [核心校验系统：论文索引校准仪]
    /// Scans all DocumentRecord JSON files to ensure accurate article counts for all global authors.
    /// 这个函数会在后台扫一遍所有独立的文献阅读记录 (成百上千个小 json)。
    /// 将每一篇文献里登记的作者，反向汇总给这个作者本人，从而纠正他的 `documentIDs` 集合。
    func recalculateArticleCounts() {
        let directoryURL = ReadingTracker.shared.saveDirectoryURL
        // [专家级防泄漏]
        DispatchQueue.global(qos: .background).async { [weak self] in
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                let jsonFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "GlobalAuthors.json" }
                
                var authorToDocs: [String: Set<String>] = [:]
                // 为了提高解码速度，专门定制的极简轻量级结构体，只扫这两个字段！
                struct TempRecord: Codable {
                    var documentID: String
                    var authors: [AuthorInfo]
                }
                
                let decoder = JSONDecoder()
                
                // 地毯式搜索
                for file in jsonFiles {
                    do {
                        let data = try Data(contentsOf: file)
                        let record = try decoder.decode(TempRecord.self, from: data)
                        let docID = record.documentID
                        for author in record.authors {
                            let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { continue }
                            authorToDocs[name, default: []].insert(docID)
                        }
                    } catch {
                        continue
                    }
                }
                
                // 比对并写入
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    var changed = false
                    for (name, existing) in self.authors {
                        let actualDocs = authorToDocs[name] ?? []
                        if existing.documentIDs != actualDocs {
                            var updated = existing
                            updated.documentIDs = actualDocs
                            self.authors[name] = updated
                            changed = true
                        }
                    }
                    if changed {
                        self.saveAuthors()
                    }
                }
            } catch {
                // Ignore
            }
        }
    }
    
    // 将整个内存库一次性序列化并进行原子保存 (Atomic Save)
    func saveAuthors() {
        let url = fileURL
        let currentAuthors = self.authors // Copy value type for thread safety 值拷贝，保护线程安全
        DispatchQueue.global(qos: .background).async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(currentAuthors)
                try data.write(to: url, options: .atomic)
            } catch {
                // Ignore
            }
        }
    }
    
    // [混合体操作：插入或更新 (Upsert)]
    /// 当用户正在阅读一篇文献并保存其信息时，触发此函数。
    /// 它会自动抽取出里面的作者数据喂给这个全局库：有则更新简历，无则新建档案。
    func upsert(_ authorsToUpsert: [(String, AuthorInfo)]) {
        DispatchQueue.main.async {
            var changed = false
            for (docID, author) in authorsToUpsert {
                let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                
                if var existing = self.authors[name] {
                    // 更新现有档案：看看是否有新的简介，以及这篇论文是不是新增给他的
                    let bioChanged = existing.bio != author.bio
                    let newDocAdded = existing.documentIDs.insert(docID).inserted
                    
                    if bioChanged || newDocAdded {
                        existing.bio = author.bio
                        existing.lastUsed = Date() // 提高这名作者的热度
                        self.authors[name] = existing
                        changed = true
                    }
                } else {
                    // 全新作者建档
                    self.authors[name] = GlobalAuthor(firstName: author.firstName, lastName: author.lastName, bio: author.bio, lastUsed: Date(), documentIDs: [docID])
                    changed = true
                }
            }
            
            if changed {
                self.saveAuthors()
            }
        }
    }
    
    // 删除作者档案
    func delete(name: String) {
        if self.authors.removeValue(forKey: name) != nil {
            self.saveAuthors()
        }
    }
    
    // [体验优化：新建空白作者]
    /// 生成一个像 "New Author 1", "New Author 2" 这种不会冲突的名字返回给 UI，用作默认占位
    func addBlankAuthor() -> String {
        var counter = 1
        var newAuthor = GlobalAuthor(firstName: "Author", lastName: "New", bio: "", lastUsed: Date(), documentIDs: [])
        
        while self.authors[newAuthor.name] != nil {
            counter += 1
            newAuthor = GlobalAuthor(firstName: "Author \(counter)", lastName: "New", bio: "", lastUsed: Date(), documentIDs: [])
        }
        
        let actualName = newAuthor.name
        self.authors[actualName] = newAuthor
        self.saveAuthors()
        return actualName
    }
    
    // [复杂操作：更新作者基础资料]
    // 当由于名字打错了，用户强制修改名字时，因为字典 Key 必须换掉，所以会有一些转移逻辑。
    func updateAuthor(oldName: String, newFirstName: String, newLastName: String, newBio: String) {
        guard let existing = self.authors[oldName] else { return }
        
        var updated = existing
        updated.firstName = newFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.lastName = newLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.bio = newBio
        
        let newFullName = updated.name
        
        if newFullName != oldName && !newFullName.isEmpty {
            // Key 变了，先删老 Key，再存新 Key
            self.authors.removeValue(forKey: oldName)
            self.authors[newFullName] = updated
        } else {
            // 名字没变，单纯更新下内部属性
            self.authors[oldName] = updated
        }
        self.saveAuthors()
    }

    
    // [搜索引擎核心：输入法联想系统]
    /// 根据用户在搜索框里打出的字，返回最有可能匹配的前面几个作者推荐，并按近期“热度”倒序排列。
    func search(query: String) -> [GlobalAuthor] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else { return [] }
        
        return authors.values
            .filter { 
                $0.name.lowercased().contains(cleanQuery) || 
                $0.firstName.lowercased().contains(cleanQuery) || 
                $0.lastName.lowercased().contains(cleanQuery) 
            }
            .sorted { $0.lastUsed > $1.lastUsed } // Recently used first
    }
    
    // 从头重新刷新所有数据
    func reload() {
        DispatchQueue.main.async {
            self.authors.removeAll()
            self.loadAuthors()
        }
    }
}
