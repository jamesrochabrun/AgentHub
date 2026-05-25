//
//  InlineEditStyleReconciler.swift
//  AgentHub
//
//  Reformats an inline Canvas toolbar edit so the persisted file matches
//  the project's existing code style. Runs through `ClaudeProgrammaticService`
//  on the Haiku fallback chain and silently falls back to the direct write
//  if the model fails or returns malformed output.
//

import Foundation

public protocol InlineEditStyleReconcilerProtocol: Sendable {
  func reconcile(
    originalContent: String,
    editedContent: String,
    filePath: String,
    changeSummary: String,
    projectPath: String
  ) async throws -> String
}

public enum InlineEditStyleReconcilerError: Error, LocalizedError {
  case emptyOutput
  case suspiciouslyTruncated(outputLength: Int, expectedAtLeast: Int)
  case modelRefusal(String)

  public var errorDescription: String? {
    switch self {
    case .emptyOutput:
      return "Reconciler returned empty output"
    case .suspiciouslyTruncated(let outputLength, let expectedAtLeast):
      return "Reconciler output suspiciously short (\(outputLength) chars, expected at least \(expectedAtLeast))"
    case .modelRefusal(let snippet):
      return "Reconciler appears to have refused the request: \(snippet)"
    }
  }
}

public actor ClaudeInlineEditStyleReconciler: InlineEditStyleReconcilerProtocol {
  private static let logPrefix = "[CANVASEDIT]"
  private static let reconcileTimeout: Duration = .seconds(8)
  private static let refusalPrefixes: [String] = [
    "i cannot",
    "i can't",
    "i'm sorry",
    "i am sorry",
    "i'm unable",
    "i am unable",
    "sorry,",
    "as an ai"
  ]

  private let programmaticService: any ClaudeProgrammaticServiceProtocol
  private let timeout: Duration

  public init(
    programmaticService: any ClaudeProgrammaticServiceProtocol,
    timeout: Duration? = nil
  ) {
    self.programmaticService = programmaticService
    self.timeout = timeout ?? Self.reconcileTimeout
  }

  public func reconcile(
    originalContent: String,
    editedContent: String,
    filePath: String,
    changeSummary: String,
    projectPath: String
  ) async throws -> String {
    let userPrompt = Self.makeUserPrompt(
      originalContent: originalContent,
      editedContent: editedContent,
      filePath: filePath,
      changeSummary: changeSummary
    )
    let request = ClaudeProgrammaticRequest(
      systemPrompt: Self.systemPrompt,
      userPrompt: userPrompt,
      workingDirectory: projectPath,
      models: ClaudeProgrammaticService.haikuFallbackModels,
      timeout: timeout,
      permissionMode: nil,
      disallowedTools: nil,
      logPrefix: Self.logPrefix
    )

    print(
      """
      \(Self.logPrefix)[REQUEST] file=\(filePath) project=\(projectPath) change=\(changeSummary)
      \(Self.logPrefix)[REQUEST][SYSTEM]
      \(Self.prefixedRequestBody(Self.systemPrompt))
      \(Self.logPrefix)[REQUEST][USER]
      \(Self.prefixedRequestBody(userPrompt))
      \(Self.logPrefix)[REQUEST][END]
      """
    )

    let raw = try await programmaticService.run(request)
    return try Self.sanitizeOutput(raw, editedContentLength: editedContent.count)
  }

  static let systemPrompt: String = """
  You are a code style reformatter. Your job is to rewrite an edited file so it matches the style of the ORIGINAL file, while preserving the exact semantic change that was made.

  You will receive:
  - ORIGINAL: the file before the edit, written in the project's authentic style
  - EDITED: the file after the edit, with the semantic change applied but possibly drift in formatting (indentation, quotes, spacing, ordering, etc.)
  - CHANGE: a one-line description of the semantic change

  Output rules (follow strictly):
  - Return ONLY the full reformatted file contents
  - Do NOT wrap the output in markdown code fences
  - Do NOT include any commentary, explanation, preamble, or trailing notes
  - Preserve the semantic change exactly — do NOT introduce additional semantic changes
  - Match ORIGINAL's style: indentation (tabs vs spaces, width), quote style, declaration order within rules, line breaks, blank lines, trailing-semicolon convention, naming conventions
  - If ORIGINAL uses Tailwind / utility classes, prefer that over raw CSS
  - If ORIGINAL uses CSS-in-JS or styled-components, follow that pattern
  - The output's line count and overall shape should closely match ORIGINAL, differing only by the edited declaration(s)
  """

  static func makeUserPrompt(
    originalContent: String,
    editedContent: String,
    filePath: String,
    changeSummary: String
  ) -> String {
    """
    CHANGE: \(changeSummary)

    ORIGINAL (\(filePath)):
    \(originalContent)

    EDITED (\(filePath)):
    \(editedContent)

    Return the reformatted file contents only.
    """
  }

  static func prefixedRequestBody(_ text: String) -> String {
    text
      .components(separatedBy: .newlines)
      .map { line in
        line.isEmpty ? "\(logPrefix)[REQUEST]" : "\(logPrefix)[REQUEST] \(line)"
      }
      .joined(separator: "\n")
  }

  static func sanitizeOutput(_ raw: String, editedContentLength: Int) throws -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw InlineEditStyleReconcilerError.emptyOutput
    }

    if text.hasPrefix("```") {
      if let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
      } else {
        text = String(text.dropFirst(3))
      }
      if text.hasSuffix("```") {
        text = String(text.dropLast(3))
      }
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard !text.isEmpty else {
      throw InlineEditStyleReconcilerError.emptyOutput
    }

    let lowerHead = text.prefix(60).lowercased()
    for prefix in refusalPrefixes where lowerHead.hasPrefix(prefix) {
      throw InlineEditStyleReconcilerError.modelRefusal(String(text.prefix(120)))
    }

    let minimumAcceptableLength = max(8, Int(Double(editedContentLength) * 0.25))
    if text.count < minimumAcceptableLength {
      throw InlineEditStyleReconcilerError.suspiciouslyTruncated(
        outputLength: text.count,
        expectedAtLeast: minimumAcceptableLength
      )
    }

    return text
  }
}
