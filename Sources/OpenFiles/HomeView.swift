import SwiftUI
import OpenFilesCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var packs: DocumentPacksModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your files, ready for what’s next.").font(.largeTitle.weight(.semibold))
                    Text("Find what you need, get your paperwork ready, and keep the versions that matter.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    action("Find something", detail: "A few words are enough. Search by name, topic, or date.", symbol: "magnifyingglass") { model.showSearch?() }
                    action("Make room", detail: "Review exact duplicates and possible cleanup candidates.", symbol: "sparkles.rectangle.stack") { model.section = .cleanup }
                    action("Prepare documents", detail: "Gather a checklist of files, review them, and export copies.", symbol: "checklist") { model.section = .packs }
                    action("Recover a version", detail: "Browse saved versions and restore earlier work.", symbol: "clock.arrow.circlepath") { model.section = .history }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("What are you getting ready for?").font(.title2.weight(.semibold))
                    Text("Start with an editable checklist. Templates are suggestions; check the recipient’s requirements.")
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(DocumentPackTemplate.examples) { template in
                            Button { packs.create(template); model.section = .packs } label: {
                                HStack { Image(systemName: "folder.badge.plus").foregroundStyle(.tint); Text(template.title).lineLimit(2).fixedSize(horizontal: false, vertical: true); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered).disabled(packs.busy)
                        }
                    }
                }
                if !packs.packs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Continue preparing").font(.title2.weight(.semibold))
                        ForEach(packs.packs.prefix(3)) { pack in
                            Button { packs.selectedID = pack.id; model.section = .packs } label: {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.tint)
                                    Text(pack.title).fontWeight(.medium)
                                    Spacer()
                                    Text("\(pack.items.filter { !$0.attachments.isEmpty }.count) of \(pack.items.count) items gathered").foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                GroupBox {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keep saved changes automatically").font(.headline)
                            Text("Choose important files or a small project folder. OpenFiles saves local versions while it’s running.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Set up…") { model.section = .protection }
                    }.padding(10)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "internaldrive")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On this Mac · \(model.library.searchCatalog.count) files indexed")
                        Text("Search coverage depends on folder access and supported formats. You can always choose documents yourself.")
                    }
                    Spacer()
                    Button("View coverage") { model.showingIndexing = true }
                }.font(.callout).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func action(_ title: String, detail: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol).font(.title).foregroundStyle(.tint)
                Text(title).font(.title3.weight(.semibold)).lineLimit(nil)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).padding(18).contentShape(Rectangle())
        }.buttonStyle(.bordered).multilineTextAlignment(.leading)
    }
}
