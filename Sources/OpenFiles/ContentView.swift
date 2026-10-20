import SwiftUI
import OpenFilesCore

// Type-context alias keeps the property wrapper unambiguous on newer SDKs.
private typealias ViewState<Value> = SwiftUI.State<Value>

private let line = Color.primary.opacity(0.09)
private let muted = Color.secondary
private let surface = Color(nsColor: .controlBackgroundColor)

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var message = ""
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 228)
            Rectangle().fill(line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                Group {
                    switch model.section {
                    case .files: files
                    case .organize: organization
                    case .history: history
                    case .vault: VaultView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    Text(model.status).lineLimit(2)
                    Spacer()
                    Text("ON DEVICE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(.horizontal, 28).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("OpenFiles", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showingCommit, onDismiss: { message = "" }) {
            VStack(alignment: .leading, spacing: 20) {
                Label("Commit a version", systemImage: "clock.badge.checkmark").font(.title2.weight(.semibold))
                Text(model.commitTarget?.lastPathComponent ?? "").font(.headline)
                Text("Save in your editor first. OpenFiles copies the saved file or complete project folder and verifies its contents.").foregroundStyle(.secondary)
                TextField("What changed?", text: $message).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { model.showingCommit = false }.keyboardShortcut(.cancelAction); Button("Commit version") { model.commit(message: message) }.buttonStyle(.borderedProminent).tint(.primary).keyboardShortcut(.defaultAction) }.disabled(model.busy)
                if model.busy { ProgressView("Saving a verified snapshot…").controlSize(.small) }
            }.padding(28).frame(width: 480)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(surface).frame(width: 34, height: 34).background(Color.primary, in: RoundedRectangle(cornerRadius: 9))
                Text("OpenFiles").font(.system(size: 18, weight: .semibold)).tracking(-0.6)
                Spacer()
                Text("α").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 34)
            Text("WORKSPACE").font(.system(size: 10, weight: .medium)).tracking(1.1).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
            ForEach(AppModel.Section.allCases) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.icon).frame(width: 18)
                        Text(section.rawValue).fontWeight(model.section == section ? .medium : .regular)
                        Spacer()
                        if section == .files && !model.state.files.isEmpty { Text("\(model.state.files.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                    }.font(.system(size: 13)).padding(.horizontal, 11).padding(.vertical, 11)
                        .background(model.section == section ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 3).accessibilityAddTraits(model.section == section ? .isSelected : [])
            }
            HStack {
                Text("FOLDERS").font(.system(size: 10, weight: .medium)).tracking(1.1).foregroundStyle(.secondary)
                Spacer()
                Button { model.chooseFolder() } label: { Image(systemName: "plus").font(.system(size: 11)) }.buttonStyle(.plain).help("Add folder").accessibilityLabel("Add folder")
            }.padding(.horizontal, 10).padding(.top, 30).padding(.bottom, 12)
            if model.state.roots.isEmpty { Text("No folders connected").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 10) }
            ForEach(model.state.roots, id: \.self) { root in
                Label(root.lastPathComponent, systemImage: "folder").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 8).help(root.path)
                    .contextMenu { Button("Remove from library") { model.removeFolder(root) } }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("Local by design", systemImage: "lock.circle").font(.system(size: 12, weight: .medium))
                Text("Your files and embeddings\nstay on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
            HStack { Text("OpenFiles"); Spacer(); Text("v0.1.0") }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 18).padding(.horizontal, 3)
        }.padding(.horizontal, 18).padding(.top, 42).padding(.bottom, 18)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) { Text("Workspace").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.system(size: 8)); Text(model.section.rawValue) }.font(.system(size: 11)).padding(.bottom, 13)
                Text(model.section.rawValue).font(.system(size: 27, weight: .semibold)).tracking(-0.8)
                Text(model.section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.section == .files {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh index").accessibilityLabel("Refresh index")
                Button { model.chooseFolder() } label: { Label("Add folder", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.primary)
            } else if model.section == .history {
                Menu { Button("File or package…") { model.chooseCommit() }; Button("Project folder…") { model.chooseCommit(project: true) } } label: { Label("Commit version", systemImage: "plus") }
            }
        }.buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 30).padding(.top, 36).padding(.bottom, 25).disabled(model.busy)
    }
    private var files: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                MetricCard(title: "Indexed files", value: "\(model.state.files.count)", symbol: "doc.on.doc", detail: "Across \(model.state.roots.count) connected folders")
                MetricCard(title: "Saved versions", value: "\(model.state.versions.count)", symbol: "clock.arrow.circlepath", detail: "Verified copies, ready to restore")
                MetricCard(title: "Search engine", value: model.embeddingsAvailable ? "Semantic" : "Local", symbol: "sparkle.magnifyingglass", detail: model.embeddingsAvailable ? "On-device English embeddings" : (model.state.roots.isEmpty ? "Add a folder to start indexing" : "Filename search · model unavailable"))
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or describe what’s inside…", text: $model.query).textFieldStyle(.plain).font(.system(size: 13)).accessibilityLabel("Search files")
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                Text("LOCAL SEARCH").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(.tertiary)
            }.padding(13).background(surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(line))
            if model.state.files.isEmpty { welcome }
            else if model.results.isEmpty { EmptyPanel(symbol: "magnifyingglass", title: "No files found", detail: "Try a filename, a topic, or a different description.") }
            else { fileTable }
            Spacer(minLength: 0)
        }.padding(30)
    }
    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.secondary).frame(height: 66)
            Text("Everything, within reach.").font(.system(size: 23, weight: .medium)).tracking(-0.7)
            Text("Connect a folder and find files by what you remember.\nA thought, a phrase, or just the filename.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 12) {
                Button("Connect your first folder") { model.chooseFolder() }.buttonStyle(.borderedProminent).tint(.primary)
                Button("Explore sample files") { model.addSamples() }.buttonStyle(.bordered)
            }.controlSize(.large).padding(.top, 4).disabled(model.busy)
            HStack(spacing: 22) { Label("No cloud uploads", systemImage: "checkmark"); Label("You choose what to index", systemImage: "checkmark") }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25).background(surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
    }
    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack { Text("Name"); Spacer(); Text("Kind").frame(width: 95, alignment: .leading); Text("Modified").frame(width: 95, alignment: .leading); Color.clear.frame(width: 66, height: 1) }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { file in
                        HStack(spacing: 11) {
                            Image(systemName: symbol(file)).font(.system(size: 18, weight: .light)).foregroundStyle(.secondary).frame(width: 31, height: 34).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) { Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(file.url.deletingLastPathComponent().lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            if file.sensitive { Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange).help("Potentially sensitive. Excluded from embeddings and organization; this file is not encrypted.") }
                            Spacer(minLength: 6)
                            Text(file.category).frame(width: 95, alignment: .leading)
                            Text(file.modified, style: .date).frame(width: 95, alignment: .leading)
                            Menu { Button("Open") { model.open(file) }; Button("Show in Finder") { model.open(file, reveal: true) }; Divider(); Button("Commit version…") { model.prepareCommit(file) }.disabled(file.sensitive) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                            Button { model.open(file) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("Open \(file.name)").accessibilityLabel("Open \(file.name)")
                        }.font(.system(size: 11)).foregroundStyle(.primary).padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle()).onTapGesture(count: 2) { model.open(file) }
                        Divider().opacity(0.35)
                    }
                }
            }
            HStack { Text("\(model.results.count) files"); Spacer(); Text("Double-click to open · Menu for versions") }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
        }.background(surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)).disabled(model.busy)
    }
    private func symbol(_ f: FileRecord) -> String { switch f.category { case "Images": "photo"; case "Video": "film"; case "Audio": "waveform"; case "Project": "shippingbox"; case "Archives": "archivebox"; default: "doc.text" } }
    private var organization: some View {
        VStack(alignment: .leading, spacing: 24) {
            InfoCard(symbol: "tray.2", title: "A calmer Downloads folder", text: "Sort top-level files into Organized / Documents, Images, Audio, Video, and Archives. Projects and potentially sensitive files stay in place. Existing files are never overwritten.")
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text("Automatic organization").font(.system(size: 13, weight: .medium)); Text("Every 60 seconds while OpenFiles runs. Applies to all connected folders.").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Toggle("Automatic organization", isOn: Binding(get: { model.state.autoOrganize }, set: { model.setAutomatic($0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Automatic organization")
            }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
            HStack { Text("Proposed moves").font(.headline); Spacer(); Button("Preview organization") { model.preview() }; Button("Apply \(model.proposals.count) moves") { model.applyMoves() }.buttonStyle(.borderedProminent).tint(.primary).disabled(model.proposals.isEmpty) }.buttonStyle(.bordered)
            if model.proposals.isEmpty { EmptyPanel(symbol: "checklist", title: "Review before you rearrange", detail: "Preview the exact destination for each file. Only files unchanged for at least 10 seconds are eligible.") }
            else { List(model.proposals) { move in VStack(alignment: .leading, spacing: 5) { Text(move.source.lastPathComponent).font(.system(size: 12, weight: .medium)); Label(move.destination.path, systemImage: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }.padding(.vertical, 6) }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 9)) }
            Spacer(minLength: 0)
        }.padding(30).disabled(model.busy)
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 22) {
            InfoCard(symbol: "clock.arrow.circlepath", title: "A save point for any saved format", text: "Commit a file or complete project folder from OpenFiles or its menu bar icon. Binary files are stored as full snapshots. Restore exports a new copy; your current work stays in place.")
            if model.state.versions.isEmpty {
                EmptyPanel(symbol: "clock.badge.checkmark", title: "Your first save point starts here", detail: "Save in your editor, then choose Commit version. Files and project folders are supported, including opaque app formats.")
                HStack { Button("Commit file…") { model.chooseCommit() }; Button("Commit project folder…") { model.chooseCommit(project: true) } }.buttonStyle(.bordered)
            } else {
                List(model.state.versions) { version in
                    HStack(spacing: 16) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) { Text(version.message).font(.system(size: 13, weight: .medium)); Text(version.name).font(.system(size: 11)).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) { Text(version.created, style: .date); Text(String(version.id.uuidString.prefix(8))).font(.system(size: 10, design: .monospaced)) }.font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Restore copy…") { model.export(version) }.buttonStyle(.bordered)
                    }.padding(.vertical, 12)
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            Text("Save all linked assets with the project. Automatic active-document detection and app-specific save hooks are planned.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(30).disabled(model.busy)
    }
}

private struct MetricCard: View {
    var title: String; var value: String; var symbol: String; var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary) }
            Text(value).font(.system(size: 25, weight: .semibold)).tracking(-0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
    }
}
private struct InfoCard: View {
    var symbol: String; var title: String; var text: String
    var body: some View { HStack(alignment: .top, spacing: 14) { Image(systemName: symbol).font(.system(size: 22, weight: .light)).frame(width: 30); VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 15, weight: .medium)); Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true) } }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)) }
}
private struct EmptyPanel: View {
    var symbol: String; var title: String; var detail: String
    var body: some View { VStack(spacing: 14) { Image(systemName: symbol).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary); Text(title).font(.system(size: 17, weight: .medium)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 430) }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity).background(surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)) }
}

