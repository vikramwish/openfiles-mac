import SwiftUI
import AppKit
import OpenFilesCore

private typealias PackState<Value> = SwiftUI.State<Value>

struct DocumentPacksView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var packs: DocumentPacksModel
    @PackState private var editingPack: DocumentPack?
    @PackState private var deletingPack: DocumentPack?
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Document packs").font(.title2.weight(.semibold))
                Menu {
                    ForEach(DocumentPackTemplate.examples) { template in
                        Button(template.title) { packs.create(template) }
                    }
                } label: { Label("New pack", systemImage: "plus") }.disabled(packs.busy)
                if packs.packs.isEmpty {
                    Text("Your checklists will appear here. Start with a template or create your own.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                } else {
                    List(selection: $packs.selectedID) {
                        ForEach(packs.packs) { pack in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(pack.title).fontWeight(.medium)
                                Text("\(pack.items.filter { !$0.attachments.isEmpty }.count) of \(pack.items.count) gathered")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).tag(pack.id)
                        }
                    }.listStyle(.plain)
                }
            }.padding(20).frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            Group {
                if let pack = packs.selected { detail(pack).id(pack.id) }
                else { welcome }
            }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Couldn’t update document pack", isPresented: Binding(get: { packs.error != nil }, set: { if !$0 { packs.error = nil } })) {
            Button("OK") { packs.error = nil }
        } message: { Text(packs.error ?? "") }
        .sheet(item: $editingPack) { pack in
            PackChecklistEditor(pack: pack) { packs.save($0, replacing: pack); editingPack = nil }
        }
        .confirmationDialog("Remove this checklist?", isPresented: Binding(get: { deletingPack != nil }, set: { if !$0 { deletingPack = nil } }), titleVisibility: .visible) {
            Button("Remove checklist", role: .destructive) { if let pack = deletingPack { packs.delete(pack) }; deletingPack = nil }
        } message: { Text("Your original documents and any exported copies stay where they are.") }
    }
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.tint)
                Text("Get your paperwork ready.").font(.largeTitle.weight(.semibold))
                Text("Pick a checklist, gather the documents, then review and export copies in one folder.")
                    .font(.title3).foregroundStyle(.secondary)
                ForEach(DocumentPackTemplate.examples) { template in
                    Button { packs.create(template) } label: {
                        HStack { Label(template.title, systemImage: "folder.badge.plus"); Spacer(); Image(systemName: "chevron.right") }
                            .padding(12).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(packs.busy)
                }
                Text("Templates are editable starting points, not official requirements. Check the recipient’s checklist before sharing.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(30).frame(maxWidth: 650, alignment: .leading)
        }
    }
    private func detail(_ pack: DocumentPack) -> some View {
        let attachments = pack.items.flatMap(\.attachments)
        let missing = pack.items.filter { $0.required && $0.attachments.isEmpty }.count
        let unreviewed = attachments.filter { !$0.reviewed }.count
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(pack.title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                            Text("Gather → Review → Export").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Edit checklist…") { editingPack = pack }
                            Button("Remove checklist…", role: .destructive) { deletingPack = pack }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Pack options")
                    }
                    Text("Check the recipient’s requirements. A match or a recent modification date does not confirm a document is correct or still valid.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let exported = packs.exportedURL {
                        GroupBox {
                            HStack {
                                Label("Copies exported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Spacer()
                                Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }
                            }.padding(6)
                        }
                    }
                    if pack.items.isEmpty {
                        ContentUnavailableView("Add your first checklist item", systemImage: "checklist", description: Text("Use Edit checklist to describe the documents you need."))
                        Button("Edit checklist…") { editingPack = pack }
                    }
                    ForEach(pack.items) { item in
                        PackItemView(item: item, pack: pack, packs: packs)
                    }
                    Label("Suggestions use your local index. Sensitive or unsupported documents may not appear; use Choose files to add them yourself.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(26)
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                if packs.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(attachments.count) files · \(unreviewed) to review · \(missing) required items missing").font(.callout.weight(.medium))
                    Text("Export rechecks reviewed files. Missing items are listed in the exported checklist.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export copies…") { packs.export(pack) }
                    .buttonStyle(.borderedProminent).disabled(packs.busy || attachments.isEmpty || unreviewed > 0)
            }.padding(18)
        }.disabled(packs.busy)
    }
}

