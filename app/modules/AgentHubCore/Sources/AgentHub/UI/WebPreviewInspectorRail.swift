//
//  WebPreviewInspectorRail.swift
//  AgentHub
//
//  Hybrid Figma-style edit rail for source-backed web preview changes.
//

import SwiftUI

struct WebPreviewInspectorRail: View {
  @Bindable var viewModel: WebPreviewInspectorViewModel
  let updateState: WebPreviewUpdateState
  let onUpdate: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header

      if let errorMessage = viewModel.errorMessage {
        statusBanner(errorMessage, color: .red)
          .padding(.horizontal, 12)
          .padding(.top, 10)
      }

      if viewModel.shouldShowLowConfidenceFallback {
        statusBanner(
          viewModel.needsSourceConfirmation
            ? "Low-confidence match. Choose a source file before live editing is enabled."
            : "Low-confidence match. Review the selected file before editing.",
          color: .orange
        )
        .padding(.horizontal, 12)
        .padding(.top, viewModel.errorMessage == nil ? 10 : 8)
      }

      Divider()
        .padding(.top, 10)

      if viewModel.isResolving {
        ProgressView("Mapping source…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        tabBar
        Divider()
        inspectorContent
      }
    }
    .background(Color(NSColor.windowBackgroundColor))
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if updateState.isVisible {
        WebPreviewUpdateBar(
          state: updateState,
          onUpdate: onUpdate
        )
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      if let snapshot = viewModel.selectedElementSnapshot {
        Image(nsImage: snapshot)
          .resizable()
          .scaledToFill()
          .frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.primary.opacity(0.08), lineWidth: 1)
          )
      }

      if let tagName = viewModel.selectedTagName {
        tagBadge(tagName)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(viewModel.relativeFilePath ?? "No mapped source")
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)

        if let selectorSummary = viewModel.selectorSummary {
          Text(selectorSummary)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        if let parentContext = viewModel.parentContext {
          Text("Inside \(parentContext.tagName.lowercased())")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }

        if let parentContextSummary = viewModel.parentContextSummary {
          Text(parentContextSummary)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        HStack(spacing: 8) {
          Text(viewModel.confidenceDisplayText)
          Text(viewModel.saveStatusText)
        }
        .font(.system(size: 11))
        .foregroundStyle(statusColor)
      }

      Spacer()

      if viewModel.isWriting {
        ProgressView()
          .controlSize(.small)
      }

      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background(Color.surfaceElevated)
  }

  private var inspectorContent: some View {
    Group {
      switch viewModel.selectedTab {
      case .design:
        designTabContent
      case .code:
        codeTabContent
      case .console:
        WebPreviewConsoleView(
          entries: viewModel.consoleEntries,
          onClear: viewModel.clearConsoleEntries
        )
      }
    }
  }

  private var tabBar: some View {
    HStack(spacing: 8) {
      ForEach(WebPreviewInspectorTab.allCases, id: \.self) { tab in
        Button {
          viewModel.selectTab(tab)
        } label: {
          Text(tab.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(viewModel.selectedTab == tab ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(viewModel.selectedTab == tab ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 8)
  }

  private var designTabContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let message = viewModel.designTabMessage {
          statusBanner(message, color: .secondary)
        }

        layoutSection
        propertiesSection
        contentSection
        boxModelSection
        typographySection
        stylesSection
        effectsSection
        if let snapshot = viewModel.liveProperties {
          BoxModelView(snapshot: snapshot)
          ElementTreeView(
            children: viewModel.childrenSummary,
            siblings: viewModel.siblingsSummary
          )
        }
      }
      .padding(12)
    }
  }

  private var layoutSection: some View {
    inspectorSection("Layout") {
      VStack(spacing: 6) {
        editableValueRow(
          title: "Display",
          value: formattedDisplayValue(for: .display),
          property: .display
        )
        readOnlyValueRow(title: "Position", value: viewModel.liveProperties?.position ?? "—")

        if let display = viewModel.liveProperties?.display?.lowercased(),
           display.contains("flex") || display.contains("grid") {
          readOnlyValueRow(title: "Flex Direction", value: viewModel.liveProperties?.flexDirection ?? "—")
          readOnlyValueRow(title: "Justify", value: viewModel.liveProperties?.justifyContent ?? "—")
          readOnlyValueRow(title: "Align Items", value: viewModel.liveProperties?.alignItems ?? "—")
          readOnlyValueRow(title: "Gap", value: viewModel.liveProperties?.gap ?? "—")
        }
      }
    }
  }

  private var propertiesSection: some View {
    inspectorSection("Properties") {
      VStack(spacing: 6) {
        editableValueRow(
          title: "Width",
          value: viewModel.metricValue(\.width),
          property: .width
        )
        editableValueRow(
          title: "Height",
          value: viewModel.metricValue(\.height),
          property: .height
        )
        editableValueRow(
          title: "Top",
          value: viewModel.metricValue(\.top),
          property: .top
        )
        editableValueRow(
          title: "Left",
          value: viewModel.metricValue(\.left),
          property: .left
        )
      }
    }
  }

  private var contentSection: some View {
    inspectorSection("Content") {
      Group {
        if viewModel.canEditContent {
          TextField(
            "Content",
            text: Binding(
              get: { viewModel.contentDisplayText == "—" ? "" : viewModel.contentDisplayText },
              set: { viewModel.updateContentValue($0) }
            ),
            axis: .vertical
          )
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13))
        } else {
          Text(viewModel.contentDisplayText)
            .font(.system(size: 13))
            .foregroundStyle(viewModel.contentDisplayText == "—" ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.primary.opacity(0.04))
        )
    }
  }

  private var typographySection: some View {
    inspectorSection("Typography") {
      VStack(spacing: 6) {
        editableValueRow(
          title: "Font",
          value: viewModel.typographyValue(\.fontFamily, fallbackTo: .fontFamily),
          property: .fontFamily
        )
        editableValueRow(
          title: "Weight",
          value: viewModel.typographyValue(\.fontWeight, fallbackTo: .fontWeight),
          property: .fontWeight
        )
        editableValueRow(
          title: "Size",
          value: viewModel.typographyValue(\.fontSize, fallbackTo: .fontSize),
          property: .fontSize
        )
        editableValueRow(
          title: "Line Height",
          value: viewModel.typographyValue(\.lineHeight, fallbackTo: .lineHeight),
          property: .lineHeight
        )
        editableValueRow(
          title: "Letter Spacing",
          value: formattedDisplayValue(for: .letterSpacing),
          property: .letterSpacing
        )
        editableValueRow(
          title: "Text Align",
          value: formattedDisplayValue(for: .textAlign),
          property: .textAlign
        )
        readOnlyValueRow(title: "Decoration", value: viewModel.liveProperties?.textDecoration ?? "—")
        readOnlyValueRow(title: "Transform", value: viewModel.liveProperties?.textTransform ?? "—")
      }
    }
  }

  private var boxModelSection: some View {
    inspectorSection("Box Model") {
      VStack(spacing: 6) {
        editableValueRow(
          title: "Margin",
          value: formattedDisplayValue(for: .margin),
          property: .margin
        )
        edgeValueRow(title: "Margin Top", value: viewModel.liveProperties?.marginEdges.top)
        edgeValueRow(title: "Margin Right", value: viewModel.liveProperties?.marginEdges.right)
        edgeValueRow(title: "Margin Bottom", value: viewModel.liveProperties?.marginEdges.bottom)
        edgeValueRow(title: "Margin Left", value: viewModel.liveProperties?.marginEdges.left)

        Divider()
          .padding(.vertical, 4)

        editableValueRow(
          title: "Padding",
          value: formattedDisplayValue(for: .padding),
          property: .padding
        )
        edgeValueRow(title: "Padding Top", value: viewModel.liveProperties?.paddingEdges.top)
        edgeValueRow(title: "Padding Right", value: viewModel.liveProperties?.paddingEdges.right)
        edgeValueRow(title: "Padding Bottom", value: viewModel.liveProperties?.paddingEdges.bottom)
        edgeValueRow(title: "Padding Left", value: viewModel.liveProperties?.paddingEdges.left)
      }
    }
  }

  private var stylesSection: some View {
    inspectorSection("Styles") {
      VStack(spacing: 6) {
        editableValueRow(
          title: "Text Color",
          value: formattedDisplayValue(for: .textColor),
          property: .textColor
        )
        editableValueRow(
          title: "Background",
          value: formattedDisplayValue(for: .backgroundColor),
          property: .backgroundColor
        )
        editableValueRow(
          title: "Radius",
          value: formattedDisplayValue(for: .borderRadius),
          property: .borderRadius
        )
      }
    }
  }

  private var effectsSection: some View {
    inspectorSection("Effects") {
      VStack(spacing: 6) {
        editableValueRow(
          title: "Opacity",
          value: formattedDisplayValue(for: .opacity),
          property: .opacity
        )
        readOnlyValueRow(title: "Box Shadow", value: viewModel.liveProperties?.boxShadow ?? "—")
      }
    }
  }

  private var codeTabContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Code")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)

        Spacer()

        if let relativeFilePath = viewModel.relativeFilePath {
          Text(relativeFilePath)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color.surfaceElevated.opacity(0.75))

      if viewModel.shouldShowLowConfidenceFallback, !viewModel.candidateFilePaths.isEmpty {
        Picker(
          "Source",
          selection: Binding(
            get: { viewModel.currentFilePath },
            set: { newPath in
              guard let newPath else { return }
              Task {
                await viewModel.selectCandidateFile(newPath)
              }
            }
          )
        ) {
          Text("Choose source file")
            .tag(Optional<String>.none)
          ForEach(viewModel.candidateFilePaths, id: \.self) { filePath in
            Text(viewModel.displayPath(for: filePath))
              .tag(Optional(filePath))
          }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }

      Divider()

      Group {
        if viewModel.currentFilePath == nil {
          ContentUnavailableView(
            "Choose a Source File",
            systemImage: "doc.text.magnifyingglass",
          description: Text("Low-confidence matches require a file choice before writes are enabled.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        SourceCodeEditorView(
            text: Binding(
              get: { viewModel.fileContent },
              set: { viewModel.fileContent = $0 }
            ),
            fileName: viewModel.currentFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Source",
            documentID: viewModel.editorDocumentID,
            displayMode: viewModel.editorDisplayMode,
            isEditable: viewModel.isEditingEnabled,
            onTextChange: { viewModel.updateEditorContent($0) },
            onIdleTextSnapshot: { _ in }
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func inspectorSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.surfaceElevated)
    )
  }

  private func editableValueRow(
    title: String,
    value: String,
    property: WebPreviewStyleProperty
  ) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

      Spacer()

      if viewModel.isEditable(property) {
        editableControl(title: title, property: property)
      } else {
        Text(value.isEmpty ? "—" : value)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(value.isEmpty ? .secondary : .primary)
      }
    }
  }

  private func readOnlyValueRow(title: String, value: String) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

      Spacer()

      Text(value)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.primary)
    }
  }

  private func edgeValueRow(title: String, value: String?) -> some View {
    readOnlyValueRow(title: title, value: value ?? "—")
  }

  private func styleBinding(for property: WebPreviewStyleProperty) -> Binding<String> {
    Binding(
      get: { viewModel.editorValue(for: property) },
      set: { viewModel.updateStyleEditorValue(property, value: $0) }
    )
  }

  @ViewBuilder
  private func editableControl(title: String, property: WebPreviewStyleProperty) -> some View {
    HStack(spacing: 8) {
      if property.supportsColorPicking {
        ColorPicker("", selection: colorBinding(for: property), supportsOpacity: true)
          .labelsHidden()
          .frame(width: 28)
      }

      TextField(
        title,
        text: styleBinding(for: property)
      )
      .textFieldStyle(.roundedBorder)
      .font(.system(size: 12, design: .monospaced))
      .multilineTextAlignment(property.supportsColorPicking ? .leading : .trailing)
      .frame(maxWidth: property.supportsColorPicking ? 132 : 92)

      if let unit = viewModel.detachedUnit(for: property) {
        Text(unit)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(minWidth: 24, alignment: .leading)
      }
    }
  }

  private func colorBinding(for property: WebPreviewStyleProperty) -> Binding<Color> {
    Binding(
      get: { viewModel.colorValue(for: property) },
      set: { viewModel.updateColorValue(property, color: $0) }
    )
  }

  private func formattedDisplayValue(for property: WebPreviewStyleProperty) -> String {
    let value = viewModel.displayedStyleValue(for: property)
    return value.isEmpty ? "—" : value
  }

  private func statusBanner(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(color)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(color.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(color.opacity(0.18), lineWidth: 1)
      )
  }

  private func tagBadge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold, design: .monospaced))
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        Capsule()
          .fill(Color.brandPrimary.opacity(0.9))
      )
  }

  private var statusColor: Color {
    if viewModel.writeErrorMessage != nil {
      return .red
    }
    if viewModel.isWriting || viewModel.hasUnsavedChanges {
      return .orange
    }
    return .secondary
  }
}
