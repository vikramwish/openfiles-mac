import SwiftUI
import OpenFilesCore

private typealias HomeState<Value> = SwiftUI.State<Value>

/// The task controls stay in place while the work below changes.
@MainActor
struct HomeView<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var packs: DocumentPacksModel
    @ViewBuilder var content: () -> Content
    @HomeState private var search = ""
    @HomeState private var showingResults = false

    private let tasks: [(AppModel.Section, String, String, String)] = [
        (.organize, "Organize", "Bring related files together", "tray.2"),
        (.photos, "Photos", "Search, albums, and duplicates", "photo.on.rectangle.angled"),
        (.cleanup, "Clean up", "Find duplicates and make room", "sparkles.rectangle.stack"),
        (.protection, "Protect", "Keep saved changes automatically", "shield.lefthalf.filled"),
        (.history, "Recover", "Restore an earlier version", "clock.arrow.circlepath"),
        (.packs, "Collect documents", "Gather and export paperwork", "checklist"),
        (.vault, "Private vault", "Lock away private files", "lock.shield")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your files, taken care of.").font(.title.weight(.semibold))
                    Spacer()
                    Button { model.chooseOrganizationFolder() } label: { Label("Add folder", systemImage: "folder.badge.plus") }
                    Button { model.showingIndexing = true } label: { Label("File activity", systemImage: "waveform.path") }
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.section == .photos ? "Find photos by name, date, place, or contents…" : "Find a file by name, contents, or date…", text: $search)
                        .textFieldStyle(.plain).onSubmit(findFiles)
                        .accessibilityLabel("Find files")
                    if showingResults {
                        Button("Clear") { search = ""; model.query = ""; showingResults = false }
                    }
                    Button("Find", action: findFiles)
                        .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140), spacing: 8), count: 4), spacing: 8) {
                    ForEach(tasks, id: \.0) { task in
                        Button {
                            showingResults = false
                            model.query = ""
                            model.section = task.0
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: task.3).font(.title3).foregroundStyle(.tint).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.1).font(.headline)
                                    Text(task.2).font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                                .background(selected(task.0) && !showingResults ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected(task.0) && !showingResults ? Color.accentColor : Color.clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selected(task.0) && !showingResults ? .isSelected : [])
                    }
                }
            }.padding(20)
            Divider()
            Group {
                if showingResults { BrowserView() }
                else { content() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.query) {
            search = model.query
            showingResults = model.section != .photos && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private func selected(_ section: AppModel.Section) -> Bool {
        model.section == section || (section == .organize && model.section == .home)
    }
    private func findFiles() {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.searchThisFolder = false
        model.query = text
        showingResults = model.section != .photos
    }
}
