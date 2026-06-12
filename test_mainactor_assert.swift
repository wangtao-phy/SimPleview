import Foundation
import AppKit

@MainActor
class MyTestClass: NSObject {
    @objc dynamic func doDraw() {
        print("doDraw")
    }
}

extension MyTestClass {
    @objc dynamic nonisolated func hd_doDraw() {
        print("hd_doDraw nonisolated")
    }
}

DispatchQueue.main.async {
    let obj = MyTestClass()
    DispatchQueue.global().async {
        obj.hd_doDraw()
        print("Done")
        exit(0)
    }
}
RunLoop.main.run()
