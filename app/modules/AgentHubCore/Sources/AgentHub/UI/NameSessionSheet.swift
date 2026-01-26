//
//  NameSessionSheet.swift
//  AgentHub
//
//  Sheet for editing a session's custom name
//

import SwiftUI

/// Sheet for editing a session's custom name
struct NameSessionSheet: View {
  let session: CLISession
  let currentName: String?
  let onSave: (String?) -> Void
  let onDismiss: () -> Void

  @State private var nameText: String = ""
  @FocusState private var isTextFieldFocused: Bool

  var body: some View {
    VStack(spacing: 16) {
      Text("Name Session")
        .font(.headline)

      TextField("Enter a name...", text: $nameText)
        .textFieldStyle(.roundedBorder)
        .focused($isTextFieldFocused)
        .onSubmit { save() }

      Text("Session ID: \(session.shortId)")
        .font(.caption)
        .foregroundColor(.secondary)

      HStack(spacing: 12) {
        Button("Cancel") {
          onDismiss()
        }
        .keyboardShortcut(.escape)

        if currentName != nil {
          Button("Clear") {
            onSave(nil)
            onDismiss()
          }
          .foregroundColor(.red)
        }

        Button("Save") {
          save()
        }
        .keyboardShortcut(.return)
        .buttonStyle(.borderedProminent)
        .disabled(nameText.isEmpty && currentName == nil)
      }
    }
    .padding(20)
    .frame(width: 300)
    .onAppear {
      nameText = currentName ?? ""
      isTextFieldFocused = true
    }
  }

  private func save() {
    let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
    onSave(trimmed.isEmpty ? nil : trimmed)
    onDismiss()
  }
}
