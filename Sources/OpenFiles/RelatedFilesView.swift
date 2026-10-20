import SwiftUI
import OpenFilesCore

private typealias RelatedState<Value> = SwiftUI.State<Value>

struct RelatedFilesView: View {
    @EnvironmentObject private var model: AppModel
    let url: URL
    @RelatedState private var expanded = false
    @RelatedState private var matches: [FileRelationship] = []
    private struct Request: Hashable { let url: URL; let revision: UInt64; let expanded: Bool }
    var body: some View {
        DisclosureGroup("Related Files", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if matches.isEmpty { Text("No related indexed files yet.").foregroundStyle(.secondary).font(.caption) }
                ForEach(matches) { match in
                    Button {
                        model.navigate(to: match.file.url.deletingLastPathComponent()); model.selectedURL = match.file.url
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(match.file.name, systemImage: "doc").lineLimit(1)
                            if !match.sharedTerms.isEmpty {
                                Text(match.sharedTerms.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            } else { Text("Similar indexed content").font(.caption2).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(match.file.url.path)
                }
            }.padding(.top, 8)
        }.font(.callout).padding(16)
        .task(id: Request(url: url, revision: model.library.searchCatalog.revision, expanded: expanded)) {
            guard expanded else { return }
            let catalog = model.library.searchCatalog, source = url
            let result = await Task.detached(priority: .utility) { catalog.relatedFiles(to: source, limit: 4) }.value
            guard !Task.isCancelled else { return }; matches = result
        }
    }
}
