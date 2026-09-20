# 代码结构与维护入口

macOS 使用根目录的 `SimPleview.xcodeproj`，源码在 `SimPleview/`。iPadOS 使用 `iPad/SimPleviewPad.xcodeproj`，源码在 `iPad/SimPleviewPad/`。两个工程独立编译；修改一端时，不应直接把另一端的视图或状态类加入工程。

当前采用按职责分文件的结构，没有额外拆成动态框架或 Swift Package。相关状态继续由原来的窗口或会话持有，避免拆文件时引入第二份状态。

## macOS

| 职责 | 主要入口 | 边界 |
| --- | --- | --- |
| 窗口与文档协调 | `AppCore/AppState.swift`、`AppState+*.swift` | 每个窗口持有自己的管理器，扩展按文件、导航、标注、页面等操作分组 |
| 文件读写与外部更新 | `Managers/DocumentManager.swift`、`FileMonitor.swift`、`Utilities/AtomicPDFWriter.swift` | 文件监听只报告变化；打开、重载和保存由文档层协调 |
| PDF 交互与绘图 | `Views/PDFKitView.swift`、`CustomPDFView+*.swift`、`PDFRenderSnapshot.swift` | UI 在主执行器准备快照，后台瓦片读取不可变绘图值 |
| 缩略图 | `Managers/ThumbnailManager.swift`、`ThumbnailStore.swift` | 前者管理单窗口请求与失效，后者管理共享图像缓存及预算 |
| 标注编辑与历史 | `Managers/AnnotationManager.swift`、`AnnotationManager+History.swift`、`Models/UndoAction.swift` | 编辑和侧栏索引同步更新；撤销、重做共用动作执行逻辑 |
| 笔迹保存与烧录 | `Utilities/StandardInk.swift`、`AppCore/DocumentManager+BurnIn.swift` | 屏幕绘制与 PDF 持久化分别处理，避免把屏幕外观缓存当作保存数据 |
| AI 对话 | `AppCore/AIChatViewModel*.swift`、`AIChatService.swift`、`Utilities/AIRequestGate.swift` | 会话状态、网络传输和请求名额分别管理；模型路由随请求保存 |
| 待办与日程 | `Views/TodoSidebarView.swift`、`Views/Todo/`、`Managers/EventManager.swift` | 面板持有一个 EventManager；子视图接收数据与回调，不另建 EventKit 存储 |
| 日程选项与翻译 | `Models/EventOptions.swift`、`Localization.swift` | 选项与翻译字典不混入网络、文件或视图布局代码 |
| 阅读记录与番茄钟 | `Managers/ReadingTracker.swift`、`FocusSessionManager.swift`、`FocusCalendarRecorder.swift` | 阅读统计、倒计时和日历写入各自负责自己的状态 |

## iPadOS

| 职责 | 主要入口 |
| --- | --- |
| 文件库与笔记本管理 | `Library/NotebookLibrary.swift`、`LibraryView.swift` |
| 文档会话、权限和保存调度 | `Reader/NotebookSession.swift` |
| PDF 与 PencilKit 交互 | `Reader/PadPDFView.swift`、`NotebookReaderView.swift` |
| 文件协调与冲突检查 | `Core/NotebookStorage.swift` |
| 矢量笔迹、可编辑数据和纸张 | `Core/VectorInk.swift`、`NotebookPaper.swift` |
| AI 配置、会话与传输 | `AI/` |

## 修改时需要保留的约束

- 正在显示的 PDFKit 文档留在其所属执行器。后台任务使用独立文档副本或不可变数据，不能用 `nonisolated(unsafe)` 绕过隔离检查。
- 关闭或更换文档时，清理任务、观察者、访问权限和历史栈。异步结果发布前检查它是否仍属于当前文档或请求。
- 标注编辑同步更新文档和侧栏。局部修改只使相关页面失效；旧缩略图可以作过渡，但不能被当作新文档的有效缓存。
- 撤销和重做先验证再修改；逆操作必须记录真实页码。现有页面重排仍只支持撤销，撤销重排后清空重做栈。
- 拆分视图时保留原来的状态持有者和视图层次，避免重建 PDFView、画布或事件存储。

验证使用 Xcode 工程，以 Swift 6 完整并发检查并将编译警告视为错误。渲染或历史逻辑变动还需使用合成 PDF 检查具体行为；编译通过不能替代运行验证。临时测试、日志及构建产物放在仓库之外。
