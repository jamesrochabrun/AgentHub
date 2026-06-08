//
//  AgentHubMCPUIResourceView.swift
//  AgentHubMCPUI
//

import SwiftUI
import WebKit

public struct AgentHubMCPUIResourceView: View {
  private let resource: AgentHubMCPUIResource

  public init(resource: AgentHubMCPUIResource) {
    self.resource = resource
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(resource.uri)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer()

        Text(resource.mimeType)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(Color.secondary.opacity(0.12))
          )
      }

      AgentHubMCPUIWebView(html: resource.text)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
  }
}

public struct AgentHubMCPUIWebView: NSViewRepresentable {
  private let html: String

  public init(html: String) {
    self.html = html
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  public func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    webView.loadHTMLString(html, baseURL: nil)
    context.coordinator.loadedHTML = html
    return webView
  }

  public func updateNSView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.loadedHTML != html else { return }
    webView.loadHTMLString(html, baseURL: nil)
    context.coordinator.loadedHTML = html
  }

  public final class Coordinator {
    var loadedHTML: String?
  }
}
