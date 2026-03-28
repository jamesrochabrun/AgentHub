import Canvas
import Foundation

extension WebPreviewInspectorViewModel {
  var canvasInspectorPaneState: CanvasInspectorPaneState? {
    guard selectedElement != nil else { return nil }

    return CanvasInspectorPaneState(
      title: selectedTagName ?? "element",
      subtitle: relativeFilePath ?? "No mapped source",
      selector: selectorSummary,
      statusText: saveStatusText,
      messageText: canvasPaneMessageText,
      messageTone: canvasPaneMessageTone,
      sections: canvasPaneSections
    )
  }

  func applyCanvasInspectorChange(_ change: CanvasInspectorChange) {
    if change.property == "content" {
      updateContentValue(change.value)
      return
    }

    guard let property = WebPreviewStyleProperty(rawValue: change.property) else { return }

    if property.supportsColorPicking {
      updateStyleValue(property, value: change.value)
    } else {
      updateStyleEditorValue(property, value: change.value)
    }
  }

  private var canvasPaneSections: [CanvasInspectorPaneSection] {
    [
      CanvasInspectorPaneSection(title: "Properties", fields: [
        canvasField(for: .width),
        canvasField(for: .height),
        canvasField(for: .top),
        canvasField(for: .left),
      ]),
      CanvasInspectorPaneSection(title: "Content", fields: [
        CanvasInspectorPaneField(
          identifier: "content",
          label: "Content",
          kind: .text,
          value: contentDisplayText == "—" ? "" : contentDisplayText,
          isEditable: canEditContent
        )
      ]),
      CanvasInspectorPaneSection(title: "Typography", fields: [
        canvasField(for: .fontFamily),
        canvasField(for: .fontWeight),
        canvasField(for: .fontSize),
        canvasField(for: .lineHeight),
      ]),
      CanvasInspectorPaneSection(title: "Styles", fields: [
        canvasField(for: .textColor),
        canvasField(for: .backgroundColor),
        canvasField(for: .padding),
        canvasField(for: .borderRadius),
      ]),
    ]
  }

  private var canvasPaneMessageText: String? {
    if let errorMessage {
      return errorMessage
    }
    if let writeErrorMessage {
      return writeErrorMessage
    }
    if shouldShowLowConfidenceFallback {
      return needsSourceConfirmation
        ? "Low-confidence match. Choose a source file in Code mode before live edits are enabled."
        : "Low-confidence match. Review the selected file before editing."
    }
    return designTabMessage
  }

  private var canvasPaneMessageTone: CanvasInspectorPaneMessageTone? {
    if errorMessage != nil || writeErrorMessage != nil {
      return .error
    }
    if shouldShowLowConfidenceFallback {
      return .warning
    }
    if canvasPaneMessageText != nil {
      return .info
    }
    return nil
  }

  private func canvasField(for property: WebPreviewStyleProperty) -> CanvasInspectorPaneField {
    let isFieldEditable = isEditable(property)
    let baseValue = displayedStyleValue(for: property)
    let value = isFieldEditable ? editorValue(for: property) : (baseValue.isEmpty ? "—" : baseValue)
    let kind = canvasFieldKind(for: property, value: value)
    let unit = kind == .number ? detachedUnit(for: property) : nil

    return CanvasInspectorPaneField(
      identifier: property.rawValue,
      label: property.label,
      kind: kind,
      value: value == "—" ? "" : value,
      unit: unit,
      isEditable: isFieldEditable
    )
  }

  private func canvasFieldKind(
    for property: WebPreviewStyleProperty,
    value: String
  ) -> CanvasInspectorPaneFieldKind {
    if property.supportsColorPicking, !value.isEmpty {
      return .color
    }

    if Double(value) != nil {
      return .number
    }

    return .text
  }
}
