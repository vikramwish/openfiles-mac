import SwiftUI
import OpenFilesCloud

struct FileLocationTag: View {
    let location: FileStorageLocation
    var body: some View {
        Label(location.label, systemImage: location.symbol)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.09), in: Capsule())
            .help((location.isRemote ? "Cloud: " : "On this Mac: ") + location.path)
            .accessibilityLabel("\(location.label), \(location.isRemote ? "cloud" : "local path"), \(location.path)")
    }
}
