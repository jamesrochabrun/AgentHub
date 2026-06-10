import CoreVideo
import Foundation
import ImageIO
import SimulatorPreview
import UniformTypeIdentifiers

// Local verification harness — NOT shipped in the app.
//
// Usage: SimulatorPreviewProbe <booted-udid> [outputPNGPath]
// Captures one framebuffer frame, writes it to PNG, then injects a center tap
// to confirm the private CoreSimulator/SimulatorKit path works on this machine.

guard CommandLine.arguments.count >= 2 else {
  FileHandle.standardError.write(Data("usage: SimulatorPreviewProbe <udid> [out.png]\n".utf8))
  exit(2)
}
let udid = CommandLine.arguments[1]
let outPath = CommandLine.arguments.count >= 3
  ? CommandLine.arguments[2]
  : NSTemporaryDirectory() + "simpreview-probe.png"

let availability = SimulatorStreamAvailability.probe(developerDir: XcodeDeveloperDirectoryProbe.path)
print("backend: \(availability.backend.rawValue)")
print("coreSim: \(availability.coreSimulatorFrameworkPath ?? "missing")")
print("simKit:  \(availability.simulatorKitFrameworkPath ?? "missing")")

let service = MainActor.assumeIsolated { SimulatorStreamService(availability: availability) }
let session = MainActor.assumeIsolated { service.session(forDeviceUDID: udid) }

let gotFrame = DispatchSemaphore(value: 0)
var captured = false
session.onStateChange = { state in print("state: \(state)") }
session.onFrame = { frame in
  guard !captured else { return }
  captured = true
  print("frame: \(frame.width)x\(frame.height)")
  if writePNG(frame.pixelBuffer, to: outPath) {
    print("wrote \(outPath)")
  } else {
    print("PNG write failed")
  }
  gotFrame.signal()
}
session.start()

if gotFrame.wait(timeout: .now() + 8) == .timedOut {
  print("TIMEOUT waiting for frame")
  session.stop()
  exit(1)
}

print("interaction supported: \(session.supportsInteraction)")
if session.supportsInteraction {
  print("injecting center tap")
  session.sendTouch(phase: .began, normalizedX: 0.5, normalizedY: 0.5)
  Thread.sleep(forTimeInterval: 0.05)
  session.sendTouch(phase: .ended, normalizedX: 0.5, normalizedY: 0.5)
}

Thread.sleep(forTimeInterval: 0.3)
session.stop()
print("OK")

func writePNG(_ pixelBuffer: CVPixelBuffer, to path: String) -> Bool {
  CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
  let width = CVPixelBufferGetWidth(pixelBuffer)
  let height = CVPixelBufferGetHeight(pixelBuffer)
  guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
  let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
  let cs = CGColorSpaceCreateDeviceRGB()
  guard let ctx = CGContext(
    data: base, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: bytesPerRow, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue),
    let image = ctx.makeImage()
  else { return false }
  let url = URL(fileURLWithPath: path) as CFURL
  guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
  else { return false }
  CGImageDestinationAddImage(dest, image, nil)
  return CGImageDestinationFinalize(dest)
}

enum XcodeDeveloperDirectoryProbe {
  static let path: String = {
    let pipe = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    p.arguments = ["-p"]
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "/Applications/Xcode.app/Contents/Developer"
  }()
}
