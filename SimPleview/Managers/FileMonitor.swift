import Foundation
import os

/// 监听文件写入与原子替换；防抖、重建监听和关闭均由此实例管理。
class FileMonitor: NSObject {
    let url: URL
    var onDidChange: (() -> Void)?

    private var lastKnownModDate: Date?
    private var acknowledgedModDate: Date?
    private var source: DispatchSourceFileSystemObject?
    /// 实例级防抖任务，替代全局 cancelPreviousPerformRequests，避免多窗口互相干扰
    private var debounceWorkItem: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var isStopped = false

    init(url: URL) {
        self.url = url
        super.init()
        self.lastKnownModDate = getModDate()
        self.acknowledgedModDate = lastKnownModDate
        startMonitoring()
    }

    private func startMonitoring() {
        guard !isStopped, source == nil else { return }
        // [极限性能优化] 使用底层的 kqueue (vnode) 机制监听文件变更
        // 放弃笨重且经常漏报的 NSFilePresenter。DispatchSource 直接监听内核级别的写入事件。
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }

        // 【关键逻辑：支持原子保存】预览 App 等现代软件保存时不是直接覆盖，而是写入临时文件后重命名替换（原子保存）。
        // 这会导致原有的 vnode 被 .delete 或 .rename。我们必须同时监听这些事件来“接力”监控。
        let eventMask: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .revoke]
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: eventMask, queue: .main)

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let data = self.source?.data ?? []

            // 发生了原子覆盖保存，原有物理文件已经被“狸猫换太子”，当前句柄失效
            if data.contains(.delete) || data.contains(.rename) || data.contains(.revoke) {
                // 仅停止旧 vnode，不将整个监视器标记为停止；关闭窗口时的 stop()
                // 会取消下面的重启任务，避免陈旧监听器复活。
                self.source?.cancel()
                self.source = nil
                self.restartWorkItem?.cancel()

                // 给系统 0.5 秒的喘息时间，让新文件彻底在硬盘上落位，然后重新抛出事件并挂载监听
                let restart = DispatchWorkItem { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.lastKnownModDate = self.getModDate()
                    self.triggerChange()
                    self.startMonitoring()
                }
                self.restartWorkItem = restart
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restart)
                return
            }

            // 常规直接写入保存
            if data.contains(.write) {
                guard let newModDate = self.getModDate() else { return }
                if let last = self.lastKnownModDate, newModDate <= last { return }
                self.lastKnownModDate = newModDate
                // 防抖处理：系统保存时可能会瞬间触发多次 write 事件
                // 使用实例级 DispatchWorkItem 替代全局 cancelPreviousPerformRequests，避免多窗口互相干扰
                self.debounceWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.triggerChange()
                }
                self.debounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
            }
        }

        // cancel() 只提交异步取消请求；此时监视器可能已经被窗口释放。
        // 回调只拥有本次打开的 FD，不依赖 self，也不会误关重启后的新 FD。
        // FD 的所有权转交给 source，只有这一处 close，stop/deinit 可重复取消。
        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()
    }

    func stop() {
        isStopped = true
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        source?.cancel()
        source = nil
    }

    private func getModDate() -> Date? {
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func updateLastKnownModDate() {
        lastKnownModDate = getModDate()
        acknowledgedModDate = lastKnownModDate
    }

    var isSelfSaving = false

    private func triggerChange() {
        guard !isStopped else { return }
        if isSelfSaving {
            // 保存抑制窗口期间的外部更新不能直接丢弃，稍后重新比较磁盘版本。
            debounceWorkItem?.cancel()
            let retry = DispatchWorkItem { [weak self] in self?.triggerChange() }
            debounceWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        let date = getModDate()
        guard date != acknowledgedModDate else { return }
        acknowledgedModDate = date
        onDidChange?()
    }
    isolated deinit {
        debounceWorkItem?.cancel()
        restartWorkItem?.cancel()
        source?.cancel()
    }
}
