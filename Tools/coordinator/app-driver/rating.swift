import ImageIO; import Foundation
for p in CommandLine.arguments.dropFirst() {
  guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil), let m = CGImageSourceCopyMetadataAtIndex(s, 0, nil) else { print("\(p): no metadata"); continue }
  let r = CGImageMetadataCopyStringValueWithPath(m, nil, "xmp:Rating" as CFString) as String? ?? "none"
  print("\((p as NSString).lastPathComponent): xmp:Rating=\(r)")
}