private struct VaultView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            InfoCard(symbol: "lock.shield", title: "Private means encrypted", text: "Your vault is an AES-256 encrypted APFS disk image with a 10 GB capacity that grows as needed. Its contents stay out of search and version history. Keep your password safe: there’s no reset.")
            VStack(spacing: 20) {
                Image(systemName: model.vaultState.mounted ? "lock.open" : "lock").font(.system(size: 38, weight: .ultraLight)).padding(.top, 12)
                Text(model.vaultState.mounted ? "Your vault is unlocked" : model.vaultState.exists ? "Unlock your private vault" : "Create your private vault").font(.system(size: 21, weight: .medium)).tracking(-0.5)
                if model.vaultState.mounted {
                    Text("Files are accessible to this Mac while the vault is unlocked.").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack { Button("Open in Finder") { model.openVault() }; Button("Copy a file into vault…") { model.importVault() }; Button("Lock vault") { model.lockVault() }.buttonStyle(.borderedProminent).tint(.primary) }.buttonStyle(.bordered).controlSize(.large)
                } else {
                    SecureField(model.vaultState.exists ? "Vault password" : "Password (at least 12 characters)", text: $password).textContentType(.password).textFieldStyle(.roundedBorder).frame(width: 320)
                    if !model.vaultState.exists { SecureField("Confirm password", text: $confirmation).textFieldStyle(.roundedBorder).frame(width: 320) }
                    Button(model.vaultState.exists ? "Unlock vault" : "Create encrypted vault") {
                        model.vaultAction(password: password); password = ""; confirmation = ""
                    }.buttonStyle(.borderedProminent).tint(.primary).controlSize(.large).disabled(password.isEmpty || (!model.vaultState.exists && (password.count < 12 || password != confirmation)))
                }
                if model.busy { ProgressView("Working with encrypted storage…").controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30).background(surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
            Label("Import creates an encrypted copy. Originals remain outside the vault until you remove them. Detection is a heuristic; it cannot identify every sensitive file.", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(30).disabled(model.busy)
    }
}
