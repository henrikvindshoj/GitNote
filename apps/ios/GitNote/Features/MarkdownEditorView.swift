import SwiftUI
import UIKit

struct MarkdownEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    let file: MarkdownFile
    @State private var text = ""
    @State private var editorCommand: MarkdownEditorCommand?
    @State private var lastSavedText = ""
    @State private var loaded = false
    @State private var isSaving = false
    @State private var showingRawMarkdown = false
    @State private var showingDestinationPrompt = false
    @State private var destination = "https://"
    @State private var destinationAction: MarkdownFormatAction = .link

    private var isDirty: Bool { loaded && text != lastSavedText }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownToolbox { action in
                if action == .link || action == .image {
                    destinationAction = action
                    destination = "https://"
                    showingDestinationPrompt = true
                } else {
                    editorCommand = MarkdownEditorCommand(action: action)
                }
            }
            Divider()

            if !loaded {
                ProgressView("Opening note…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RichMarkdownDocumentView(markdown: $text, command: $editorCommand)
                    .background(Color(uiColor: .systemBackground))
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("View Raw Markdown", systemImage: "chevron.left.forwardslash.chevron.right") {
                        showingRawMarkdown = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(!isDirty || isSaving)
            }
        }
        .sheet(isPresented: $showingRawMarkdown) {
            RawMarkdownView(markdown: text)
        }
        .alert(
            destinationAction == .image ? "Add Image" : "Add Link",
            isPresented: $showingDestinationPrompt
        ) {
            TextField("https://example.com", text: $destination)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Insert") {
                editorCommand = MarkdownEditorCommand(
                    action: destinationAction,
                    destination: destination
                )
            }
        } message: {
            Text(destinationAction == .image ? "Enter the image URL." : "Enter the link destination.")
        }
        .task {
            guard let contents = await model.read(file, in: workspace) else {
                dismiss()
                return
            }
            text = contents
            lastSavedText = contents
            loaded = true
        }
        .interactiveDismissDisabled(isDirty)
    }

    private func save() {
        isSaving = true
        Task {
            if await model.save(text, to: file, in: workspace) {
                lastSavedText = text
            }
            isSaving = false
        }
    }
}

private struct MarkdownToolbox: View {
    let apply: (MarkdownFormatAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Paragraph") { apply(.paragraph) }
                    Divider()
                    Button("Heading 1") { apply(.heading(1)) }
                    Button("Heading 2") { apply(.heading(2)) }
                    Button("Heading 3") { apply(.heading(3)) }
                    Button("Heading 4") { apply(.heading(4)) }
                    Button("Heading 5") { apply(.heading(5)) }
                    Button("Heading 6") { apply(.heading(6)) }
                } label: {
                    Label("Heading", systemImage: "textformat.size")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Heading size")

                formatButton("Bold", systemImage: "bold", action: .bold)
                formatButton("Italic", systemImage: "italic", action: .italic)
                formatButton("Bulleted list", systemImage: "list.bullet", action: .unorderedList)
                formatButton("Numbered list", systemImage: "list.number", action: .orderedList)
                formatButton("Blockquote", systemImage: "text.quote", action: .blockquote)
                formatButton("Link", systemImage: "link", action: .link)
                formatButton("Inline code", systemImage: "chevron.left.forwardslash.chevron.right", action: .inlineCode)

                Menu {
                    Button("Code block", systemImage: "chevron.left.forwardslash.chevron.right") {
                        apply(.codeBlock)
                    }
                    Button("Horizontal rule", systemImage: "minus") {
                        apply(.horizontalRule)
                    }
                    Button("Image", systemImage: "photo") {
                        apply(.image)
                    }
                } label: {
                    Label("More formatting", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("More formatting")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func formatButton(
        _ title: String,
        systemImage: String,
        action: MarkdownFormatAction
    ) -> some View {
        Button(title, systemImage: systemImage) { apply(action) }
            .labelStyle(.iconOnly)
            .accessibilityLabel(title)
    }
}

enum MarkdownFormatAction: Equatable {
    case bold
    case italic
    case inlineCode
    case heading(Int)
    case paragraph
    case unorderedList
    case orderedList
    case blockquote
    case codeBlock
    case horizontalRule
    case link
    case image
}

private struct RawMarkdownView: View {
    @Environment(\.dismiss) private var dismiss
    let markdown: String

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(markdown)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Raw Markdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
