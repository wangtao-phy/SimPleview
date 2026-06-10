import Foundation

/// [教程注释：全局目录管理器]
/// 集中管理 App 所有需要存储到本地硬盘的文件夹。
/// 确保所有 App 数据都整齐地存放在 `~/Documents/SimPleview` 目录下，而不是在用户的文稿文件夹里到处乱拉屎。
class DirectoryManager {
    static let shared = DirectoryManager()
    
    private init() {}
    
    /// 获取应用的主根目录：`~/Documents/SimPleview`
    var appRootDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootDir = docs.appendingPathComponent("SimPleview")
        
        // 自动确保根目录存在
        if !FileManager.default.fileExists(atPath: rootDir.path) {
            try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        }
        
        return rootDir
    }
    
    /// 获取/创建指定的子目录（如 "signature", "Reading Record"）
    /// - Parameter folderName: 子文件夹的名称
    /// - Returns: 子目录的安全 URL
    func getDirectory(for folderName: String) -> URL {
        let dir = appRootDirectory.appendingPathComponent(folderName)
        
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        
        return dir
    }
}
