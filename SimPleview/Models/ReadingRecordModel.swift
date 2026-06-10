import Foundation

/// [教程注释：Codable 与 数据持久化]
/// `AuthorInfo` 结构体代表了一个作者的简要信息。
/// 遵循 `Codable` 协议是 Swift 极度强大的特性，它让我们可以通过仅仅一行代码，将整个结构体转换为 JSON 或从 JSON 解析出来。
/// 遵循 `Identifiable` 协议用于 SwiftUI 列表；`Equatable` 用于状态对比；`Sendable` 保证在并发任务中安全传递。
struct AuthorInfo: Codable, Identifiable, Equatable, Sendable {
    // [核心概念：UUID]
    // 通用唯一识别码。在创建时自动生成，保证每个作者记录在列表中是绝对唯一的，不会因为同名而导致 SwiftUI 渲染错乱。
    var id: UUID = UUID()
    var firstName: String
    var lastName: String
    var bio: String
    
    // [教程注释：计算属性处理中英文字符]
    // 动态计算作者的完整显示名称。
    var name: String {
        // [逻辑流程]
        // 1. 去除首尾的空格和换行符，防止用户输入脏数据
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return last }
        if last.isEmpty { return first }
        
        // 2. 利用正则表达式检测是否包含汉字 (\p{Han} 是汉字的 Unicode 匹配模式)
        let hasChinese = (last + first).range(of: "\\p{Han}", options: .regularExpression) != nil
        
        // 3. 如果是中文，姓和名连在一起显示；如果是外文，中间加一个空格。
        if hasChinese {
            return "\(last)\(first)"
        } else {
            return "\(last) \(first)"
        }
    }
    
    // [教程注释：定制 JSON 字段映射]
    // CodingKeys 枚举用来告诉 Swift 编解码器（JSONDecoder），我们想保存哪些字段。
    // 注意这里我们甚至把计算属性 `name` 也加进去了，以便老版本的兼容读取。
    enum CodingKeys: String, CodingKey {
        case id, firstName, lastName, bio, name
    }
    
    nonisolated init(firstName: String = "", lastName: String = "", bio: String = "") {
        self.firstName = firstName
        self.lastName = lastName
        self.bio = bio
    }
    
    // [教程注释：自定义解码器 (向后兼容)]
    // 很多时候 App 会升级，数据结构会变。通过自定义 `init(from decoder:)`，
    // 我们能读取旧版本的 JSON（只有一个 `name` 字段），并智能拆分为新的 `firstName` 和 `lastName`。
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 使用 decodeIfPresent 尝试解析，如果 JSON 里面没这个字段，就给个默认值。这是防止崩溃的利器。
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bio = try container.decodeIfPresent(String.self, forKey: .bio) ?? ""
        
        // [逻辑流程：平滑升级老数据]
        if let fName = try? container.decode(String.self, forKey: .firstName),
           let lName = try? container.decode(String.self, forKey: .lastName) {
            // 如果能读到新版的字段，直接赋值
            firstName = fName
            lastName = lName
        } else {
            // 否则尝试读取老版本的 `name` 字段，并根据空格切分成姓和名
            let oldName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            let parts = oldName.split(separator: " ")
            if parts.count > 1 {
                lastName = String(parts.last!)
                // dropLast() 去掉数组最后一个元素，剩余的重新拼成名
                firstName = parts.dropLast().joined(separator: " ")
            } else {
                lastName = oldName
                firstName = ""
            }
        }
    }
    
    // [教程注释：自定义编码器]
    // 配合上面的解码器，我们在保存为 JSON 时，明确指定要保存的字段。
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(bio, forKey: .bio)
    }
}

/// [教程注释：PDF 阅读记录核心模型]
/// 代表了一份 PDF 文档在当前 App 中的所有阅读统计数据。
/// 它会作为一个单独的 JSON 文件持久化保存在沙盒的 Documents 目录中。
struct DocumentRecord: Codable, Sendable {
    /// 稳定标识符，通常是文件名（Title），作为跨设备或重启后的唯一凭证。
    var documentID: String
    
