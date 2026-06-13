import SwiftUI
import UniformTypeIdentifiers
import os

#if os(macOS)
import AppKit

/// [教程注释：签名管理悬浮窗]
/// 点击工具栏的签名图标后，弹出的管理面板。
/// 动态扫描并展示专属文件夹下所有的历史签名，并提供导入新签名的入口。
struct SignaturePopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    @State private var signatureURLs: [URL] = []
    @AppStorage("insertAsVector") var insertAsVector = true
    
    // 两列网格布局，展示得紧凑美观
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 10)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // [顶部标题栏]
            HStack {
                Text(state.L("Signatures"))
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                
                // 矢量/位图切换按钮
                Button(action: { insertAsVector.toggle() }) {
                    Image(systemName: insertAsVector ? "waveform.path" : "photo")
                        .font(.body.weight(.bold))
                        .foregroundColor(insertAsVector ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(state.L(insertAsVector ? "Vector Mode" : "Image Mode"))
                
                // 导入按钮
                Button(action: importNewSignature) {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                }
                .buttonStyle(.plain)
                .help(state.L("Import new signature"))
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            
            Divider()
            
            // [中央内容区：签名网格展示]
            if signatureURLs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "signature")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(state.L("No signatures found"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(state.L("Click + to import"))
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(signatureURLs, id: \.self) { url in
                            Button(action: {
                                // 点击立刻插入到当前 PDF 中，并关闭面板
                                state.processAndInsertSignature(imageURL: url)
                                uiState.isShowingSignaturePopover = false
                            }) {
                                SignatureThumbnail(url: url)
                            }
                            .buttonStyle(.plain)
                            // 提供原生右键菜单用于删除
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteSignature(at: url)
                                } label: {
                                    Label(state.L("Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 300) // 限制最大高度
            }
        }
        .frame(width: 260)
        .onAppear {
            loadSignatures()
        }
    }
    
    // [逻辑：从磁盘读取现存所有签名]
    private func loadSignatures() {
        let dir = state.getSignatureDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            // 过滤出图片，并按创建时间倒序排列（最新的在前面）
            self.signatureURLs = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "png" || ext == "jpg" || ext == "jpeg"
            }.sorted { u1, u2 in
                let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return d1 > d2
            }
        } catch {
            print("\(error.localizedDescription)")
        }
    }
    
    // [逻辑：触发原生文件选择器，并将文件拷贝进沙盒]
    private func importNewSignature() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        // [修复] Popover 本身层级较高，NSOpenPanel 默认层级较低容易被遮挡。
        // 强制将文件选择器的窗口层级拉高到 popUpMenu 级别，并激活 App。
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let _ = try state.importSignature(from: url)
                    // 导入成功，刷新列表
                    loadSignatures()
                } catch {
                    print("\(error.localizedDescription)")
                }
            }
        }
    }
    
    // [逻辑：从磁盘彻底删除某个签名]
    private func deleteSignature(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            // 简单粗暴的动画过滤更新
            withAnimation {
                signatureURLs.removeAll { $0 == url }
            }
        } catch {
            print("\(error.localizedDescription)")
        }
    }
}

/// 辅助视图：渲染单个签名图片的缩略图，保证视觉统一
struct SignatureThumbnail: View {
    let url: URL
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 60)
        .contentShape(Rectangle()) // 扩大点击热区
    }
}
#endif
