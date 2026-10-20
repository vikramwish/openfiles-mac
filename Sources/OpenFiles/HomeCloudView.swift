import SwiftUI
import AppKit
import OpenFilesCore
import OpenFilesCloud

private struct CloudUploadReview: Identifiable {
    let id = UUID()
    let suggestion: CloudPlacementSuggestion
    let destinationID: String
    let destination: String
}

private typealias HomeCloudState<Value> = SwiftUI.State<Value>

@MainActor
struct HomeCloudView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var cloud: CloudBrowserModel
    @HomeCloudState private var review: CloudUploadReview?
    @HomeCloudState private var suggestions: [CloudPlacementSuggestion] = []
    @HomeCloudState private var suggestionTask: Task<Void, Never>?
    private var homeItems: [CloudItem] {
        Array(cloud.items.sorted {
            if $0.isFolder != $1.isFolder { return !$0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Cloud documents", systemImage: "cloud").font(.title2.weight(.semibold))
                        Spacer()
                        Button("View all") { app.section = .cloud }
                    }
                    Picker("Cloud provider", selection: Binding(get: { cloud.provider }, set: { cloud.selectProvider($0) })) {
                        ForEach(CloudProvider.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 330)
                        .disabled(cloud.connectionBusy || cloud.transferBusy)
                    if cloud.connected {
                        HStack {
                            if !cloud.folders.isEmpty {
                                Button { cloud.goBack() } label: { Image(systemName: "chevron.left") }.help("Parent folder")
                            }
                            Text(cloud.currentLocation.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            Button("Refresh") { cloud.refresh() }.disabled(cloud.loading)
                        }
                        if cloud.loading { ProgressView("Loading cloud documents…") }
                        else if homeItems.isEmpty { Text(cloud.error == nil ? "This folder is empty." : "Couldn’t load this folder. Try Refresh.").foregroundStyle(.secondary) }
                        ForEach(homeItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.tint)
                                Button(item.name) { open(item) }.buttonStyle(.plain).lineLimit(1)
                                    .help(item.isFolder ? "Open folder" : "Preview or open document")
                                FileLocationTag(location: cloud.currentLocation)
                                Spacer()
                                if let size = item.size { Text(bytes(size)).font(.caption).foregroundStyle(.secondary) }
                                if item.isFolder {
                                    Button { cloud.openFolder(item) } label: { Image(systemName: "chevron.right") }.help("Open folder")
                                } else if CloudPreviewPolicy.supports(item) {
                                    Button("Preview") { cloud.preview(item) }
                                } else if item.webURL != nil {
                                    Button("Open") { cloud.openOnWeb(item) }
                                } else if item.canDownload {
                                    Button("Save copy…") { cloud.saveCopy(item) }.disabled(cloud.transferBusy)
                                }
                            }.padding(.vertical, 4)
                        }
                        if cloud.items.count > 8 || cloud.nextPageToken != nil {
                            Button("Browse more documents…") { app.section = .cloud }
                        }
                        Text("Showing files in this folder. Select Preview to download a temporary copy.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let item = cloud.previewItem {
                            Divider()
                            CloudPreviewView(model: cloud, item: item).frame(height: 370)
                        }
                    } else if cloud.connectionBusy {
                        ProgressView("Loading cloud connection…")
                    } else {
                        Text("Connect Google Drive or OneDrive to see your documents here.").foregroundStyle(.secondary)
                        Button("Connect cloud storage…") { configureCloud() }
                    }
                    if let error = cloud.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(12)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Suggested for cloud storage", systemImage: "icloud.and.arrow.up").font(.title2.weight(.semibold))
                    Text("Large files and files last modified over 90 days ago, from your local index. Review a destination before uploading. Copies keep the original on your Mac and do not free disk space.")
                        .font(.callout).foregroundStyle(.secondary)
                    if suggestions.isEmpty {
                        Text("No candidates yet. Index local folders to find large or older files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(suggestions) { suggestion in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.source.lastPathComponent).lineLimit(1).help(suggestion.source.path)
                                Text("\(bytes(suggestion.size)) · \(suggestion.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review upload…") {
                                if cloud.connected && cloud.connectedForWriting {
                                    review = CloudUploadReview(suggestion: suggestion, destinationID: cloud.uploadDestinationID, destination: cloud.currentLocation.path)
                                } else { configureCloud() }
                            }.disabled(cloud.transferBusy || cloud.connectionBusy)
                        }
                    }
                    if cloud.connected && !cloud.connectedForWriting {
                        Button("Enable uploads…") { configureCloud() }
                        Text("Enable uploads in connection settings and reconnect to approve write access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if cloud.uploading {
                        HStack { ProgressView().controlSize(.small); Text(cloud.status); Button("Cancel upload") { cloud.cancelUpload() } }
                    }
                    if let summary = cloud.uploadSummary { Text(summary).font(.caption).textSelection(.enabled) }
                }.padding(12)
            }
        }
        .task { cloud.activate() }
        .onReceive(app.$state) { state in
            suggestionTask?.cancel()
            let files = state.files
            suggestionTask = Task {
                let values = await Task.detached(priority: .utility) { CloudPlacementSuggestions.suggest(files) }.value
                guard !Task.isCancelled else { return }
                suggestions = values
            }
        }
        .onDisappear { suggestionTask?.cancel(); cloud.deactivate() }
        .sheet(item: $review) { value in
            VStack(alignment: .leading, spacing: 16) {
                Text("Upload a cloud copy").font(.title2)
                Text(value.suggestion.source.lastPathComponent).font(.headline)
                Text(value.suggestion.source.path).font(.caption).textSelection(.enabled)
                Text("Indexed size: \(bytes(value.suggestion.size))")
                Text("Destination: \(value.destination)")
                Text("The current file contents and filename will be sent to this account. Existing cloud files will not be replaced. Your local original stays in place; this does not free disk space.")
                    .foregroundStyle(.secondary)
                if value.destinationID != cloud.uploadDestinationID {
                    Text("The destination changed. Close this review and choose the destination again.").foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { review = nil }.keyboardShortcut(.cancelAction)
                    Button("Show local file") { NSWorkspace.shared.activateFileViewerSelecting([value.suggestion.source]) }
                    Spacer()
                    Button("Upload copy") {
                        cloud.upload([value.suggestion.source], reviewedDestination: value.destinationID); review = nil
                    }.buttonStyle(.borderedProminent)
                        .disabled(!cloud.connected || !cloud.connectedForWriting || cloud.transferBusy || value.destinationID != cloud.uploadDestinationID)
                }
            }.padding(24).frame(width: 530)
        }
    }

    private func configureCloud() { cloud.showingRegistration = true; app.section = .cloud }
    private func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    private func open(_ item: CloudItem) {
        if item.isFolder { cloud.openFolder(item) }
        else if CloudPreviewPolicy.supports(item) { cloud.preview(item) }
        else if item.webURL != nil { cloud.openOnWeb(item) }
        else if item.canDownload { cloud.saveCopy(item) }
    }
}
