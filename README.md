# SimPleview

**[English]**  
SimPleview is a minimalist macOS PDF reader built using AI-assisted programming. While macOS comes with a built-in Preview app, SimPleview focuses on specific workflows to provide a cleaner and more efficient reading and annotating experience. 

**[中文]**  
SimPleview 是一款通过 AI 辅助编程构建的极简 macOS PDF 阅读器。虽然 macOS 自带了“预览(Preview)”应用，但 SimPleview 专注于特定工作流，旨在提供更干净、更高效的阅读与批注体验。

---

## Features vs. Apple Preview / 相比自带“预览”的优势功能

**[English]**
- **Memory Hibernation (智能休眠)**: Unlike Preview which keeps all open PDFs actively loaded in memory, SimPleview automatically hibernates background windows after a period of inactivity, replacing them with a low-memory frosted glass state to save RAM.
- **Create Blank Documents (新建空白文档)**: Preview requires complicated workarounds to create a blank PDF from scratch. SimPleview provides a direct menu option (Cmd+Shift+N) to instantly create blank PDFs or images in standard paper sizes (A4, A3, etc.) for quick sketching or note-taking.
- **Distraction-Free UI (极简阅读界面)**: Built natively with SwiftUI's `NavigationSplitView`, it offers a cleaner sidebar and toolbar layout than Preview, focusing purely on the reading and annotating content without visual clutter.
- **Optimized Thumbnail Generation (优化的缩略图加载)**: Uses asynchronous background threads to render PDF thumbnails, avoiding the UI stutter that occasionally happens in Preview with large documents.
- **Streamlined Annotations (更直接的批注工具)**: Provides immediate access to highlight, underline, strikeout, and ink tools without needing to toggle an edit mode.

**[中文]**
- **后台内存休眠**：自带的“预览”会将所有打开的 PDF 完整驻留在内存中。而 SimPleview 会自动侦测长期在后台静置的窗口，将其进入省电休眠状态（显示毛玻璃蒙版），大幅节省系统内存。
- **一键新建空白文档**：在自带的“预览”中想要凭空新建一个空白 PDF 步骤非常繁琐。SimPleview 提供了直观的快捷键 (Cmd+Shift+N) 和菜单，可以直接生成 A4、A3 等标准纸张尺寸的空白 PDF 或图片，方便随时做草稿和笔记。
- **纯净的沉浸式 UI**：使用 SwiftUI 原生的分栏架构，去除了自带“预览”繁杂的顶部状态栏视觉干扰，提供了更现代、更专注内容的侧边栏和阅读主界面。
- **无感缩略图加载**：采用完全异步的后台多线程生成 PDF 侧边栏缩略图，解决了在打开超大文档时可能出现的卡顿掉帧问题。
- **更快捷的批注流**：将高亮、下划线、删除线和画笔等常用工具直接提取，无需像自带“预览”那样反复点击切换进入“编辑模式”。

---

## Tech Stack / 技术细节

**[English]**
- Language: Swift 6
- Frameworks: SwiftUI, AppKit (NSApplicationDelegate, NSWindowController), PDFKit
- Development: Entirely built and optimized through AI Pair Programming.

**[中文]**
- 语言：Swift 6
- 框架：SwiftUI，AppKit (底层窗口与生命周期控制)，PDFKit
- 开发方式：全程通过 AI 结对编程完成代码构建与深度优化。
