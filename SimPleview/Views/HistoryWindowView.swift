import SwiftUI

struct HistoryWindowView: View {
    @StateObject private var historyManager = HistoryManager.shared
    @State private var showingDeletedAlert = false
    @State private var deletedAlertFileName = ""
    @State private var selectedItemID: UUID?
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.en
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack {
                Text(LS("History"))
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Menu {
                    Button(LS("Clear Older Than 7 Days")) {
                        historyManager.clearHistory(olderThanDays: 7)
                    }
                    Button(LS("Clear Older Than 30 Days")) {
                        historyManager.clearHistory(olderThanDays: 30)
                    }
                    Button(LS("Clear All (90 Days)")) {
                        historyManager.clearHistory(olderThanDays: 0) // 0 means clear everything
                    }
                } label: {
                    Image(systemName: "trash")
                    Text(LS("Clear"))
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .frame(width: 80)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            List(selection: $selectedItemID) {
                let grouped = groupHistory(historyManager.history)
                
                if let last7 = grouped["last7"], !last7.isEmpty {
                    Section(header: Text(LS("Last 7 Days")).font(.headline).padding(.top, 5)) {
                        ForEach(last7) { item in
                            HistoryRow(item: item) {
                                historyManager.deleteItem(id: item.id)
                            }
                            .tag(item.id)
                            .onTapGesture(count: 2) {
                                openFileLocation(item: item)
                            }
                        }
                    }
                }
                
                if let last30 = grouped["last30"], !last30.isEmpty {
                    Section(header: Text(LS("Last 30 Days")).font(.headline).padding(.top, 5)) {
                        ForEach(last30) { item in
                            HistoryRow(item: item) {
                                historyManager.deleteItem(id: item.id)
                            }
                            .tag(item.id)
                            .onTapGesture(count: 2) {
                                openFileLocation(item: item)
                            }
                        }
                    }
                }
                
                if let last90 = grouped["last90"], !last90.isEmpty {
                    Section(header: Text(LS("Last 90 Days")).font(.headline).padding(.top, 5)) {
                        ForEach(last90) { item in
                            HistoryRow(item: item) {
                                historyManager.deleteItem(id: item.id)
                            }
                            .tag(item.id)
                            .onTapGesture(count: 2) {
                                openFileLocation(item: item)
                            }
                        }
                    }
                }
                
                if historyManager.history.isEmpty {
                    HStack {
                        Spacer()
                        Text(LS("No history available."))
                            .foregroundColor(.secondary)
                            .padding(.top, 50)
                        Spacer()
                    }
                }
            }
            .listStyle(SidebarListStyle())
        }
        .frame(minWidth: 400, minHeight: 500)
        .alert(isPresented: $showingDeletedAlert) {
            Alert(
                title: Text(LS("File Deleted")),
                message: Text(String(format: LS("The file '%@' no longer exists or has been deleted."), deletedAlertFileName)),
                dismissButton: .default(Text(LS("OK")))
            )
        }
    }
    
    private func groupHistory(_ items: [HistoryItem]) -> [String: [HistoryItem]] {
        var grouped: [String: [HistoryItem]] = ["last7": [], "last30": [], "last90": []]
        
        let now = Date()
        let calendar = Calendar.current
        
        for item in items {
            let days = calendar.dateComponents([.day], from: item.lastOpenedDate, to: now).day ?? 0
            if days <= 7 {
                grouped["last7"]?.append(item)
            } else if days <= 30 {
                grouped["last30"]?.append(item)
            } else {
                grouped["last90"]?.append(item)
            }
        }
        
        return grouped
    }
    
    private func openFileLocation(item: HistoryItem) {
        let path = item.url.path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            deletedAlertFileName = item.url.lastPathComponent
            showingDeletedAlert = true
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let onDelete: () -> Void
    
    @State private var isHovering = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.en
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    var body: some View {
        let path = item.url.path
        let fileExists = FileManager.default.fileExists(atPath: path)
        
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .foregroundColor(fileExists ? .primary : .gray)
                    .strikethrough(!fileExists)
                
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            Text(item.lastOpenedDate, style: .date)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
