import SwiftUI
import OpenFilesCore

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let items: [BrowserItem]
}
private typealias BatchState<Value> = SwiftUI.State<Value>

@MainActor
struct BatchRenameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: BatchRenameRequest
    @BatchState private var preview: BatchRenamePreview?
    @BatchState private var names: [URL: String] = [:]
    @BatchState private var selected = Set<URL>()
    @BatchState private var prefix = ""
    @BatchState private var includeDate = false
    @BatchState private var loading = false
    @BatchState private var applying = false
    @BatchState private var error: String?
    @BatchState private var report: BatchRenameReport?
    @BatchState private var analysis: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggest filenames · \(request.items.count) files").font(.title2.weight(.semibold))
            Text("Review each name and check the files you want to rename. Names stay in their original folders and retain their extensions.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Shared prefix, such as a project name", text: $prefix).textFieldStyle(.roundedBorder)
                Toggle("Modified date", isOn: $includeDate)
                Button("Apply naming pattern") { applyPattern() }.disabled(preview == nil)
            }.disabled(loading || applying || report != nil)
            if loading { ProgressView("Reading content and ranking names for \(request.items.count) files…") }
            if let preview, report == nil {
                HStack {
                    Button("Select all suggestions") { selected = Set(preview.rows.filter { $0.preview != nil }.map(\.source)) }
                    Button("Deselect all") { selected = [] }
                    Spacer()
                    Text("\(selected.count) selected").foregroundStyle(.secondary)
                }.disabled(applying)
                List(preview.rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Toggle(row.source.lastPathComponent, isOn: Binding(get: { selected.contains(row.source) }, set: { if $0 { selected.insert(row.source) } else { selected.remove(row.source) } }))
                                .toggleStyle(.checkbox).disabled(row.preview == nil)
                            Spacer()
                            if let suggestion = row.preview {
                                Menu("Alternatives") {
                                    ForEach(suggestion.suggestions) { option in
                                        Button(option.name) { names[row.source] = patterned(option.name, preview: suggestion) }
                                    }
                                }
                            }
                        }
                        if row.preview != nil {
                            TextField("New filename", text: Binding(get: { names[row.source] ?? "" }, set: { names[row.source] = $0 })).textFieldStyle(.roundedBorder)
                        }
                        if let problem = row.problem { Text(problem).foregroundStyle(.orange) }
                        Text(row.source.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.font(.callout).padding(.vertical, 5).disabled(applying)
                }
            } else if let report {
                Text("Renamed \(report.renamed) of \(report.outcomes.count) selected files.").font(.headline)
                List(report.outcomes) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(result.source.lastPathComponent, systemImage: result.destination == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        if let destination = result.destination { Text("→ " + destination.lastPathComponent) }
                        if let message = result.message { Text(message).foregroundStyle(.secondary) }
                    }
                }
            } else { Spacer() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if preview == nil && !loading { Button("Analyze again") { startAnalysis() } }
                Spacer()
                Button(report == nil ? "Cancel" : "Done") { analysis?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                if report == nil {
                    Button("Rename \(selected.count) selected files") { apply() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || loading || applying)
                }
            }
            if applying { ProgressView("Renaming reviewed files…") }
        }.padding(24).frame(width: 800, height: 620)
        .onAppear { startAnalysis() }
        .onDisappear {
            analysis?.cancel()
            if let preview { Task { await model.library.discardBatchRename(preview.id) } }
        }
        .interactiveDismissDisabled(applying)
    }
    private func patterned(_ name: String, preview: RenamePreview) -> String {
        BatchRenamePattern.name(name, prefix: prefix, modified: includeDate ? preview.modified : nil)
    }
    private func applyPattern() {
        guard let preview else { return }
        for row in preview.rows {
            if let value = row.preview, let suggestion = value.suggestions.first { names[row.source] = patterned(suggestion.name, preview: value) }
        }
    }
    private func startAnalysis() {
        analysis?.cancel(); loading = true; error = nil; selected = []
        analysis = Task {
            defer { loading = false }
            do {
                let value = try await model.library.previewBatchRename(request.items.map(\.url))
                if Task.isCancelled { await model.library.discardBatchRename(value.id); return }
                preview = value; applyPattern()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func apply() {
        guard let preview else { return }
        applying = true; error = nil
        let choices = names.filter { selected.contains($0.key) }
        Task {
            defer { applying = false }
            do {
                let result = try await model.library.applyBatchRename(preview.id, names: choices)
                report = result
                model.state = await model.library.current()
                model.refreshAfterRenames(result.outcomes.compactMap { item in item.destination.map { (item.source, $0) } })
                model.status = "Renamed \(result.renamed) selected files."
            } catch { self.error = error.localizedDescription }
        }
    }
}
