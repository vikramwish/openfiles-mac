import SwiftUI
import AppKit
import OpenFilesCore

private typealias HistoryState<Value> = SwiftUI.State<Value>

/// Shared by the browser inspector and the floating companion in external editors.
struct VersionHistoryView: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @HistoryState private var message = ""
    @HistoryState private var savedStatus = "Checking saved changes…"
    @HistoryState private var operationError: String?
    private var versions: [FileVersion] {
        model.state.versions.filter { $0.source == url.resolvingSymlinksInPath().standardizedFileURL }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Version history", systemImage: "clock.arrow.circlepath").font(.headline)
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
                }
            }
            Label(savedStatus, systemImage: "externaldrive.badge.checkmark").font(.caption).foregroundStyle(.secondary)
            TextField("What changed? (optional)", text: $message).textFieldStyle(.roundedBorder).accessibilityLabel("Commit message")
            Button { model.commitFile(url, message: message) } label: {
                Label("Commit saved changes", systemImage: "plus.circle").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(model.busy)
            Text("Save in your editor first. Only changes saved to disk are committed.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("\(versions.count) committed versions").font(.caption.weight(.medium))
                Spacer()
                Button { model.showVersionPanel(for: url) } label: { Image(systemName: "pip") }.help("Keep versions beside your editor").accessibilityLabel("Keep versions beside your editor")
            }
            if versions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.checkmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Start this file’s history").font(.subheadline.weight(.medium))
                    Text("Commit a first version to return to it later.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(versions) { version in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(version.message).font(.subheadline.weight(.medium)).textSelection(.enabled)
                                Text(version.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(String(version.id.uuidString.prefix(8))).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                    Spacer()
                                    Menu("Restore") {
                                        Button("Open restored copy…") { model.restoreAndOpen(version) }
                                        Button("Export copy…") { model.export(version) }
                                    }.fixedSize().disabled(model.busy)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text("Restore opens a separate copy in its default app. Your current file stays in place.").font(.caption2).foregroundStyle(.secondary)
            if let operationError { Text(operationError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if model.busy { ProgressView("Working…").controlSize(.small) }
        }.padding(18)
        .task(id: url) {
            message = ""
            while !Task.isCancelled {
                do {
                    let status = try await model.library.versionStatus(url)
                    guard !Task.isCancelled else { return }
                    savedStatus = status; operationError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    savedStatus = "Saved file unavailable"; operationError = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
        .onChange(of: model.state.versions.count) {
            Task {
                do { savedStatus = try await model.library.versionStatus(url) }
                catch { operationError = error.localizedDescription }
            }
        }
    }
}

struct EditingVersionsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let url = model.editingURL { VersionHistoryView(url: url).id(url) }
            else { Text("Open a file from OpenFiles to see its versions.").padding() }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .alert("OpenFiles", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
