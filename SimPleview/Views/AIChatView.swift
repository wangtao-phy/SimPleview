import SwiftUI

struct AIChatView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
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
            
            // Chat Messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
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
            
            // Input Area
            HStack {
                TextField("输入你的问题，选中的内容将作为上下文...", text: $viewModel.inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.sendMessage(appState: state)
                    }
                
                Button(action: {
                    viewModel.sendMessage(appState: state)
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(viewModel.inputText.isEmpty ? .gray : .blue)
                }
                .disabled(viewModel.inputText.isEmpty || viewModel.isGenerating)
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(height: max(150, uiState.chatBoxHeight - dragOffset))
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: -5)
        .onAppear {
            viewModel.configure(with: state.fileName)
        }
        .onChange(of: state.fileName) { _, newFileName in
            viewModel.configure(with: newFileName)
        }
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage
    @State private var webViewHeight: CGFloat = 50
    @State private var isThinkingExpanded: Bool = false
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
                Text(message.content)
                    .padding(10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 8) {
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
                    
                    if !message.content.isEmpty {
                        KaTeXWebView(markdown: message.content, dynamicHeight: $webViewHeight)
                            .frame(height: webViewHeight)
                    } else if message.thinking != nil {
                        // Still thinking...
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // add border
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                Spacer()
            }
        }
    }
}
