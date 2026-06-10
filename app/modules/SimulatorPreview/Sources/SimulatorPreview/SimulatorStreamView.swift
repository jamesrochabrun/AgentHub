import AVFoundation
import AppKit
import CoreVideo
import SwiftUI

/// SwiftUI host for a live simulator stream. Renders captured frames into an
/// `AVSampleBufferDisplayLayer` and forwards mouse/keyboard input to the
/// session when interaction is supported.
public struct SimulatorStreamView: NSViewRepresentable {
  private let session: any SimulatorStreamSessionProtocol
  private let isInteractive: Bool

  public init(session: any SimulatorStreamSessionProtocol, isInteractive: Bool) {
    self.session = session
    self.isInteractive = isInteractive
  }

  public func makeNSView(context: Context) -> SimulatorStreamNSView {
    let view = SimulatorStreamNSView()
    view.configure(session: session, isInteractive: isInteractive)
    return view
  }

  public func updateNSView(_ nsView: SimulatorStreamNSView, context: Context) {
    nsView.setInteractive(isInteractive)
  }

  public static func dismantleNSView(_ nsView: SimulatorStreamNSView, coordinator: ()) {
    nsView.detach()
  }
}

/// AppKit backing view that owns the display layer and input handling.
public final class SimulatorStreamNSView: NSView {
  private let displayLayer = AVSampleBufferDisplayLayer()
  private weak var session: (any SimulatorStreamSessionProtocol)?
  private var isInteractive = false
  private var contentSize: CGSize = .zero
  private var formatDescription: CMVideoFormatDescription?
  private var formatDimensions: CGSize = .zero

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.black.cgColor
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor.black.cgColor
    layer?.addSublayer(displayLayer)
  }

  public override var isFlipped: Bool { true }  // top-left origin, matches device coords

  public override func layout() {
    super.layout()
    displayLayer.frame = bounds
  }

  func configure(session: any SimulatorStreamSessionProtocol, isInteractive: Bool) {
    self.session = session
    self.isInteractive = isInteractive

    session.onFrame = { [weak self] frame in
      self?.enqueue(frame)
    }
    session.start()
  }

  func setInteractive(_ value: Bool) {
    isInteractive = value
  }

  func detach() {
    session?.onFrame = nil
    displayLayer.flushAndRemoveImage()
  }

  // MARK: - Rendering

  private func enqueue(_ frame: SimulatorStreamFrame) {
    contentSize = CGSize(width: frame.width, height: frame.height)
    guard let sampleBuffer = Self.makeSampleBuffer(
      pixelBuffer: frame.pixelBuffer,
      cachedFormat: &formatDescription,
      cachedDimensions: &formatDimensions)
    else { return }

    if displayLayer.status == .failed {
      displayLayer.flush()
    }
    displayLayer.enqueue(sampleBuffer)
  }

  private static func makeSampleBuffer(
    pixelBuffer: CVPixelBuffer,
    cachedFormat: inout CMVideoFormatDescription?,
    cachedDimensions: inout CGSize
  ) -> CMSampleBuffer? {
    let dims = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                      height: CVPixelBufferGetHeight(pixelBuffer))
    if cachedFormat == nil || cachedDimensions != dims {
      var format: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
      guard status == noErr else { return nil }
      cachedFormat = format
      cachedDimensions = dims
    }
    guard let format = cachedFormat else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sb = sampleBuffer else { return nil }

    // Display immediately rather than waiting on a timeline.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0 {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sb
  }

  // MARK: - Input

  public override var acceptsFirstResponder: Bool { isInteractive }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInteractive }

  private func normalized(for event: NSEvent) -> CGPoint? {
    let point = convert(event.locationInWindow, from: nil)
    return SimulatorPointMapper.normalizedPoint(
      viewPoint: point, contentSize: contentSize, viewSize: bounds.size)
  }

  public override func mouseDown(with event: NSEvent) {
    guard isInteractive, let p = normalized(for: event) else { return }
    window?.makeFirstResponder(self)
    session?.sendTouch(phase: .began, normalizedX: p.x, normalizedY: p.y)
  }

  public override func mouseDragged(with event: NSEvent) {
    guard isInteractive, let p = normalized(for: event) else { return }
    session?.sendTouch(phase: .moved, normalizedX: p.x, normalizedY: p.y)
  }

  public override func mouseUp(with event: NSEvent) {
    guard isInteractive else { return }
    // Clamp the up-point even if it ended in the letterbox bars.
    let point = convert(event.locationInWindow, from: nil)
    let rect = SimulatorPointMapper.aspectFitRect(contentSize: contentSize, in: bounds.size)
    guard rect.width > 0 else { return }
    let nx = min(max((point.x - rect.minX) / rect.width, 0), 1)
    let ny = min(max((point.y - rect.minY) / rect.height, 0), 1)
    session?.sendTouch(phase: .ended, normalizedX: nx, normalizedY: ny)
  }

  public override func keyDown(with event: NSEvent) {
    guard isInteractive, let usage = KeyCodeMapping.hidUsage(forVirtualKeyCode: event.keyCode) else {
      super.keyDown(with: event)
      return
    }
    session?.sendKey(direction: .down, hidUsage: usage)
  }

  public override func keyUp(with event: NSEvent) {
    guard isInteractive, let usage = KeyCodeMapping.hidUsage(forVirtualKeyCode: event.keyCode) else {
      super.keyUp(with: event)
      return
    }
    session?.sendKey(direction: .up, hidUsage: usage)
  }
}
