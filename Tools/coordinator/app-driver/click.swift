import CoreGraphics; import Foundation
// usage: click x y [clicks]   (screen points, top-left origin)
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let n = a.count > 3 ? Int(a[3])! : 1
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
for i in 1...n {
  for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
    e.post(tap: .cghidEventTap); usleep(40_000)
  }
  usleep(90_000)
}
