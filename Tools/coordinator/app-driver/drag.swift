import CoreGraphics; import Foundation
// drag x1 y1 x2 y2 [steps]   |   scroll x y lines(neg = down) [count]
let a = CommandLine.arguments
let src = CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
if a[1] == "drag" {
  let p1 = CGPoint(x: Double(a[2])!, y: Double(a[3])!), p2 = CGPoint(x: Double(a[4])!, y: Double(a[5])!)
  let steps = a.count > 6 ? Int(a[6])! : 20
  post(.mouseMoved, p1); usleep(80_000); post(.leftMouseDown, p1); usleep(60_000)
  for i in 1...steps { let f = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * f, y: p1.y + (p2.y - p1.y) * f)); usleep(16_000) }
  usleep(60_000); post(.leftMouseUp, p2)
} else {
  let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!); let lines = Int32(a[4])!; let n = a.count > 5 ? Int(a[5])! : 10
  post(.mouseMoved, p); usleep(80_000)
  for _ in 0..<n { CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap); usleep(20_000) }
}
