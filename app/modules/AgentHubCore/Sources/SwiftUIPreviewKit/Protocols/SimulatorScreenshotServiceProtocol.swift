//
//  SimulatorScreenshotServiceProtocol.swift
//  SwiftUIPreviewKit
//
//  Protocol for capturing screenshots from the iOS Simulator.
//

import Foundation

public protocol SimulatorScreenshotServiceProtocol: Sendable {
  /// Captures a single screenshot from the simulator with the given UDID.
  func captureScreenshot(udid: String, outputPath: String) async throws

  /// Starts polling the simulator for screenshots at the given interval.
  /// Calls `onChange` only when the captured image differs from the previous one.
  /// Returns an ID that can be used to stop polling.
  func startPolling(
    udid: String,
    interval: TimeInterval,
    onChange: @escaping @Sendable (String) -> Void
  ) async -> UUID

  /// Stops a previously started polling session.
  func stopPolling(id: UUID) async
}
