# SimPleview

SimPleview 是通过 AI 辅助编程开发的 PDF 阅读与标注应用，现有 macOS 和 iPadOS 两个版本。iPadOS 版还支持创建和整理 PDF 笔记本。两个版本使用独立的 Xcode 工程。

SimPleview is a PDF reader and annotation app developed with AI-assisted programming. It has macOS and iPadOS versions. The iPadOS version also supports creating and organizing PDF notebooks. Each version has a separate Xcode project.

## 运行要求 / Requirements

| 版本 / Platform | 系统与设备 / System and device | 工程 / Project |
| --- | --- | --- |
| macOS | macOS 26.6+，Apple Silicon（M 系列）；不支持 Intel Mac / Apple Silicon only | `SimPleview.xcodeproj` |
| iPadOS | iPadOS 18+，iPad | `iPad/SimPleviewPad.xcodeproj` |

## 功能 / Features

- **PDF 阅读与标注**：页面缩略图、搜索、页面管理、高亮、下划线、删除线、文字笔记和手绘。
- **标注保存**：普通标注写入 PDF，可在其他设备读取；可切换全部标注的显示与隐藏。
- **AI 对话**：支持多个兼容 Chat Completions 的 API，分别配置密钥和模型 ID。回答按句显示，可暂停；使用视觉模型时可主动读取当前页或整份 PDF。详见 [AI 功能说明（macOS）](AI_FEATURES.md) 和 [iPad 版说明](iPad/README.md)。
- **macOS**：另有签名管理、阅读记录、内部链接悬停预览、独立对比窗口、标签分组和在 Finder 中显示文件。闲置后台窗口会清理缓存，但不卸载整份 PDF。
- **iPadOS**：使用 PencilKit 手写，可创建空白、横线、方格、点阵笔记本，用文件夹整理。支持 Apple Pencil，也可启用手指书写。未移植 Mac 的签名库和 Finder 操作。

- **PDF reading and annotation**: Thumbnails, search, page management, highlights, underlines, strikeouts, text notes, and handwriting.
- **Annotation storage**: Standard annotations are saved in the PDF for use on other devices. Annotations can be shown or hidden together.
- **AI chat**: Multiple Chat Completions-compatible APIs with separate keys and model IDs, sentence-by-sentence display, and pause. Page images are sent to a vision model when the user requests current-page or whole-document reading.
- **macOS**: Signature management, reading records, internal-link previews, comparison windows, tab groups, and Reveal in Finder. Idle background windows clear caches while keeping the PDF loaded.
- **iPadOS**: PencilKit handwriting, blank/lined/grid/dotted notebooks, and folder organization. Supports Apple Pencil and optional finger drawing. The Mac signature library and Finder actions are not included.

## 安装 / Installation

### macOS

