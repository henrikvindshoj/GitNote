import SwiftUI

struct MarkdownEditorView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case preview = "Preview"
        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    let file: MarkdownFile
    @State private var mode: Mode = .edit
    @State private var text = ""
    @State private var lastSavedText = ""
    @State private var loaded = false
    @State private var isSaving = false

    private var isDirty: Bool { loaded && text != lastSavedText }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Editor mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Group {
                if !loaded {
                    ProgressView("Opening note…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mode == .edit {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .secondarySystemBackground))
                } else {
                    MarkdownPreview(markdown: text)
                }
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!isDirty || isSaving)
            }
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

private struct MarkdownPreview: View {
    let markdown: String

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(markdown)
    }

    var body: some View {
        ScrollView {
            Text(rendered)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
