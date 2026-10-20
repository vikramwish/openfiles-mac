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
                    if model.busy || model.indexing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    Text(model.status).lineLimit(2)
                    Spacer()
                    Text(model.indexing ? "SEMANTIC INDEXING" : "ON DEVICE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(.horizontal, 28).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("OpenFiles", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showingGo) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Go to folder").font(.title2.weight(.semibold))
                TextField("/Users/you/Documents", text: $model.pathInput).textFieldStyle(.roundedBorder).onSubmit { model.goToPath() }
                HStack { Spacer(); Button("Cancel") { model.showingGo = false }.keyboardShortcut(.cancelAction); Button("Go") { model.goToPath() }.keyboardShortcut(.defaultAction) }
            }.padding(26).frame(width: 480)
        }
        .sheet(isPresented: $model.showingNewFolder) {
            VStack(alignment: .leading, spacing: 18) {
                Text("New folder").font(.title2.weight(.semibold))
                TextField("Folder name", text: $model.newFolderName).textFieldStyle(.roundedBorder).onSubmit { model.createFolder() }
                HStack { Spacer(); Button("Cancel") { model.showingNewFolder = false }.keyboardShortcut(.cancelAction); Button("Create") { model.createFolder() }.keyboardShortcut(.defaultAction).disabled(model.newFolderName.isEmpty) }
            }.padding(26).frame(width: 420)
        }
        .sheet(item: $model.previewItem) { item in
            VStack(spacing: 0) {
                HStack { Text(item.name).font(.headline); Spacer(); Button("Open") { model.open(item) }; Button("Done") { model.previewItem = nil }.keyboardShortcut(.cancelAction) }.padding(18)
                Divider()
                FilePreview(url: item.url).frame(minWidth: 640, minHeight: 460)
            }
        }
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
            }.padding(.bottom, 28)
            Text("FAVORITES").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.locations, id: \.url) { location in
                        locationButton(location.name, icon: location.icon, url: location.url)
                    }
                    if !model.volumes.isEmpty {
                        Text("LOCATIONS").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
                        ForEach(model.volumes, id: \.self) { url in locationButton(url.lastPathComponent, icon: "externaldrive", url: url) }
                    }
                    let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
                    if FileManager.default.fileExists(atPath: cloud.path) { locationButton("iCloud Drive", icon: "icloud", url: cloud) }
                }
            }
            Divider().padding(.vertical, 15)
            ForEach(AppModel.Section.allCases.filter { $0 != .files }) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 11) { Image(systemName: section.icon).frame(width: 18); Text(section.rawValue); Spacer() }
                        .font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 10)
                        .background(model.section == section ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Label("On this Mac. By default.", systemImage: "lock.circle").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 20)
        }.padding(.horizontal, 16).padding(.top, 42).padding(.bottom, 18).background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
    private func locationButton(_ title: String, icon: String, url: URL) -> some View {
        Button { model.navigate(to: url) } label: {
            HStack(spacing: 11) { Image(systemName: icon).frame(width: 18); Text(title).lineLimit(1); Spacer() }.font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 9)
                .background(model.section == .files && model.currentFolder.standardizedFileURL.path == url.standardizedFileURL.path ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(url.path)
    }
    @ViewBuilder
    private var header: some View {
        if model.section == .files { BrowserToolbar() }
        else {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.section.rawValue).font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                    Text(model.section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.section == .history {
                    Menu { Button("File or package…") { model.chooseCommit() }; Button("Project folder…") { model.chooseCommit(project: true) } } label: { Label("Commit version", systemImage: "plus") }
                }
            }.padding(.horizontal, 30).padding(.top, 38).padding(.bottom, 25)
        }
    }
    private var files: some View { BrowserView() }
    private var organization: some View {
        VStack(alignment: .leading, spacing: 24) {
            InfoCard(symbol: "tray.2", title: "A calmer Downloads folder", text: "Sort top-level files into Organized / Documents, Images, Audio, Video, and Archives. Projects and potentially sensitive files stay in place. Existing files are never overwritten.")
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text("Automatic organization").font(.system(size: 13, weight: .medium)); Text("Every 60 seconds while OpenFiles runs. Applies only to folders listed below.").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Toggle("Automatic organization", isOn: Binding(get: { model.state.autoOrganize }, set: { model.setAutomatic($0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Automatic organization")
            }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Folders to organize").font(.headline)
                    Text("Browsing and search work everywhere. Only these folders can be rearranged automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(model.state.roots, id: \.self) { root in
                        HStack { Text(root.path).font(.system(size: 11)); Button("Remove") { model.removeFolder(root) }.buttonStyle(.borderless) }
                    }
                }
                Spacer()
                Button("Choose folder to organize…") { model.chooseOrganizationFolder() }.buttonStyle(.bordered)
            }
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
                    HStack { Button("Browse vault") { model.openVault() }; Button("Copy a file into vault…") { model.importVault() }; Button("Lock vault") { model.lockVault() }.buttonStyle(.borderedProminent).tint(.primary) }.buttonStyle(.bordered).controlSize(.large)
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
