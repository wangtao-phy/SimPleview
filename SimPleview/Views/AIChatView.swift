import SwiftUI
import PDFKit

struct AIChatView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @ObservedObject private var conversations = ConversationManager.shared
    @ObservedObject private var gate = AIRequestGate.shared
    @ObservedObject private var configuration = AIConfigurationStore.shared
    @StateObject private var viewModel = AIChatViewModel()
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Handle for resizing
            ZStack {
                Color.gray.opacity(0.1)
                Capsule()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 40, height: 4)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        let newHeight = uiState.chatBoxHeight - value.translation.height
                        if newHeight < 150 {
                            uiState.isAIChatPresented = false
                            uiState.chatBoxHeight = 300 // reset for next time
                        } else {
                            uiState.chatBoxHeight = newHeight
                        }
                        dragOffset = 0
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            
            // Conversation Toolbar
            HStack {
                Menu {
                    ForEach(viewModel.availableSessions) { session in
                        Button(action: {
                            viewModel.switchSession(to: session.id)
                        }) {
                            Text(session.title)
                            if session.id == viewModel.currentSessionID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    Text(viewModel.availableSessions.first(where: { $0.id == viewModel.currentSessionID })?.title ?? "选择对话")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                
                Spacer()
                
                Button(action: {
                    viewModel.createNewSession()
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("新建对话")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            
            Divider()
            
            // 只显示本对话实际收到的用量。多页读取时这是最近一批请求，而非整轮总计。
            if let usage = viewModel.lastUsage {
                Text("最近请求：输入 \(usage.promptTokens) Token（缓存 \(usage.cachedTokens)）· 输出 \(usage.completionTokens) Token")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .help("由 API 返回。缓存是输入 Token 中复用的部分；多页读取时仅表示最近一次请求。")
            } else if viewModel.estimatedContextTokens > 0 {
                Text("上下文估算：\(viewModel.estimatedContextTokens) Token")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("本地估算的对话长度，不代表已经发送请求或产生用量。")
            }

            // Chat Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty {
                            Text("有什么可以帮你的？")
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                        } else {
                            ForEach(viewModel.messages) { message in
                                ChatBubbleView(message: message).padding(.horizontal, 40)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            
            Divider()
            
            HStack {
                Button { viewModel.readCurrentPDFPage(appState: state) } label: {
                    Label("读取当前页", systemImage: "doc.text.viewfinder")
                }
                .disabled(gate.isBusy || configuration.selectedRoute?.model.supportsVision != true || state.pdfView.document == nil)
                .help("只把点击时的当前页面作为图片发送给所选视觉模型；可先输入问题，也可暂停。")
                Button { viewModel.readEntirePDF(appState: state) } label: {
                    Label("视觉读取整份 PDF", systemImage: "doc.viewfinder")
                }
                .disabled(gate.isBusy || configuration.selectedRoute?.model.supportsVision != true || state.pdfView.document == nil)
                .help("把全部页面按两页一批转成图片，顺序发送给当前所选 API。包含扫描页和图表；可随时暂停。")
                Text(viewModel.isCompressing ? "正在整理上下文…" : (gate.isBusy && !viewModel.isGenerating ? "另一窗口正在回答，请稍候…" : viewModel.status))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if viewModel.canResume {
                    Button("继续回答") { viewModel.resumeAnswer() }.disabled(gate.isBusy)
                        .help("以原 API 和模型发起续答请求，保留已有回答。")
                }
            }.padding(.horizontal).padding(.top, 6)
            // Input Area
            HStack {
                TextField("输入你的问题，选中的内容将作为上下文...", text: $viewModel.inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.sendMessage(appState: state)
                    }
                
                if viewModel.isGenerating {
                    Button(viewModel.isStopping ? "正在暂停…" : "暂停") { viewModel.pauseGeneration() }
                        .disabled(viewModel.isStopping)
                } else {
                Button(action: {
                    viewModel.sendMessage(appState: state)
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(viewModel.inputText.isEmpty ? .gray : .blue)
                }
                .disabled(viewModel.inputText.isEmpty || gate.isBusy || configuration.selectedRoute == nil)
                .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(height: max(150, uiState.chatBoxHeight - dragOffset))
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: -5)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FlushAIConversations"))) { notification in
            if notification.object == nil || (notification.object as? AppState) === state {
                viewModel.cancelPendingWork()
            }
        }
        .alert("对话存储", isPresented: Binding(get: { conversations.lastError != nil || viewModel.errorMessage != nil }, set: { if !$0 { conversations.lastError = nil; viewModel.errorMessage = nil } })) {
            Button("确定") { conversations.lastError = nil; viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? conversations.lastError ?? "") }
        .onDisappear { viewModel.cancelPendingWork() }
        .onAppear {
            if let id = state.documentID { viewModel.configure(with: id, legacyName: state.fileName) }
        }
        .onChange(of: state.fileURL) { _, _ in
            if let id = state.documentID { viewModel.configure(with: id, legacyName: state.fileName) }
        }
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage
    @State private var webViewHeight: CGFloat = 50
    @State private var isThinkingExpanded: Bool = false
    @State private var notesHeight: CGFloat = 50
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer(minLength: 200)
                Text(message.content)
                    .padding(10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let model = message.requestedModel {
                        Text("\(message.apiName ?? "API") · \(model)").font(.caption2).foregroundStyle(.secondary)
                        if let actual = message.responseModel {
                            Text("API 返回：\(actual)").font(.caption2).foregroundStyle(.secondary)
                        } else if message.generationState == "completed" {
                            Text("服务未返回模型 ID，无法核验服务端型号").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let progress = message.pdfProgress {
                        Text(progress.pageNumber.map { "\(progress.fileName) · 第 \($0) 页 · \(progress.completedPages == 1 ? "已读取" : "读取中")" }
                            ?? "\(progress.fileName) · 已读取 \(progress.completedPages)/\(progress.totalPages) 页")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let thinking = message.thinking, !thinking.isEmpty {
                        DisclosureGroup(isExpanded: $isThinkingExpanded) {
                            Text(thinking)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.leading, 12)
                                .padding(.vertical, 4)
                        } label: {
                            Text("思考过程")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if message.pdfProgress != nil {
                        // 长书的逐页笔记单独折叠；最新阅读内容/全文总结始终可见，
                        // 不能因整个长消息的显示上限而把最后的总结截掉。
                        let text = message.pdfSummary ?? message.pdfLatestText ?? ""
                        if !text.isEmpty {
                            KaTeXWebView(markdown: text, dynamicHeight: $webViewHeight).frame(height: webViewHeight)
                        } else if message.generationState == "running" { ProgressView().controlSize(.small) }
                        DisclosureGroup("逐页阅读笔记") {
                            KaTeXWebView(markdown: message.content, dynamicHeight: $notesHeight).frame(height: notesHeight)
                        }
                    } else if !message.content.isEmpty {
                        KaTeXWebView(markdown: message.content, dynamicHeight: $webViewHeight)
                            .frame(height: webViewHeight)
                    } else if message.generationState == "running" {
                        ProgressView().controlSize(.small)
                    }
                    if message.generationState == "paused" { Text("已暂停").font(.caption).foregroundStyle(.secondary) }
                    if let error = message.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // add border
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                Spacer(minLength: 200)
            }
        }
    }
}
