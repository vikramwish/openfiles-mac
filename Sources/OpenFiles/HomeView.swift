import SwiftUI
import OpenFilesCore

private typealias HomeState<Value> = SwiftUI.State<Value>

/// Search is always available; collections provide a place to continue a task.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var collections: CollectionsModel
    @ObservedObject var cloud: CloudBrowserModel
    @HomeState private var creating = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Find what you need.").font(.largeTitle.weight(.semibold))
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name, contents, or date…", text: Binding(
                        get: { model.query },
                        set: { model.searchThisFolder = false; model.query = $0 }
                    ))
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .accessibilityLabel("Search your files")
                    if !model.query.isEmpty {
                        Button { model.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    } else { Text("⌘F").font(.caption).foregroundStyle(.secondary) }
                }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                if model.query.isEmpty {
                    Text("Try “PDFs in Downloads this month” or words from a document.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                BrowserView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HomeCloudView(cloud: cloud)
                        HStack {
                            Text("Your collections").font(.title2.weight(.semibold))
                            Spacer()
                            Button("New collection", systemImage: "plus") { creating = true }.disabled(collections.busy)
                        }
                        Text("Keep files for a trip, course, or project together. Originals stay where they are.")
                            .font(.callout).foregroundStyle(.secondary)
                        if collections.collections.isEmpty {
                            ContentUnavailableView {
                                Label("A place for your next task", systemImage: "rectangle.stack")
                            } description: {
                                Text("Create a collection, then add files from search or choose them from any folder.")
                            } actions: {
                                Button("Create collection") { creating = true }.disabled(collections.busy)
                            }.frame(maxWidth: .infinity).padding(.vertical, 20)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                                ForEach(collections.collections.prefix(6)) { collection in
                                    Button {
                                        model.selectedCollectionID = collection.id; model.section = .collections
                                    } label: {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.tint)
                                            Text(collection.title).font(.headline).lineLimit(2)
                                            Text("\(collection.files.count) references").font(.callout).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).padding(16)
                                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                            .contentShape(RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                            }
                            Button("View all collections") { model.selectedCollectionID = nil; model.section = .collections }
                        }
                        Divider().padding(.vertical, 4)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "checklist").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Preparing paperwork?").font(.headline)
                                Text("Use a checklist to review documents and export copies for a rental, trip, or expense claim.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Prepare documents") { model.section = .packs }
                            }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .onAppear { searchFocused = true }
        .sheet(isPresented: $creating) {
            CollectionNameSheet(heading: "New collection") { title in
                guard let id = await collections.create(title) else { return false }
                model.selectedCollectionID = id; model.section = .collections
                return true
            }
        }
    }
}
