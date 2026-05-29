//
//  CLIEnvironmentVariablesEditor.swift
//  AgentHub
//

import Foundation
import SwiftUI

struct CLIEnvironmentVariablesEditor: View {
  @Binding var variables: [CLIEnvironmentVariable]

  private let rowAnimation = Animation.easeInOut(duration: 0.18)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if variables.isEmpty {
        Text("No environment variables configured.")
          .foregroundColor(.secondary)
          .transition(.opacity.combined(with: .move(edge: .top)))
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach($variables) { $variable in
            HStack(spacing: 8) {
              TextField(
                text: $variable.name,
                prompt: Text("VARIABLE_NAME")
              ) {
                EmptyView()
              }
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .lineLimit(1)
              .frame(maxWidth: .infinity)

              Text("=")
                .foregroundColor(.secondary)

              TextField(
                text: $variable.value,
                prompt: Text("value")
              ) {
                EmptyView()
              }
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .lineLimit(1)
              .frame(maxWidth: .infinity)

              Button(action: { removeVariable(id: variable.id) }) {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .foregroundColor(.secondary)
              .accessibilityLabel("Remove variable")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      HStack(spacing: 12) {
        Button(action: addVariable) {
          Label("Add variable", systemImage: "plus")
        }

        if !variables.isEmpty {
          Button(role: .destructive, action: clearVariables) {
            Label("Clear all", systemImage: "trash")
          }
          .transition(.opacity)
        }
      }
    }
    .animation(rowAnimation, value: variables.isEmpty)
    .animation(rowAnimation, value: variables.count)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func addVariable() {
    withAnimation(rowAnimation) {
      variables.append(CLIEnvironmentVariable(name: "", value: ""))
    }
  }

  private func removeVariable(id: UUID) {
    guard let index = variables.firstIndex(where: { $0.id == id }) else { return }
    _ = withAnimation(rowAnimation) {
      variables.remove(at: index)
    }
  }

  private func clearVariables() {
    withAnimation(rowAnimation) {
      variables.removeAll()
    }
  }
}
