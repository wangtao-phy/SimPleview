import Foundation
import CryptoKit

/// 规范化完整路径的摘要作为持久化身份：同名文件互不覆盖，原子保存更换 inode
/// 不会换身份。显示标题独立保存；外部移动/重命名文件会形成新的路径身份。
nonisolated enum DocumentIdentity {
    static func id(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
