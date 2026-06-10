import CoreGraphics

/// Maps a click location in an aspect-fit display view to normalized simulator
/// framebuffer coordinates (0...1, top-left origin), which the Indigo HID touch
/// path expects.
///
/// The view letterboxes the framebuffer (`contentsGravity = resizeAspect`), so
/// clicks in the letterbox bars map to nil — they shouldn't tap the device.
public enum SimulatorPointMapper {
  public struct Layout: Equatable {
    public let contentRect: CGRect
    public init(contentRect: CGRect) { self.contentRect = contentRect }
  }

  /// Compute the letterboxed content rectangle for `contentSize` fit inside
  /// `viewSize` preserving aspect ratio.
  public static func aspectFitRect(contentSize: CGSize, in viewSize: CGSize) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0,
      viewSize.width > 0, viewSize.height > 0
    else { return .zero }

    let scale = min(viewSize.width / contentSize.width, viewSize.height / contentSize.height)
    let w = contentSize.width * scale
    let h = contentSize.height * scale
    let x = (viewSize.width - w) / 2
    let y = (viewSize.height - h) / 2
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// Convert a point in view space (top-left origin) to normalized device
  /// coordinates. Returns nil if the point is outside the content rect.
  public static func normalizedPoint(
    viewPoint: CGPoint,
    contentSize: CGSize,
    viewSize: CGSize
  ) -> CGPoint? {
    let rect = aspectFitRect(contentSize: contentSize, in: viewSize)
    guard rect.width > 0, rect.height > 0 else { return nil }
    guard rect.contains(viewPoint) else { return nil }
    let nx = (viewPoint.x - rect.minX) / rect.width
    let ny = (viewPoint.y - rect.minY) / rect.height
    return CGPoint(x: nx, y: ny)
  }

  /// Inverse of `normalizedPoint`: where a normalized device coordinate lands
  /// in view space (top-left origin). Used to position annotation pins over
  /// the letterboxed stream. Returns nil when either size is degenerate.
  public static func viewPoint(
    normalizedX: Double,
    normalizedY: Double,
    contentSize: CGSize,
    viewSize: CGSize
  ) -> CGPoint? {
    let rect = aspectFitRect(contentSize: contentSize, in: viewSize)
    guard rect.width > 0, rect.height > 0 else { return nil }
    return CGPoint(
      x: rect.minX + rect.width * min(max(normalizedX, 0), 1),
      y: rect.minY + rect.height * min(max(normalizedY, 0), 1)
    )
  }
}
