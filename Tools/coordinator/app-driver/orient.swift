import ImageIO; import Foundation
for p in CommandLine.arguments.dropFirst() {
  guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
        let pr = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { continue }
  let o = (pr[kCGImagePropertyOrientation] as? Int) ?? 1
  if o != 1 { print("\(o) \(p)") }
}
