import SwiftUI
import OpenFilesCore
import OpenFilesAgent

/// Reviewable membership suggestions for one collection.
struct CollectionSuggestionSet: Identifiable {
    let id = UUID()
    let collection: FileCollection
    let members: [AgentCollectionMember]
    let ignored: [String]
    /// true when the configured model refined the pick; false when only the local index ranked it.
    let refinedByModel: Bool
}

/// Review before any reference is added: rows show why each file was suggested, and only
/// the checked rows are added through the collection store.
struct CollectionSuggestionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []

    private var suggestion: CollectionSuggestionSet? { model.collectionSuggestions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Files for “\(suggestion?.collection.title ?? "")”").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(suggestion.map { $0.refinedByModel ? "ranked by \(model.agentModel) · you approve every reference" : "ranked by your local index · you approve every reference" } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { finish() }.keyboardShortcut(.cancelAction)
            }
            if let suggestion {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestion.members.enumerated()), id: \.element.url) { index, member in
                            Toggle(isOn: Binding(
                                get: { selected.contains(member.url) },
                                set: { if $0 { selected.insert(member.url) } else { selected.remove(member.url) } }
                            )) {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "doc").foregroundStyle(Color.accentColor).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(member.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                                        Text(member.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle).help(member.url.path)
                                        if !member.reason.isEmpty {
                                            Text(member.reason).font(.caption).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 4)
                            }.toggleStyle(.checkbox)
                            if index < suggestion.members.count - 1 { Divider() }
                        }
                    }
                }
                if !suggestion.ignored.isEmpty {
                    Text(suggestion.ignored.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                DisclosureGroup("What is sent to the model service") {
                    Text("Candidate file names, paths, sizes and short text excerpts of the candidates the app already found in your index. The model only chooses among them; it cannot invent files. References are added only for the rows you approve.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }.font(.caption)
                HStack {
                    Button(selected.count == suggestion.members.count ? "Deselect all" : "Select all") {
                        selected = selected.count == suggestion.members.count ? [] : Set(suggestion.members.map(\.url))
                    }
                    Spacer()
                    Button("Add \(selected.count) file\(selected.count == 1 ? "" : "s")") {
                        model.applyCollectionSuggestions(Array(selected))
                    }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                }
            }
            if let error = model.collectionSuggestionError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
        }.padding(20).frame(width: 620, height: 560)
        .onAppear { selected = Set(suggestion?.members.map(\.url) ?? []) }
    }

    private func finish() {
        model.collectionSuggestions = nil
        dismiss()
    }
}
