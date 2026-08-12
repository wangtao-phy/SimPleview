import Foundation
import Combine

struct HistoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    let url: URL
    var lastOpenedDate: Date
}

@MainActor
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    
    @Published var history: [HistoryItem] = []
    
    private let maxDays: Int = 90
    private let defaultsKey = "SimPleview.PDFHistory"
    
    private init() {
        loadHistory()
        cleanOldHistory()
    }
    
    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            return
        }
        self.history = items
    }
    
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
    
    func recordOpen(url: URL) {
        // 如果文件已经存在，将其移动到最前面并更新时间
        if let index = history.firstIndex(where: { $0.url.path == url.path }) {
            var item = history[index]
            item.lastOpenedDate = Date()
            history.remove(at: index)
            history.insert(item, at: 0)
        } else {
            // 新文件
            let newItem = HistoryItem(url: url, lastOpenedDate: Date())
            history.insert(newItem, at: 0)
        }
        
        cleanOldHistory()
        saveHistory()
    }
    
    func deleteItem(id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }
    
    func clearHistory(olderThanDays days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        history.removeAll { $0.lastOpenedDate < cutoffDate }
        saveHistory()
    }
    
    private func cleanOldHistory() {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxDays, to: Date()) ?? Date()
        let originalCount = history.count
        history.removeAll { $0.lastOpenedDate < cutoffDate }
        if history.count != originalCount {
            saveHistory()
        }
    }
}
