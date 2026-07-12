# SimPleview

SimPleview is a macOS PDF reader built entirely through AI-assisted programming. While macOS comes with a built-in "Preview" app, some of its features can be rigid or underutilized. This application extends and optimizes the specific functionalities most commonly used by its author.

SimPleview 是一款完全通过 AI 辅助编程构建的 macOS PDF 阅读器。虽然 macOS 自带了“预览”应用，但部分功能非常死板，部分功能没能发挥应有的长处。这个 app 对其中部分作者常用的功能进行了拓展与优化。

---

##  Features vs. Apple Preview / 相比自带“预览”的优势功能

- **Background Memory Hibernation**: Apple's Preview keeps all open PDFs fully loaded in memory. SimPleview automatically detects background windows that have been inactive for a long time and puts them into a hibernation state to save RAM.
- **Customizable Annotation Colors**: The original motivation for this app was to break free from the rigid, fixed underline colors in Preview, allowing complete freedom in choosing annotation colors.
- **Signature Management**: Signatures are now stored and managed in a dedicated, fixed folder for quick and convenient access.
- **Reading History & Tracking**: It tracks the time spent reading each PDF and allows for manual management of an author library.
- **One-Click Blank Document Creation**: Creating a blank PDF from scratch in Preview is incredibly tedious. SimPleview provides intuitive shortcuts (Cmd+Shift+N) and menus to instantly generate blank PDFs or images in standard sizes (A4, A3, etc.) for quick sketches and notes.
- **Page Insertion & Deletion**: Preview's native page management is excellent; this app retains that functionality while providing even more options via right-clicking the thumbnail.
- **Side-by-Side Comparison**: You can easily pop out individual pages of the current PDF into a separate window to conveniently compare different sections of the same document.
- **Open in Browser**: Instead of building heavy AI features into the reader itself, it provides a one-click "Open in Browser" button. Since most modern browsers now feature built-in AI reading assistants, you can directly leverage them for AI-assisted reading.
- **Reveal in Finder**: A small but highly convenient feature to instantly locate your file.


- **后台内存休眠**：自带的“预览”会将所有打开的 PDF 完整驻留在内存中。而 SimPleview 会自动侦测长期在后台静置的窗口，将其进入休眠状态以节省资源。
- **标注自由切换颜色**：这个 app 的初衷便是解放自带“预览”中定死的下划线颜色，实现真正的自由标色。
- **签名管理**：现在所有的签名统一存放在一个固定的文件夹下，方便随时调用与管理。
- **阅读记录**：可以记录 PDF 的阅读时长，也可以手动管理属于您自己的作者库。
- **一键新建空白文档**：在自带的“预览”中想要凭空新建一个空白 PDF 步骤非常繁琐。SimPleview 提供了直观的快捷键 (Cmd+Shift+N) 和菜单，可以直接生成 A4、A3 等标准纸张尺寸的空白 PDF 或图片，方便随时做草稿和笔记。
- **插入与删除 PDF 页面**：自带“预览”的原生页面管理功能非常好用，当前 app 做了完整保留，并在缩略图的右键菜单中提供了更多实用的拓展选项。
- **对比查看**：可以单独弹出当前 PDF 的特定页面，方便在同一个 PDF 文件内进行跨页对比查看。
- **浏览器打开**：阅读器本身不提供臃肿的 AI 功能，而是提供“一键在浏览器打开”。如今各大主流浏览器都已经内置了强大的 AI 阅读助手，您可以直接借用浏览器来辅助阅读。
- **当前文件所在文件夹**：一个极为方便的小功能，一键直达文件所在目录。

---

## 📥 Installation & Usage / 安装与使用指南


If you download the pre-compiled `.dmg` file from the Releases page, you may encounter a macOS Gatekeeper warning ("App is damaged and can't be opened" or "Unidentified developer") because this is an independently published, unsigned open-source application.
To open it:
1. Drag the `SimPleview.app` from the DMG to your `Applications` folder.
2. Go to **System Settings > Privacy & Security**, scroll down, and click **"Open Anyway"** for SimPleview.
3. Alternatively, right-click the App and select **"Open"**.
4. If macOS claims the app is "damaged", run this command in Terminal to clear the quarantine attributes: `xattr -cr /Applications/SimPleview.app`


如果您直接从 Releases 页面下载了打包好的 `.dmg` 安装包，在打开时可能会遇到 macOS 的安全拦截（提示“应用已损坏，打不开”或“来自未知开发者”）。这是因为本应用为个人发布的开源软件，未向苹果官方签发开发者证书。
解决方法：
1. 请务必先将 DMG 里面的 `SimPleview.app` 拖入到您的「应用程序」文件夹中。
2. 打开 Mac 的**系统设置 > 隐私与安全性**，向下滑动，找到拦截提示并点击**仍要打开**。
3. 或者，在访达中右键（或按住 Control 键点击）该 App，然后在弹出的菜单中选择**打开**。
4. 如果 macOS 仍然无理取闹地提示“应用已损坏”，请打开“终端 (Terminal)”，输入以下命令彻底清除苹果的隔离属性，然后即可完美运行：
   `xattr -cr /Applications/SimPleview.app`

---

##  Tech Stack / 技术细节


- **Language**: Swift 6
- **Frameworks**: SwiftUI, AppKit, PDFKit
- **Development Method**: The entire code construction and deep optimization were accomplished through AI programming. The human author solely played the role of a Product Manager.


- **语言**：Swift 6
- **框架**：SwiftUI，AppKit，PDFKit
- **开发方式**：全程通过 AI 编程完成代码构建与深度优化，本人在此过程中仅扮演项目经理的角色。

---

## 📄 License & Notes / 说明


The source code of this application is open to everyone for learning and personal use, but commercial use is strictly prohibited. Users are encouraged to build upon this framework and leverage AI to add customized features that suit their own preferences. If you use code from this project, please provide proper attribution by citing the source.


本项目代码开源供所有人学习与使用，但严禁用于任何商业用途。开发者可以基于此现有框架，利用 AI 助手为其增加符合自身需求的个性化功能。若您在项目中使用了本仓库的代码，请务必注明来源与出处。
