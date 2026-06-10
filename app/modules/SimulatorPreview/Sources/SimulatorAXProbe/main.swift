import CoreGraphics
import Foundation
import SimulatorPreview

// Local verification harness — NOT shipped in the app.
//
// Usage: SimulatorAXProbe <booted-udid> [hitX hitY]
// Fetches the frontmost app's accessibility tree via the private
// AccessibilityPlatformTranslation path and prints it; optionally hit-tests a
// point (device points, top-left origin).

guard CommandLine.arguments.count >= 2 else {
  FileHandle.standardError.write(Data("usage: SimulatorAXProbe <udid> [hitX hitY]\n".utf8))
  exit(2)
}
let udid = CommandLine.arguments[1]
let developerDir = XcodeDeveloperDirectory.resolved

let inspector = SimulatorAXInspector.shared
print("available: \(inspector.isAvailable(developerDir: developerDir))")

let semaphore = DispatchSemaphore(value: 0)
var fetched: SimulatorAXElement?
Task {
  do {
    fetched = try await inspector.fetchFrontmostTree(udid: udid, developerDir: developerDir)
  } catch {
    print("ERROR: \(error.localizedDescription)")
  }
  semaphore.signal()
}
if semaphore.wait(timeout: .now() + 30) == .timedOut {
  print("TIMEOUT fetching accessibility tree")
  exit(1)
}
guard let tree = fetched else { exit(1) }

func dump(_ element: SimulatorAXElement, indent: Int) {
  let pad = String(repeating: "  ", count: indent)
  let frame = element.frame
  var line = "\(pad)\(element.summary)  [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]"
  if let value = element.value { line += "  value=\(value.prefix(40))" }
  print(line)
  for child in element.children {
    dump(child, indent: indent + 1)
  }
}

let all = tree.flattened()
print("elements: \(all.count), screen: \(Int(tree.frame.width))x\(Int(tree.frame.height)) pt")
dump(tree, indent: 0)

if CommandLine.arguments.count >= 4,
  let x = Double(CommandLine.arguments[2]),
  let y = Double(CommandLine.arguments[3]) {
  let hit = tree.deepestElement(containing: CGPoint(x: x, y: y))
  print("hit(\(x), \(y)): \(hit?.summary ?? "none")")
}
print("OK")
