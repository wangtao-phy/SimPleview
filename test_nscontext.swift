import AppKit
let ctx = NSGraphicsContext(cgContext: CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!, flipped: false)
print(type(of: ctx))