    /// 文档展示标题。
    var documentTitle: String
    
    /// [核心概念：TimeInterval]
    /// 本质上是 Double 类型，单位是秒。记录了所有阅读会话累加的总时长。
    var totalReadingTime: TimeInterval
    
    /// [教程注释：字典映射]
    /// 一个用来记录每一页看了多久的字典（哈希表）。
    /// Key: 页码索引 (0 递增)
    /// Value: 在这一页停留的总秒数。
    var pageDurations: [Int: TimeInterval]
    
    /// 准确记录最后一次阅读的时间戳。
    var lastReadDate: Date
    
    // MARK: - Metadata (元数据区块)
    var articleDate: String
    var authors: [AuthorInfo]
    var articleSummary: String
    
    // 记录哪一天对这篇文章打了多少分。例如 "2026-05-29" : 85
    var ratings: [String: Int] 
    
    enum CodingKeys: String, CodingKey {
        case documentID, documentTitle, totalReadingTime, pageDurations, lastReadDate, articleDate, authors, articleSummary, ratings
    }
    
    nonisolated init(documentID: String, documentTitle: String) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.totalReadingTime = 0
        self.pageDurations = [:]
        self.lastReadDate = Date()
        self.articleDate = ""
        self.authors = []
        self.articleSummary = ""
        self.ratings = [:]
    }
    
    // [教程注释：JSON 字典键值转换陷阱]
    // JSON 标准规范中，Object (字典) 的 Key 必须是字符串！
    // 但是我们的 `pageDurations` 字典是 `[Int: TimeInterval]`。
    // Swift 标准库有时能自动处理，但为了绝对的安全和兼容旧数据，我们在这里手动拦截并进行 Int 到 String 的双向转换。
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try container.decode(String.self, forKey: .documentID)
        documentTitle = try container.decode(String.self, forKey: .documentTitle)
        totalReadingTime = try container.decode(TimeInterval.self, forKey: .totalReadingTime)
        lastReadDate = try container.decode(Date.self, forKey: .lastReadDate)
        
        // 尝试以 [String: TimeInterval] 的形式读取，并手动将其转回 [Int: TimeInterval]
        if let dict = try? container.decode([String: TimeInterval].self, forKey: .pageDurations) {
            var intDict = [Int: TimeInterval]()
            for (key, val) in dict {
                if let i = Int(key) {
                    intDict[i] = val
                }
            }
            pageDurations = intDict
        } else {
            // 如果读取失败，尝试使用原生解码逻辑，再失败则给个空字典 `[:]`
            pageDurations = try container.decodeIfPresent([Int: TimeInterval].self, forKey: .pageDurations) ?? [:]
        }
        
        articleDate = try container.decodeIfPresent(String.self, forKey: .articleDate) ?? ""
        authors = try container.decodeIfPresent([AuthorInfo].self, forKey: .authors) ?? []
        articleSummary = try container.decodeIfPresent(String.self, forKey: .articleSummary) ?? ""
        ratings = try container.decodeIfPresent([String: Int].self, forKey: .ratings) ?? [:]
    }
    
    // 同理，保存数据为 JSON 时，把 [Int: TimeInterval] 字典拆解转换为 [String: TimeInterval] 的绝对安全格式。
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(documentTitle, forKey: .documentTitle)
        try container.encode(totalReadingTime, forKey: .totalReadingTime)
        try container.encode(lastReadDate, forKey: .lastReadDate)
        
        var strDict = [String: TimeInterval]()
        for (key, val) in pageDurations {
            strDict[String(key)] = val
        }
        try container.encode(strDict, forKey: .pageDurations)
        
        try container.encode(articleDate, forKey: .articleDate)
        try container.encode(authors, forKey: .authors)
        try container.encode(articleSummary, forKey: .articleSummary)
        try container.encode(ratings, forKey: .ratings)
    }
}
