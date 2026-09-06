import Foundation
import Combine

nonisolated struct AIModelConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var modelID: String
    var supportsVision = false
    var contextBudget = 32_768
}

nonisolated struct AIEndpointConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var baseURL: String
    var keyAccount = UUID().uuidString
    var models: [AIModelConfiguration]

    static func deepSeek() -> Self {
        .init(name: "DeepSeek", baseURL: "https://api.deepseek.com", models: [
            .init(modelID: "deepseek-v4-flash"),
            .init(modelID: "deepseek-v4-pro"),
            .init(modelID: "deepseek-v4-flash-vision-exp", supportsVision: true)
        ])
    }
}

/// 一个选项就是一个完整路由。模型名不再单独存在另一个偏好设置中，
/// 因而不可能只改 Picker 文案却沿用另一个 API 或另一个请求 model 字段。
nonisolated struct AIRoute: Identifiable, Equatable, Sendable {
    var endpoint: AIEndpointConfiguration
    var model: AIModelConfiguration
    var id: UUID { model.id }
    var label: String { "\(endpoint.name) · \(model.modelID)" }

    func validateReportedModel(_ reported: String?) throws {
        guard let reported, !reported.isEmpty else { return }
        // 同一型号的官方日期快照允许通过；Flash 与 Pro 等不同型号绝不互换。
        let prefix = model.modelID + "-"
        let datedSnapshot = reported.hasPrefix(prefix) && String(reported.dropFirst(prefix.count))
            .range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        guard reported == model.modelID || datedSnapshot else {
            throw AIConfigurationError.message("模型不一致：请求 \(model.modelID)，API 返回 \(reported)。已停止，不会自动替换模型；请检查服务商的模型映射。")
        }
    }
}

nonisolated enum AIConfigurationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class AIConfigurationStore: ObservableObject {
    static let shared = AIConfigurationStore()
    @Published private(set) var endpoints: [AIEndpointConfiguration] = []
    @Published private(set) var selectedModelID: UUID?
    @Published var lastError: String?
    private let defaults: UserDefaults
    private let storageKey = "aiEndpoints_v1"
    private let selectionKey = "aiSelectedRoute_v1"
    var routes: [AIRoute] { endpoints.flatMap { endpoint in endpoint.models.map { AIRoute(endpoint: endpoint, model: $0) } } }
    var selectedRoute: AIRoute? { routes.first { $0.id == selectedModelID } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            do { endpoints = try JSONDecoder().decode([AIEndpointConfiguration].self, from: data) }
            catch { lastError = "无法读取 API 配置：" + error.localizedDescription }
            selectedModelID = defaults.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
        } else {
            // 旧配置整体迁移为一个 API。保留原模型 ID 和原钥匙串 account，
            // 不根据显示名称猜测/替换模型，也不把同一密钥复制到所有新服务商。
            // 旧版本未显式保存的默认配置是 OpenAI；必须保留旧域名，
            // 不能把 default account 中的旧 OpenAI 密钥迁往 DeepSeek。
            let provider = defaults.string(forKey: "aiProvider") ?? "OpenAI"
            let ids = defaults.string(forKey: "aiAvailableModels_v2") ?? (provider == "DeepSeek" ? "deepseek-v4-flash,deepseek-v4-pro,deepseek-v4-flash-vision-exp" : "gpt-5.5,gpt-5.6")
            var names = ids.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let selected = defaults.string(forKey: "aiModel_v2") ?? names.first
            if let selected, !names.contains(selected) { names.append(selected) }
            var seen = Set<String>()
            let models = names.filter { seen.insert($0).inserted }.map {
                AIModelConfiguration(modelID: $0, supportsVision: $0 == "deepseek-v4-flash-vision-exp",
                    contextBudget: max(4096, min(1_000_000, defaults.integer(forKey: "aiContextBudget") == 0 ? 32_768 : defaults.integer(forKey: "aiContextBudget"))))
            }
            let endpoint = AIEndpointConfiguration(name: provider,
                baseURL: defaults.string(forKey: "aiBaseURL") ?? (provider == "DeepSeek" ? "https://api.deepseek.com" : "https://api.openai.com/v1"), keyAccount: "default", models: models)
            endpoints = [endpoint]
            selectedModelID = models.first { $0.modelID == selected }?.id
            persist()
        }
    }

    func select(_ id: UUID?) {
        // 删除/无效选择保留为空并要求用户重选；禁止静默回退至列表首个模型。
        selectedModelID = id.flatMap { wanted in routes.contains { $0.id == wanted } ? wanted : nil }
        defaults.set(selectedModelID?.uuidString, forKey: selectionKey)
    }

    func validated(_ endpoint: AIEndpointConfiguration) throws -> AIEndpointConfiguration {
        var result = endpoint
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !result.name.isEmpty, let url = URL(string: result.baseURL), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.hasSuffix("/chat/completions") else {
            throw AIConfigurationError.message("请输入 API 名称和有效的 HTTPS Base URL（如 https://api.deepseek.com）；不要附加 /chat/completions。")
        }
        guard !endpoints.contains(where: { $0.id != result.id && $0.name.caseInsensitiveCompare(result.name) == .orderedSame }) else {
            throw AIConfigurationError.message("API 名称已存在。请为不同接口/密钥设置可区分的名称，例如 DeepSeek 个人、DeepSeek 工作。")
        }
        var ids = Set<String>()
        for index in result.models.indices {
            result.models[index].modelID = result.models[index].modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = result.models[index]
            guard !model.modelID.isEmpty, !model.modelID.contains(where: { $0.isWhitespace }),
                  ids.insert(model.modelID).inserted, (4096...1_000_000).contains(model.contextBudget) else {
                throw AIConfigurationError.message("模型 ID 不能为空、不能含空白或在同一 API 中重复；上下文预算为 4096–1000000。")
            }
        }
        guard !result.models.isEmpty else { throw AIConfigurationError.message("至少添加一个精确的模型 ID。") }
        return result
    }

    func save(_ endpoint: AIEndpointConfiguration) throws {
        let endpoint = try validated(endpoint)
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = endpoint }
        else { endpoints.append(endpoint) }
        if !routes.contains(where: { $0.id == selectedModelID }) { selectedModelID = nil }
        persist()
    }

    func remove(_ id: UUID) throws {
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { return }
        try APIKeyStore.save("", account: endpoint.keyAccount)
        endpoints.removeAll { $0.id == id }
        if !routes.contains(where: { $0.id == selectedModelID }) { selectedModelID = nil }
        persist()
    }

    func requireRoute(id: UUID? = nil) throws -> AIRoute {
        guard let route = routes.first(where: { $0.id == (id ?? selectedModelID) }) else {
            throw AIConfigurationError.message("请先在 AI 设置中添加 API，并明确选择一个模型。")
        }
        _ = try validated(route.endpoint)
        return route
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(endpoints), forKey: storageKey)
            defaults.set(selectedModelID?.uuidString, forKey: selectionKey)
        } catch { lastError = error.localizedDescription }
    }
}
