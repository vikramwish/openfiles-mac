import SwiftUI
import OpenFilesCloud

private typealias SyncReviewState<Value> = SwiftUI.State<Value>

@MainActor
struct CloudSyncReviewView: View {
    @ObservedObject var model: CloudBrowserModel
    let plan: CloudSyncPlan
    @SyncReviewState private var selected: CloudSyncAction?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review two-way sync").font(.title2)
            Text("\(plan.pair.localRoot.path) ↔ \(plan.pair.remoteFolderName)").font(.caption).textSelection(.enabled)
            Text("Compare competing copies before choosing which to keep. Replaced content is retained in local backups; deletions remain manual.").font(.caption).foregroundStyle(.secondary)
            if plan.changes.isEmpty { Text("The paired folders are up to date.") }
            List(plan.changes) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.path).font(.headline)
                        Text(action.kind.rawValue).foregroundStyle(action.kind == .conflict ? Color.orange : Color.secondary)
                        if !action.detail.isEmpty { Text(action.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if (action.kind == .compare || action.kind == .conflict), action.localDigest != nil, action.remote?.canDownload == true {
                        Button("Compare copies…") { selected = action }.disabled(model.transferBusy)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.dismissSyncPreview() }
                Button("Apply sync") { model.applySync() }.buttonStyle(.borderedProminent).disabled(model.transferBusy || plan.changes.isEmpty)
            }
        }.padding(24).frame(width: 720, height: 520)
        .sheet(item: $selected) { action in
            CloudConflictView(model: model, plan: plan, action: action)
        }
    }
}

@MainActor
private struct CloudConflictView: View {
    @ObservedObject var model: CloudBrowserModel
    @Environment(\.dismiss) private var dismiss
    let plan: CloudSyncPlan
    let action: CloudSyncAction
    @SyncReviewState private var showChanges = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare copies · \(action.path)").font(.title2).lineLimit(1)
            if model.comparingConflict { ProgressView("Downloading a temporary cloud copy and checking both versions…") }
            if let value = model.conflictComparison {
                HStack {
                    metadata("This Mac", size: value.localSize, modified: value.localModified)
                    Spacer()
                    metadata(plan.pair.provider.displayName, size: value.remote.size, modified: value.remote.modified)
                }
                if let text = value.text {
                    Picker("Comparison", selection: $showChanges) { Text("Text changes").tag(true); Text("Side by side").tag(false) }.pickerStyle(.segmented)
                    if showChanges {
                        if text.changes.isEmpty { Text("The contents are identical.") }
                        List(text.changes) { change in
                            Text("\(change.kind == .removed ? "− Local" : "+ Cloud") L\(change.line): \(change.text)")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(change.kind == .removed ? Color.red : Color.green).textSelection(.enabled)
                        }
                    } else {
                        HStack(alignment: .top) { textPane(text.local); Divider(); textPane(text.cloud) }
                    }
                } else {
                    Text("Text differences aren’t available for this format or size. Inspect the two previews before choosing.").font(.caption).foregroundStyle(.secondary)
                    HStack { FilePreview(url: value.localURL); Divider(); FilePreview(url: value.cloudURL) }
                }
                Text("Choosing a copy replaces the other version after checking it hasn’t changed. The replaced bytes are saved in local sync backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.comparisonError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.resolvingConflict)
                if model.comparisonError != nil { Button("Compare again") { model.compareConflict(plan, path: action.path) } }
                Spacer()
                Button("Keep local copy") { model.resolveConflict(.keepLocal) }.disabled(model.conflictComparison == nil || model.transferBusy)
                Button("Keep cloud copy") { model.resolveConflict(.keepCloud) }.disabled(model.conflictComparison == nil || model.transferBusy)
            }
            if model.resolvingConflict { ProgressView("Applying your choice…") }
        }.padding(24).frame(width: 960, height: 640)
        .onAppear { model.compareConflict(plan, path: action.path) }
        .onDisappear { model.dismissConflictComparison() }
        .interactiveDismissDisabled(model.resolvingConflict)
    }
    private func metadata(_ title: String, size: Int64?, modified: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable")
            if let modified { Text(modified, format: .dateTime.year().month().day().hour().minute()) }
            else { Text("Modification date unavailable") }
        }.font(.caption)
    }
    private func textPane(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
