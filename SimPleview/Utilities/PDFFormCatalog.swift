import Foundation
import CoreGraphics
import PDFKit

/// PDFKit 会保存页面上的 Widget，却不一定把新增字段登记到 /AcroForm/Fields。
/// 这里只补齐本应用新写出的未加密、传统 xref 临时 PDF；不重绘页面、不改原字段树。
/// 不支持的结构直接抛错，由外层保存事务保留原文件。
@MainActor enum PDFFormCatalog {
    private struct Reference: Hashable {
        let number: Int
        let generation: Int
        var text: String { "\(number) \(generation) R" }
    }
    private struct Entry {
        let offset: Int
        let generation: Int
    }
    private struct Dictionary {
        let range: Range<Int>
        let values: [String: Range<Int>]
    }
    private struct Reader {
        let data: Data
        var position: Int
        private func delimiter(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32, 40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte) }
        mutating func token() throws -> Range<Int> {
            while position < data.count {
                if [0, 9, 10, 12, 13, 32].contains(data[position]) { position += 1 }
                else if data[position] == 37 {
                    while position < data.count && data[position] != 10 && data[position] != 13 { position += 1 }
                } else { break }
            }
            guard position < data.count else { throw PDFFormCatalog.invalid() }
            let start = position, byte = data[position]
            position += 1
            if byte == 40 {
                var depth = 1
                while position < data.count && depth > 0 {
                    let next = data[position]; position += 1
                    if next == 92 { guard position < data.count else { throw PDFFormCatalog.invalid() }; position += 1 }
                    else if next == 40 { depth += 1 }
                    else if next == 41 { depth -= 1 }
                }
                guard depth == 0 else { throw PDFFormCatalog.invalid() }
            } else if byte == 60 {
                if position < data.count && data[position] == 60 { position += 1 }
                else {
                    while position < data.count && data[position] != 62 { position += 1 }
                    guard position < data.count else { throw PDFFormCatalog.invalid() }; position += 1
                }
            } else if byte == 62 {
                if position < data.count && data[position] == 62 { position += 1 }
            } else if byte == 47 {
                while position < data.count && !delimiter(data[position]) { position += 1 }
            } else if !delimiter(byte) {
                while position < data.count && !delimiter(data[position]) { position += 1 }
            }
            return start..<position
        }
        func text(_ range: Range<Int>) -> String { String(decoding: data[range], as: UTF8.self) }
        private func key(_ range: Range<Int>) throws -> String {
            var result = Data(), index = range.lowerBound
            while index < range.upperBound {
                if data[index] == 35 {
                    guard index + 2 < range.upperBound,
                          let byte = UInt8(text((index + 1)..<(index + 3)), radix: 16) else { throw PDFFormCatalog.invalid() }
                    result.append(byte); index += 3
                } else { result.append(data[index]); index += 1 }
            }
            return String(decoding: result, as: UTF8.self)
        }
        mutating func value(depth: Int = 0) throws -> Range<Int> {
            guard depth < 64 else { throw PDFFormCatalog.invalid() }
            let first = try token(), kind = text(first)
            if kind == "<<" || kind == "[" {
                let end = kind == "<<" ? ">>" : "]"
                while true {
                    let saved = position, next = try token()
                    if text(next) == end { return first.lowerBound..<next.upperBound }
                    position = saved
                    _ = try value(depth: depth + 1)
                }
            }
            if Int(kind) != nil {
                let saved = position
                if let second = try? token(), Int(text(second)) != nil,
                   let third = try? token(), text(third) == "R" { return first.lowerBound..<third.upperBound }
                position = saved
            }
            return first
        }
        mutating func dictionary() throws -> Dictionary {
            let start = try token()
            guard text(start) == "<<" else { throw PDFFormCatalog.invalid() }
            var values: [String: Range<Int>] = [:]
            while true {
                let key = try key(token())
                if key == ">>" { return Dictionary(range: start.lowerBound..<position, values: values) }
                guard key.hasPrefix("/"), values[key] == nil else { throw PDFFormCatalog.invalid() }
                values[key] = try value()
            }
        }
    }

    /// 只检查源文件的根字段数组；普通文档无须为这个判断生成整本快照。
    static func containsGeneratedFields(in document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return false }
        return !generatedNames(in: fields).isEmpty
    }

    private static func generatedNames(in fields: CGPDFArrayRef) -> [String] {
        var result: [String] = []
        for index in 0..<CGPDFArrayGetCount(fields) {
            var field: CGPDFDictionaryRef?, parent: CGPDFDictionaryRef?, kids: CGPDFArrayRef?
            var name: CGPDFStringRef?, subtype: UnsafePointer<CChar>?, type: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field,
                  CGPDFDictionaryGetDictionary(field, "Parent", &parent) == false,
                  CGPDFDictionaryGetArray(field, "Kids", &kids) == false,
                  CGPDFDictionaryGetName(field, "Subtype", &subtype), let subtype, String(cString: subtype) == "Widget",
                  CGPDFDictionaryGetName(field, "FT", &type), let type, String(cString: type) == "Tx",
                  CGPDFDictionaryGetString(field, "T", &name), let name,
                  let value = CGPDFStringCopyTextString(name) as String?, value.hasPrefix("SimPleview.Form.") else { continue }
            result.append(value)
        }
        return result
    }

    /// fieldNames 是当前仍在页面上的全部生成字段，空集合也须移除旧的根字段引用。
    static func attachGeneratedFields(in url: URL, fieldNames: Set<String>) throws {
        // 生成器使用 ASCII UUID 名称，限定这一接口，避免猜测 PDFDocEncoding 或层级字段名。
        guard fieldNames.allSatisfy({ $0.hasPrefix("SimPleview.Form.") && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 && ![40, 41, 92].contains($0) } }) else { throw invalid() }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let marker = data.range(of: Data("startxref".utf8), options: .backwards) else { throw invalid() }
        var tail = Reader(data: data, position: marker.upperBound)
        guard let latest = Int(tail.text(try tail.token())), latest >= 0, latest < data.count else { throw invalid() }
        var entries: [Int: Entry] = [:], seen = Set<Int>(), offset: Int? = latest
        var trailer: Dictionary?
        // 允许我们自己追加的传统增量链；新条目（含 free）必须遮住旧版本。
        var mentioned = Set<Int>()
        while let current = offset {
            guard current >= 0, current < data.count, seen.insert(current).inserted, seen.count <= 64 else { throw invalid() }
            var reader = Reader(data: data, position: current)
            guard reader.text(try reader.token()) == "xref" else { throw invalid() }
            while true {
                let first = reader.text(try reader.token())
                if first == "trailer" { break }
                guard let start = Int(first), let count = Int(reader.text(try reader.token())), start >= 0,
                      count >= 0, count <= data.count / 10, start <= Int.max - count else { throw invalid() }
                for number in start..<(start + count) {
                    guard let location = Int(reader.text(try reader.token())), let generation = Int(reader.text(try reader.token())),
                          location >= 0, generation >= 0, generation <= 65535 else { throw invalid() }
                    let state = reader.text(try reader.token())
                    guard state == "n" || state == "f" else { throw invalid() }
                    if mentioned.insert(number).inserted && state == "n" {
                        guard location < data.count else { throw invalid() }
                        entries[number] = Entry(offset: location, generation: generation)
                    }
                }
            }
            let parsed = try reader.dictionary()
            guard parsed.values["/Encrypt"] == nil, parsed.values["/XRefStm"] == nil else { throw invalid() }
            if trailer == nil { trailer = parsed }
            if let previous = parsed.values["/Prev"] {
                guard let value = Int(reader.text(previous)) else { throw invalid() }; offset = value
            } else { offset = nil }
        }
        guard let trailer, let rootValue = trailer.values["/Root"], let root = reference(rootValue, data: data),
              let sizeValue = trailer.values["/Size"], let size = Int(String(decoding: data[sizeValue], as: UTF8.self)),
              size > (entries.keys.max() ?? 0), size < Int.max else { throw invalid() }
        func object(_ ref: Reference) throws -> Reader {
            guard let entry = entries[ref.number], entry.generation == ref.generation else { throw invalid() }
            var reader = Reader(data: data, position: entry.offset)
            guard reader.text(try reader.token()) == String(ref.number), reader.text(try reader.token()) == String(ref.generation),
                  reader.text(try reader.token()) == "obj" else { throw invalid() }
            return reader
        }
        var rootReader = try object(root)
        let catalog = try rootReader.dictionary()
        guard catalog.values["/Type"].map({ rootReader.text($0) }) == "/Catalog" else { throw invalid() }
        var generated: [Reference] = [], parents: [Reference] = [], found = Set<String>()
        for (number, entry) in entries where !fieldNames.isEmpty {
            let ref = Reference(number: number, generation: entry.generation)
            var reader = try object(ref)
            guard let dictionary = try? reader.dictionary(), dictionary.values["/Subtype"].map({ reader.text($0) }) == "/Widget",
                  let nameValue = dictionary.values["/T"] else { continue }
            let raw = reader.text(nameValue)
            guard raw.hasPrefix("("), raw.hasSuffix(")"), fieldNames.contains(String(raw.dropFirst().dropLast())) else { continue }
            found.insert(String(raw.dropFirst().dropLast()))
            // 已有字段子树由 AcroForm 原样拥有，不能把它的 Widget 子节点再挂成根字段。
            if let parent = dictionary.values["/Parent"] {
                guard let ref = reference(parent, data: data) else { throw invalid() }
                parents.append(ref); continue
            }
            guard dictionary.values["/FT"].map({ reader.text($0) }) == "/Tx" else { throw invalid() }
            generated.append(ref)
        }
        guard found == fieldNames else { throw invalid() }
        var updates: [Reference: Data] = [:]
        let formValue = catalog.values["/AcroForm"]
        let formRef = formValue.flatMap { reference($0, data: data) }
        var formReader = try formRef.map(object) ?? Reader(data: data, position: formValue?.lowerBound ?? 0)
        let form = try formValue.map { _ in try formReader.dictionary() }
        let fieldsValue = form?.values["/Fields"]
        let fieldsRef = fieldsValue.flatMap { reference($0, data: data) }
        var fieldsReader = try fieldsRef.map(object) ?? Reader(data: data, position: fieldsValue?.lowerBound ?? 0)
        var registered = Set<Reference>(), roots: [Reference] = []
        if fieldsValue != nil {
            let start = try fieldsReader.token()
            guard fieldsReader.text(start) == "[" else { throw invalid() }
            while true {
                let saved = fieldsReader.position, next = try fieldsReader.token()
                if fieldsReader.text(next) == "]" { break }
                fieldsReader.position = saved
                guard let ref = reference(try fieldsReader.value(), data: data) else { throw invalid() }
                guard registered.insert(ref).inserted else { throw invalid() }
                roots.append(ref)
            }
        }
        for parent in parents {
            var ancestor = parent, visited = Set<Reference>()
            while !registered.contains(ancestor) {
                guard visited.insert(ancestor).inserted, visited.count <= 64 else { throw invalid() }
                var reader = try object(ancestor)
                let dictionary = try reader.dictionary()
                guard let value = dictionary.values["/Parent"], let next = reference(value, data: data) else { throw invalid() }
                ancestor = next
            }
        }
        let retained = try roots.filter { ref in
            var reader = try object(ref)
            let field = try reader.dictionary()
            guard field.values["/Parent"] == nil, field.values["/Kids"] == nil,
                  field.values["/Subtype"].map({ reader.text($0) }) == "/Widget",
                  field.values["/FT"].map({ reader.text($0) }) == "/Tx",
                  let nameRange = field.values["/T"] else { return true }
            let raw = reader.text(nameRange)
            guard raw.hasPrefix("("), raw.hasSuffix(")") else { return true }
            let name = String(raw.dropFirst().dropLast())
            return !name.hasPrefix("SimPleview.Form.") || fieldNames.contains(name)
        }
        let additions = generated.filter { !registered.contains($0) }.sorted { $0.number < $1.number }
        guard !additions.isEmpty || retained.count != roots.count else {
            // 无须追加也要检查编码后的真实字段名，不能把无法处理的旧引用误判为已清理。
            if form != nil { try validate(url, fieldNames: fieldNames, count: roots.count) }
            else if !fieldNames.isEmpty { throw invalid() }
            return
        }
        let newArray = Data(("[ " + (retained + additions).map(\.text).joined(separator: " ") + " ]").utf8)
        var nextSize = size
        if let fieldsRef { updates[fieldsRef] = newArray }
        else {
            let newForm = form.map { replacing($0, key: "/Fields", value: newArray, data: data) }
                ?? Data("<< /Fields ".utf8) + newArray + Data(" >>".utf8)
            if let formRef { updates[formRef] = newForm }
            else {
                let created = Reference(number: size, generation: 0)
                nextSize += 1
                updates[created] = newForm
                updates[root] = replacing(catalog, key: "/AcroForm", value: Data(created.text.utf8), data: data)
            }
        }
        var suffix = Data("\n".utf8), locations: [(Reference, Int)] = []
        for (ref, value) in updates.sorted(by: { $0.key.number < $1.key.number }) {
            locations.append((ref, data.count + suffix.count))
            suffix.append(Data("\(ref.number) \(ref.generation) obj\n".utf8)); suffix.append(value)
            suffix.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count + suffix.count
        suffix.append(Data("xref\n".utf8))
        for (ref, location) in locations {
            guard location < 10_000_000_000 else { throw invalid() }
            suffix.append(Data("\(ref.number) 1\n".utf8))
            suffix.append(Data(String(format: "%010lld %05d n \n", Int64(location), ref.generation).utf8))
        }
        var newTrailer = replacing(trailer, key: "/Size", value: Data(String(nextSize).utf8), data: data)
        var updatedReader = Reader(data: newTrailer, position: 0)
        let updatedDictionary = try updatedReader.dictionary()
        newTrailer = replacing(updatedDictionary, key: "/Prev", value: Data(String(latest).utf8), data: newTrailer)
        suffix.append(Data("trailer\n".utf8)); suffix.append(newTrailer)
        suffix.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: suffix)
        try validate(url, fieldNames: fieldNames, count: retained.count + additions.count)
    }

    private static func validate(_ url: URL, fieldNames: Set<String>, count: Int) throws {
        guard let verification = CGPDFDocument(url as CFURL), let verifiedCatalog = verification.catalog else { throw invalid() }
        var verifiedForm: CGPDFDictionaryRef?, verifiedFields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(verifiedCatalog, "AcroForm", &verifiedForm), let verifiedForm,
              CGPDFDictionaryGetArray(verifiedForm, "Fields", &verifiedFields), let verifiedFields,
              CGPDFArrayGetCount(verifiedFields) == count else { throw invalid() }
        let names = generatedNames(in: verifiedFields)
        guard names.count == fieldNames.count, Set(names) == fieldNames else { throw invalid() }
    }

    private static func reference(_ range: Range<Int>, data: Data) -> Reference? {
        var reader = Reader(data: data, position: range.lowerBound)
        guard let first = try? reader.token(), let number = Int(reader.text(first)), number > 0,
              let second = try? reader.token(), let generation = Int(reader.text(second)), generation >= 0, generation <= 65535,
              let third = try? reader.token(), reader.text(third) == "R", reader.position == range.upperBound else { return nil }
        return Reference(number: number, generation: generation)
    }
    private static func replacing(_ dictionary: Dictionary, key: String, value: Data, data: Data) -> Data {
        let range = dictionary.values[key] ?? (dictionary.range.upperBound - 2)..<(dictionary.range.upperBound - 2)
        var result = Data(data[dictionary.range.lowerBound..<range.lowerBound])
        if dictionary.values[key] == nil { result.append(Data((" " + key + " ").utf8)) }
        result.append(value); result.append(data[range.upperBound..<dictionary.range.upperBound])
        return result
    }
    private static func invalid() -> NSError {
        NSError(domain: "SimPleview.FormCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "无法安全登记 PDF 表单字段；原文件未替换，请保留窗口中的修改。"])
    }
}
