import SwiftUI
import OpenFilesCore

private typealias RenameState<Value> = SwiftUI.State<Value>

@MainActor
struct RenameSuggestionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: BrowserItem
    @RenameState private var preview: RenamePreview?
    @RenameState private var name = ""
    @RenameState private var loading = true
    @RenameState private var applying = false
    @RenameState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggest a filename").font(.title2.weight(.semibold))
            Text(item.name).font(.headline).textSelection(.enabled)
            Text("Choose a name based on this file’s content, or edit a suggestion before renaming. The file stays in its current folder.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("Reading content and comparing possible names…").padding(.vertical, 16) }
            if let preview {
                ForEach(preview.suggestions) { suggestion in
                    Button { name = suggestion.name } label: {
                        HStack {
                            Image(systemName: name == suggestion.name ? "checkmark.circle.fill" : "circle")
                            Text(suggestion.name).multilineTextAlignment(.leading)
                            Spacer()
                            Text(String(format: "%.2f", suggestion.similarity)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered).disabled(applying)
                }
                Text("Ranked by \(preview.model). Similarity scores are not confidence percentages.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("New filename", text: $name).textFieldStyle(.roundedBorder).disabled(applying)
                Text(item.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if error != nil && !loading { Button("Analyze again") { Task { await analyze() } }.disabled(applying) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("Rename file") { apply() }.buttonStyle(.borderedProminent)
                    .disabled(preview == nil || name.isEmpty || loading || applying)
            }
            if applying { ProgressView("Renaming and updating search…").controlSize(.small) }
        }.padding(24).frame(width: 560)
        .task { await analyze() }
        .interactiveDismissDisabled(applying)
        .onDisappear { if let preview { Task { await model.library.discardRenamePreview(preview.id) } } }
    }

    @MainActor private func analyze() async {
        loading = true; error = nil
        if let preview { await model.library.discardRenamePreview(preview.id) }
        preview = nil
        defer { loading = false }
        do {
            let result = try await model.library.previewRename(item.url)
            if Task.isCancelled { await model.library.discardRenamePreview(result.id); return }
            preview = result; name = result.suggestions.first?.name ?? ""
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func apply() {
        guard let preview else { return }
        applying = true; error = nil
        Task { @MainActor in
            defer { applying = false }
            do {
                let result = try await model.library.applyRename(previewID: preview.id, name: name)
                model.state = await model.library.current()
                model.reloadFolder(); model.selectedURL = result.destination
                model.status = "Renamed to \(result.destination.lastPathComponent)."
                if let warning = result.indexWarning { model.error = warning }
                dismiss()
            } catch { self.error = error.localizedDescription; self.preview = nil }
        }
    }
}
