import Cocoa
import Quartz

let url = URL(fileURLWithPath: "test.pdf")
guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { exit(1) }
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
context.beginPage(mediaBox: &box)
context.endPage()
context.closePDF()