1. 从 [Releases](https://github.com/wangtao-phy/SimPleview/releases) 下载 macOS 安装包，打开 DMG，将 `SimPleview.app` 拖入“应用程序”。
2. 启动应用。如果系统提示开发者无法验证，确认下载来源后，在“系统设置 → 隐私与安全性”中按系统提示选择“仍要打开”。
3. 从源码运行：下载完整仓库，用 Xcode 打开根目录的 `SimPleview.xcodeproj`，选择 `SimPleview` scheme 和 `My Mac`，按 `⌘R`。归档使用 `Product → Archive`。

Download the macOS DMG from [Releases](https://github.com/wangtao-phy/SimPleview/releases) and drag `SimPleview.app` into Applications. If macOS cannot verify the developer, check the download source and follow the prompt in System Settings → Privacy & Security. To build from source, open the root `SimPleview.xcodeproj`, select the `SimPleview` scheme and `My Mac`, then press `⌘R`. Use Product → Archive for an archive build.

### iPadOS

以下是通过 Xcode 从源码安装到自己 iPad 的方法。需要一台能运行 Xcode 的 Mac、iPad 和 Apple 账户；macOS 的 DMG 不能安装到 iPad。工程已用 Xcode 27 Beta 编译验证，所用 Xcode 还需支持 iPad 上的系统版本。

1. 下载完整仓库（GitHub 页面选择 `Code → Download ZIP` 后解压，或使用 `git clone`）。
2. 用 Xcode 打开 `iPad/SimPleviewPad.xcodeproj`，不要打开根目录的 Mac 工程。
3. 在 `Xcode → Settings → Accounts` 中登录自己的 Apple 账户。
4. 选择工程中的 `SimPleviewPad` target，进入 `Signing & Capabilities`，勾选 `Automatically manage signing`，将 `Team` 改为自己的团队或 `Personal Team`。若提示 Bundle Identifier 已被占用，将其改为自己的唯一标识，例如 `com.yourname.simpleviewpad`。
5. 用数据线连接 iPad，解锁并确认“信任此电脑”。在 iPad 的“设置 → 隐私与安全性 → 开发者模式”中启用开发者模式，按提示重启并确认。如果没有该选项，先在 Xcode 中完成设备连接。参见 [Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
6. 在 Xcode 顶部选择 `SimPleviewPad` scheme 和已连接的 iPad，按 `⌘R`。首次运行时等待 Xcode 完成设备准备、签名和安装；设备应保持解锁。如果 iPad 提示需要信任开发者，在“设置 → 通用 → VPN 与设备管理”中按提示操作。
7. 安装完成后，iPad 上的应用名称为“SimPleview 笔记”。以后可直接从主屏幕打开。只想在 Mac 上试用界面时，可把运行目标改为 iPad 模拟器。

免费 `Personal Team` 可用于个人设备测试，但描述文件会在签发 7 天后到期，需要重新连接 Xcode 编译安装。更新时使用原来的团队和 Bundle Identifier，不要先删除应用；应用内的笔记应另有备份。参见 [Apple 账户与签名限制](https://developer.apple.com/help/account/basics/about-your-developer-account)。

To install the iPadOS version from source, you need a Mac with Xcode, an iPad, and an Apple Account. The macOS DMG cannot be installed on an iPad. The project has been built with Xcode 27 Beta; Xcode must also support the OS version on your device.

1. Download and extract the whole repository, or clone it with Git.
2. Open `iPad/SimPleviewPad.xcodeproj` in Xcode.
3. Sign in under Xcode → Settings → Accounts. Select the `SimPleviewPad` target → Signing & Capabilities, enable automatic signing, and select your own Team or Personal Team. If the bundle ID is unavailable, replace it with a unique ID such as `com.yourname.simpleviewpad`.
4. Connect and unlock your iPad, trust the Mac, and enable Developer Mode under Settings → Privacy & Security. Follow the restart and confirmation prompts.
5. Select the `SimPleviewPad` scheme and your iPad, then press `⌘R`. Complete any device preparation or developer-trust prompts. The installed app is named “SimPleview 笔记”. An iPad simulator can also be selected for local testing.

Personal Team provisioning expires after 7 days and requires rebuilding and reinstalling through Xcode. Keep the same team and bundle ID for updates, avoid deleting the app first, and keep a separate copy of your notebooks. See the Apple links above for Developer Mode and provisioning details.

## 文件、标注与同步 / Files, annotations, and sync

- **macOS**：普通标注在停止编辑两秒后自动保存到原 PDF，也可手动保存；检测到外部修改时暂停自动保存。签名保留原有的本地管理和烧录流程。
- **iPadOS**：“打开文件”直接打开并修改系统“文件”中的原 PDF；“导入 PDF 副本”另存一份到笔记目录。新笔记本默认保存在应用文档目录，也可通过“选择笔记目录”选择文件提供商允许访问的文件夹。
- **跨设备**：两端打开同一份 iCloud Drive PDF，并等待同步完成后再切换设备。保存成功仅表示本地写入完成，应用不自动合并两台设备同时编辑产生的冲突。
- **手绘**：使用标准 PDF 矢量笔迹。iPad 另存原生编辑数据用于继续编辑；也可导出笔迹写入页面的通用矢量 PDF。通用导出不保留逐笔编辑及原文件的交互结构，详见 [iPad 文件与笔迹说明](iPad/README.md#文件与笔迹)。扫描页面本身仍是图片。

On macOS, standard annotations are saved to the original PDF after two seconds without editing, or manually. On iPadOS, “打开文件” opens the original file in place; “导入 PDF 副本” creates a separate copy. To work across devices, open the same iCloud Drive PDF and wait for sync before switching devices. A successful save confirms a local write, not completed cloud sync; simultaneous edits are not merged automatically. Handwriting uses standard PDF vector ink. The iPad version also keeps native editing data and offers a separate vector export; see the iPad documentation for its limits.

## 技术与仓库内容 / Technical details

使用 Swift 6、SwiftUI 和 PDFKit；macOS 使用 AppKit，iPadOS 使用 UIKit 和 PencilKit。两个工程的源码和资源分别管理。仓库保留编译需要的资源及第三方许可证；本地测试、调试文件、用户配置和构建产物不随源码提交。

Built with Swift 6, SwiftUI, and PDFKit, using AppKit on macOS and UIKit/PencilKit on iPadOS. The projects keep separate source and resource directories. Required runtime resources and third-party licenses are included; local tests, debug files, user settings, and build products are excluded.

## License & Notes / 说明

The source code of this application is open to everyone for learning and personal use, but commercial use is strictly prohibited. Users are encouraged to build upon this framework and leverage AI to add customized features that suit their own preferences. If you use code from this project, please provide proper attribution by citing the source.


本项目代码开源供所有人学习与使用，但严禁用于任何商业用途。开发者可以基于此现有框架，利用 AI 助手为其增加符合自身需求的个性化功能。若您在项目中使用了本仓库的代码，请务必注明来源与出处。
