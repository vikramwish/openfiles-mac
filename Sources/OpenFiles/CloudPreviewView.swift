import SwiftUI
import OpenFilesCloud

@MainActor
struct CloudPreviewView: View {
    @ObservedObject var model: CloudBrowserModel
    let item: CloudItem
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(item.name).font(.headline).lineLimit(1)
                FileLocationTag(location: model.currentLocation)
                Spacer()
                Button { model.dismissCloudPreview() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Close preview")
            }
            Text("Preview downloads a temporary copy, removed when you close it. Save a copy to keep the file.")
                .font(.caption).foregroundStyle(.secondary)
            if let size = (model.cloudPreview?.item ?? item).size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            Divider()
            if let value = model.cloudPreview { FilePreview(url: value.url) }
            else if model.previewLoading { ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark", description: Text(model.previewError ?? "Open this file on the provider’s website."))
            }
            HStack {
                if item.webURL != nil { Button("Open in browser") { model.openOnWeb(item) } }
                Spacer()
                if item.canDownload { Button("Save copy…") { model.saveCopy(item) }.disabled(model.transferBusy) }
                if model.previewError != nil { Button("Retry") { model.preview(item) } }
            }
        }.padding(12).frame(minHeight: 240, maxHeight: .infinity)
    }
}
