import SwiftUI
import OpenFilesCloud

private typealias StorageViewState<Value> = SwiftUI.State<Value>

struct StorageUsageView: View {
    let title: String
    let usage: StorageUsage?
    var loading = false
    var error: String?
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.medium))
                if loading { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing storage usage") }
            }
            if let usage {
                if let available = usage.available, let total = usage.total {
                    Text("\(bytes(available)) available of \(bytes(total))")
                } else if let used = usage.used {
                    Text("\(bytes(used)) used · storage limit unavailable")
                } else if let available = usage.available {
                    Text("\(bytes(available)) available · storage limit unavailable")
                } else if let total = usage.total {
                    Text("\(bytes(total)) total · available space unavailable")
                }
                if let fraction = usage.fractionUsed {
                    ProgressView(value: fraction).frame(maxWidth: 240).tint(fraction >= 0.9 ? .orange : .accentColor)
                        .accessibilityLabel("\(Int(fraction * 100)) percent used")
                }
            } else if !loading { Text("Storage usage unavailable").help(error ?? "Try refreshing.") }
            if let error, usage != nil { Text("Couldn’t refresh usage").help(error) }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct VolumeStorageView: View {
    let url: URL
    @StorageViewState private var usage: StorageUsage?
    @StorageViewState private var title = "This Mac"
    @StorageViewState private var error: String?
    @StorageViewState private var loading = false

    var body: some View {
        StorageUsageView(title: title, usage: usage, loading: loading, error: error)
            .task(id: url) {
                // Read filesystem metadata off the UI actor and refresh while the view is visible.
                while !Task.isCancelled {
                    loading = true
                    let result = await Task.detached(priority: .utility) { [url] () -> (StorageUsage?, String, String?) in
                        do {
                            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
                            guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else {
                                return (nil, "This Mac", "The volume did not report its capacity.")
                            }
                            return (StorageUsage(used: Int64(max(0, total - free)), total: Int64(total), available: Int64(free)), values.volumeName ?? "This Mac", nil)
                        } catch { return (nil, "This Mac", error.localizedDescription) }
                    }.value
                    guard !Task.isCancelled else { return }
                    usage = result.0; title = "This Mac · " + result.1; error = result.2; loading = false
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
    }
}
