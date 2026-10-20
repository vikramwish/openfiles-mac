import SwiftUI
import AppKit
import OpenFilesCore

private typealias HistoryState<Value> = SwiftUI.State<Value>

/// One inline composer shared by the inspector and optional editor companion.
struct VersionHistoryView: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @HistoryState private var message = ""
    @HistoryState private var review: VersionReview?
    @HistoryState private var selection = Set<String>()
    @HistoryState private var versionID: UUID?
    @HistoryState private var tab = 0
    @HistoryState private var running = false
    @HistoryState private var loading = true
    @HistoryState private var operationError: String?
    @HistoryState private var readError: String?
    @HistoryState private var feedback: String?
    private var versions: [FileVersion] {
        model.state.versions.filter { $0.source == url.resolvingSymlinksInPath().standardizedFileURL }
    }
    private var locked: Bool { running || model.versionBusy || loading || readError != nil }
    private var historical: FileVersion? { versions.first { $0.id == versionID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Versions", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Button { model.showVersionPanel(for: url) } label: { Image(systemName: "pip") }
                    .buttonStyle(.borderless).help("Keep versions beside your editor").accessibilityLabel("Keep versions beside your editor")
            }
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
                }
            }
            Picker("View", selection: $tab) {
                Text("Changes").tag(0)
                Text("History (\(versions.count))").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if tab == 0 { changes } else { history }
            if running { ProgressView("Updating versions…").controlSize(.small) }
            if let feedback { Label(feedback, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            if let detail = operationError ?? readError {
                Text(detail).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Refresh changes") { Task { await refresh(reset: true) } }.disabled(running)
            }
            Text("Versions capture changes saved in your editor. Restoring keeps a recovery version of your current work. Reopen the file in your editor to see restored changes.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18)
        .task(id: versionID) {
            review = nil; loading = true; operationError = nil
            await refresh(reset: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                await refresh()
            }
        }
    }
    private var changes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let historical {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Restore selected changes").font(.subheadline.weight(.semibold))
                        Text(historical.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Cancel") { versionID = nil; message = ""; feedback = nil }.disabled(locked)
                }
            }
            if loading { ProgressView("Reading changes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let review, review.changes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text(historical == nil ? "All changes are in version history" : "No changes to restore").font(.subheadline.weight(.medium))
                    Text(historical == nil ? "New edits appear here after your editor saves them." : "Choose another version to review its changes.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review {
                HStack {
                    Text("\(selection.count) of \(review.changes.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(selection.count == review.changes.count ? "Deselect all" : "Select all") {
                        selection = selection.count == review.changes.count ? [] : Set(review.changes.map(\.id))
                    }.buttonStyle(.borderless).font(.caption).disabled(locked)
                }
                if review.kind == .document {
                    Text("This format is saved and restored as a complete document.").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(review.changes) { change in
                            VStack(alignment: .leading, spacing: 7) {
                                Toggle(isOn: Binding(get: { selection.contains(change.id) }, set: { value in
                                    if value { selection.insert(change.id) } else { selection.remove(change.id) }
                                })) { Text(change.title).font(.caption.weight(.medium)).lineLimit(3) }
                                    .toggleStyle(.checkbox).disabled(locked)
                                if review.kind == .text {
                                    if !change.removed.isEmpty { diffText(change.removed, prefix: "−", color: .red) }
                                    if !change.added.isEmpty { diffText(change.added, prefix: "+", color: .green) }
                                } else if review.kind == .files {
                                    Text(change.added.isEmpty ? "Deleted" : change.removed.isEmpty ? "Added" : "Modified").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: .infinity)
            } else { Spacer() }
            TextField(historical == nil ? "Describe this version" : "Describe these restored changes", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4).accessibilityLabel(historical == nil ? "Version description" : "Restored changes description").disabled(running)
            Button(action: applySelection) {
                Label(historical == nil ? "Save version" : "Restore selected changes", systemImage: historical == nil ? "checkmark" : "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
                .disabled(locked || selection.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || review == nil)
        }
    }
    private func diffText(_ text: String, prefix: String, color: Color) -> some View {
        Text(prefix + " " + String(text.prefix(1600))).font(.system(.caption2, design: .monospaced))
            .foregroundStyle(color).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if versions.isEmpty {
                    Text("Save a version to start this file’s history.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 24)
                }
                ForEach(versions) { version in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(version.message).font(.subheadline.weight(.medium)).textSelection(.enabled)
                        Text(version.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Restore selected changes…") {
                                versionID = version.id; message = "Restore changes: \(version.message)"; tab = 0; feedback = nil
                            }
                            .help("Choose which changes from this version to restore")
                            Button("Restore entire version") { restore(version) }
                                .help("Restore this version and keep your current work in history")
                        }.font(.caption).disabled(locked)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.frame(maxHeight: .infinity)
    }
    @MainActor private func refresh(reset: Bool = false) async {
        guard !running else { return }
        let requested = versionID
        do {
            let fresh = try await model.library.reviewChanges(url, versionID: requested)
            guard !Task.isCancelled, requested == versionID, !running else { return }
            if reset || review == nil { selection = Set(fresh.changes.map(\.id)) }
            else if review?.changes != fresh.changes {
                // Never silently select edits that arrived after the user made a selection.
                let previous = Set(review?.changes ?? [])
                selection = previous.isEmpty ? Set(fresh.changes.map(\.id)) : Set(fresh.changes.filter { previous.contains($0) && selection.contains($0.id) }.map(\.id))
                feedback = "File updated. Review the latest changes."
            }
            review = fresh; loading = false; readError = nil
            if reset { operationError = nil }
        } catch {
            guard !Task.isCancelled, requested == versionID else { return }
            loading = false; readError = error.localizedDescription
        }
    }
    private func applySelection() {
        guard let review, !locked else { return }
        running = true; operationError = nil; feedback = nil
        let chosen = selection, note = message
        Task { @MainActor in
            do {
                if review.versionID == nil { try await model.commitChanges(review, selected: chosen, message: note) }
                else { try await model.cherryPick(review, selected: chosen, message: note) }
                feedback = review.versionID == nil ? "Version saved: \(note)" : "Selected changes restored."
                message = ""; running = false
                if versionID != nil { versionID = nil } else { await refresh(reset: true) }
            } catch { running = false; operationError = error.localizedDescription }
        }
    }
    private func restore(_ version: FileVersion) {
        guard let review, !locked else { return }
        running = true; operationError = nil; feedback = nil
        Task { @MainActor in
            do {
                try await model.restoreVersion(version, expectedDigest: review.workingDigest)
                feedback = "Restored. Your previous saved work is in history."
                running = false
                if versionID != nil { versionID = nil } else { await refresh(reset: true) }
            } catch { running = false; operationError = error.localizedDescription }
        }
    }
}

struct EditingVersionsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let url = model.editingURL { VersionHistoryView(url: url).id(url) }
            else { Text("Select a file in OpenFiles to review its changes.").padding() }
        }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
}
