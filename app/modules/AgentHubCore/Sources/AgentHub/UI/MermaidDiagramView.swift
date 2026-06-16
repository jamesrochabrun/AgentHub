//
//  MermaidDiagramView.swift
//  AgentHub
//
//  Renders Mermaid diagrams extracted from a Claude Code session's JSONL file.
//

import AppKit
import SwiftUI

// MARK: - MermaidDiagramView

/// Side panel / sheet view that extracts and renders all Mermaid diagrams
/// from a session's JSONL file using native rendering (no WebView/JS).
public struct MermaidDiagramView: View {
  let session: CLISession
  let onDismiss: () -> Void
  var isEmbedded: Bool = false

  @State private var diagrams: [String] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  public init(
    session: CLISession,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false
  ) {
    self.session = session
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
  }

  public var body: some View {
    VStack(spacing: 0) {
      header

      if isLoading {
        loadingState
      } else if let error = errorMessage {
        errorState(error)
      } else if diagrams.isEmpty {
        emptyState
      } else {
        diagramList
      }
    }
    .frame(
      minWidth: isEmbedded ? 300 : 700, idealWidth: isEmbedded ? .infinity : 900, maxWidth: .infinity,
      minHeight: isEmbedded ? 300 : 550, idealHeight: isEmbedded ? .infinity : 750, maxHeight: .infinity
    )
    .onKeyPress(.escape) {
      guard !isEmbedded else { return .handled }
      onDismiss()
      return .handled
    }
    .task {
      await loadDiagrams()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Spacer()
      Button("Close") {
        onDismiss()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  // MARK: - Content

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Extracting diagrams...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorState(_ message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundColor(.secondary)
      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "chart.xyaxis.line")
        .font(.title2)
        .foregroundColor(.secondary)
      Text("No Mermaid diagrams found")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var diagramList: some View {
    ScrollView {
      LazyVStack(spacing: 24) {
        ForEach(Array(diagrams.enumerated()), id: \.offset) { index, source in
          DiagramCard(index: index + 1, source: source)
        }
      }
      .padding(16)
    }
  }

  // MARK: - Loading

  private func loadDiagrams() async {
    let filePath = session.sessionFilePath ?? Self.resolveFilePath(for: session)
    do {
      diagrams = try await Self.extractMermaidBlocks(from: filePath)
    } catch {
      errorMessage = "Failed to read session: \(error.localizedDescription)"
    }
    isLoading = false
  }

  /// Constructs the session JSONL path using the same encoding as CLISessionMonitorService.
  private static func resolveFilePath(for session: CLISession) -> String {
    let claudeDataPath = NSHomeDirectory() + "/.claude"
    let encodedPath = session.projectPath.claudeProjectPathEncoded
    return "\(claudeDataPath)/projects/\(encodedPath)/\(session.id).jsonl"
  }

  // MARK: - JSONL Extraction

  /// Reads a session JSONL file and returns all Mermaid source blocks found in assistant text content.
  /// Handles both Claude (assistant/text blocks) and Codex (event_msg/agent_message) formats.
  public static func extractMermaidBlocks(from filePath: String) async throws -> [String] {
    return try await Task.detached(priority: .userInitiated) {
      guard let data = FileManager.default.contents(atPath: filePath),
            let content = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadNoSuchFile)
      }

      var blocks: [String] = []
      let lines = content.components(separatedBy: .newlines)
      let decoder = JSONDecoder()

      for line in lines where !line.isEmpty {
        guard let lineData = line.data(using: .utf8) else { continue }

        // Try Claude format first
        if let entry = try? decoder.decode(SessionJSONLParser.SessionEntry.self, from: lineData),
           entry.type == "assistant",
           let contentBlocks = entry.message?.content {
          for block in contentBlocks where block.type == "text" {
            guard let text = block.text else { continue }
            blocks.append(contentsOf: extractMermaidSections(from: text))
          }
          continue
        }

        // Try Codex format: {"type":"event_msg","payload":{"type":"agent_message","message":"..."}}
        if let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
           let type = json["type"] as? String, type == "event_msg",
           let payload = json["payload"] as? [String: Any],
           let eventType = payload["type"] as? String, eventType == "agent_message",
           let message = payload["message"] as? String {
          blocks.append(contentsOf: extractMermaidSections(from: message))
        }
      }
      return blocks
    }.value
  }

  /// Extracts all ```mermaid ... ``` sections from a text string.
  private static func extractMermaidSections(from text: String) -> [String] {
    var results: [String] = []
    var searchRange = text.startIndex..<text.endIndex

    let openTag = "```mermaid"
    let closeTag = "```"

    while let openRange = text.range(of: openTag, range: searchRange) {
      let afterOpen = openRange.upperBound
      // Skip the newline right after the opening tag
      let contentStart = text[afterOpen...].first == "\n"
        ? text.index(after: afterOpen)
        : afterOpen

      guard contentStart < text.endIndex,
            let closeRange = text.range(of: closeTag, range: contentStart..<text.endIndex) else {
        break
      }

      let source = String(text[contentStart..<closeRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !source.isEmpty {
        results.append(source)
      }
      searchRange = closeRange.upperBound..<text.endIndex
    }
    return results
  }
}

// MARK: - DiagramCard

/// Renders a single Mermaid diagram asynchronously with zoom and download support.
private struct DiagramCard: View {
  let index: Int
  let source: String

  @State private var renderedImage: NSImage?
  @State private var isRendering = true
  @State private var renderError: String?
  @State private var scale: CGFloat = 1.0
  @State private var baseScale: CGFloat = 1.0

  private let scaleStep: CGFloat = 0.25
  private let minScale: CGFloat = 0.25
  private let maxScale: CGFloat = 4.0

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Label row + controls
      HStack {
        Text("Diagram \(index)")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.secondary)

        Spacer()

        if renderedImage != nil {
          // Zoom controls
          HStack(spacing: 2) {
            Button(action: { scale = max(minScale, scale - scaleStep) }) {
              Image(systemName: "minus")
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Zoom out")

            Text("\(Int(scale * 100))%")
              .font(.caption2)
              .foregroundColor(.secondary)
              .frame(minWidth: 36)

            Button(action: { scale = min(maxScale, scale + scaleStep) }) {
              Image(systemName: "plus")
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Zoom in")

            Button(action: { scale = 1.0; baseScale = 1.0 }) {
              Image(systemName: "arrow.uturn.backward")
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Reset zoom")
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 4))

          // Download button
          Button(action: saveImage) {
            Image(systemName: "arrow.down.circle")
              .font(.caption2)
          }
          .buttonStyle(.plain)
          .help("Save as PNG")
        }
      }

      // Diagram canvas
      ZStack {
        if isRendering {
          HStack(spacing: 8) {
            ProgressView()
              .scaleEffect(0.7)
            Text("Rendering...")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .frame(height: 120)
          .frame(maxWidth: .infinity)
        } else if let error = renderError {
          VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundColor(.secondary)
            Text(error)
              .font(.caption)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
          }
          .frame(height: 80)
          .frame(maxWidth: .infinity)
        } else if let image = renderedImage {
          let aspect = image.size.height / max(image.size.width, 1)
          let baseWidth: CGFloat = 560
          ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
              .resizable()
              .frame(
                width: baseWidth * scale,
                height: baseWidth * aspect * scale
              )
          }
        }
      }
      .padding(12)
      .background(Color(NSColor.textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
      .gesture(
        MagnifyGesture()
          .onChanged { value in
            scale = min(maxScale, max(minScale, baseScale * value.magnification))
          }
          .onEnded { value in
            baseScale = scale
          }
      )
    }
    .task {
      await render()
    }
  }

  private func render() async {
    do {
      let image = try await Task.detached(priority: .userInitiated) {
        try MermaidRenderHelper.renderImage(source: source)
      }.value
      renderedImage = image
    } catch {
      renderError = "Render failed: \(error.localizedDescription)"
    }
    isRendering = false
  }

  private func saveImage() {
    guard let image = renderedImage else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "diagram-\(index).png"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      guard let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let png = bitmap.representation(using: .png, properties: [:]) else { return }
      try? png.write(to: url)
    }
  }
}