private struct PackItemView: View {
    @EnvironmentObject private var model: AppModel
    let item: DocumentPackItem
    let pack: DocumentPack
    @ObservedObject var packs: DocumentPacksModel
    @PackState private var showingSuggestions = false
    @PackState private var reviewAttachment: DocumentPackAttachment?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.attachments.isEmpty ? "circle.dashed" : "doc.on.doc").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.headline)
                        Text(item.required ? "Required in this checklist" : "Optional").font(.caption).foregroundStyle(.secondary)
                        if !item.detail.isEmpty { Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                }
                ForEach(item.attachments) { attachment in
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text(attachment.url.lastPathComponent).fontWeight(.medium).lineLimit(2)
                        Text(attachment.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(attachment.url.path)
                        HStack(spacing: 10) {
                            Label(attachment.reviewed ? "Reviewed · rechecked on export" : "Needs your review", systemImage: attachment.reviewed ? "checkmark.circle" : "eye")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(attachment.reviewed ? "Review again…" : "Review…") { reviewAttachment = attachment }
                            Button { packs.remove(attachment, in: pack) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove from checklist").accessibilityLabel("Remove \(attachment.url.lastPathComponent) from checklist")
                        }
                    }
                }
                HStack {
                    Button("Choose files…") { packs.chooseFiles(for: item, in: pack) }
                    Button("Find suggestions…") { showingSuggestions = true }
                    Spacer()
                }
            }.padding(10)
        }
        .sheet(isPresented: $showingSuggestions) {
            PackSuggestionsView(item: item, pack: pack, packs: packs)
        }
        .sheet(item: $reviewAttachment) { attachment in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(attachment.url.lastPathComponent).font(.title2.weight(.semibold))
                    Text("Check that this is the right document, is current, and contains only information you want to include. Export copies the whole file without redaction.")
                        .foregroundStyle(.secondary)
                    Text(attachment.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                Divider()
                FilePreview(url: attachment.url).frame(minWidth: 600, minHeight: 380)
                Divider()
                HStack {
                    Button("Open original") { NSWorkspace.shared.open(attachment.url) }
                    Spacer()
                    Button("Cancel") { reviewAttachment = nil }.keyboardShortcut(.cancelAction)
                    Button("Mark as reviewed") { packs.review(attachment, in: pack); reviewAttachment = nil }
                        .buttonStyle(.borderedProminent)
                }.padding(18)
            }.frame(width: 720, height: 630)
        }
    }
}

private struct PackSuggestionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: DocumentPackItem
    let pack: DocumentPack
    @ObservedObject var packs: DocumentPacksModel
    @PackState private var query = ""
    @PackState private var matches: [FileSearchMatch] = []
    @PackState private var searching = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find \(item.title.lowercased())").font(.title2.weight(.semibold))
            TextField("A filename or topic", text: $query).textFieldStyle(.roundedBorder)
            Text("Suggestions are possible matches, not verified documents. Add a file, then review it in your checklist.").font(.callout).foregroundStyle(.secondary)
            if searching { ProgressView().controlSize(.small) }
            if matches.isEmpty && !searching {
                ContentUnavailableView("No matches in the local index", systemImage: "doc.text.magnifyingglass", description: Text("Try a different word or choose a file yourself. Sensitive files may be excluded from search."))
            } else {
                List(matches, id: \.file.id) { match in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(match.file.name).fontWeight(.medium)
                            Text(match.reason).font(.caption).foregroundStyle(.secondary)
                            Text(match.file.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(match.file.url.path)
                        }
                        Spacer()
                        Button("Add") { packs.attach([match.file.url], to: item, in: pack); dismiss() }
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
            }
            HStack {
                Button("Choose files…") { dismiss(); packs.chooseFiles(for: item, in: pack) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 650, height: 500)
        .onAppear { query = item.query }
        .task(id: query) {
            searching = true
            defer { searching = false }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            var byURL: [URL: FileSearchMatch] = [:]
            for term in query.split(separator: ",").prefix(8) {
                let results = await model.library.searchMatches(String(term))
                guard !Task.isCancelled else { return }
                for match in results {
                    if match.score > (byURL[match.file.url]?.score ?? -.infinity) { byURL[match.file.url] = match }
                }
            }
            let results = byURL.values.sorted { $0.score == $1.score ? $0.file.url.path < $1.file.url.path : $0.score > $1.score }
            guard !Task.isCancelled else { return }
            let attached = Set(pack.items.flatMap(\.attachments).map(\.url))
            matches = Array(results.filter { !$0.file.sensitive && !$0.file.isProject && !attached.contains($0.file.url) }.prefix(20))
        }
    }
}

private struct PackChecklistEditor: View {
    @Environment(\.dismiss) private var dismiss
    @PackState var pack: DocumentPack
    var save: (DocumentPack) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit checklist").font(.title2.weight(.semibold))
            TextField("Pack title", text: $pack.title).textFieldStyle(.roundedBorder)
            Text("Adapt this list to the recipient’s requirements. Removing an item removes its references from this checklist, not your original files.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 16) {
                    ForEach($pack.items) { $item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Document needed", text: $item.title)
                                TextField("Instructions or requirements", text: $item.detail)
                                TextField("Search words (separate alternatives with commas)", text: $item.query)
                                HStack {
                                    Toggle("Required", isOn: $item.required)
                                    Spacer()
                                    Button("Remove item", role: .destructive) { pack.items.removeAll { $0.id == item.id } }
                                }
                            }.textFieldStyle(.roundedBorder).padding(8)
                        }
                    }
                }
            }
            HStack {
                Button("Add item") { pack.items.append(DocumentPackItem(title: "", detail: "", query: "", required: true)) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save checklist") { save(pack) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(pack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pack.items.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(24).frame(width: 640, height: 600)
    }
}
