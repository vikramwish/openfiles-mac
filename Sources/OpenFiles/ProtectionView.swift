import SwiftUI
import AppKit
import OpenFilesCore

/// Shared by all workspace windows. The task only lives while the application is open.
@MainActor
final class ProtectionModel: ObservableObject {
    @Published private(set) var state = AutomaticHistoryState()
    @Published private(set) var checking = false
    @Published var error: String?
    var onLibraryChange: ((LibraryState) -> Void)?
    private let history: AutomaticHistory
    private let library: FileLibrary
    private var poll: Task<Void, Never>?
    private var started = false

    init(library: FileLibrary, directory: URL) {
        self.library = library
        history = AutomaticHistory(library: library, directory: directory)
    }
    /// Reads configuration without checking files or starting a timer.
    func load() async {
        do { state = try await history.load(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func stop() async {
        poll?.cancel(); poll = nil; started = false
        while checking { try? await Task.sleep(for: .milliseconds(25)) }
    }
    func start() async {
        guard !started else { return }
        started = true
        do { state = try await history.load() }
        catch { self.error = error.localizedDescription; started = false; return }
        await checkNow()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.checkNow()
            }
        }
    }
    func checkNow() async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        do {
            state = try await history.checkNow()
            onLibraryChange?(await library.current())
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func chooseLocations() {
        let picker = NSOpenPanel()
        picker.title = "Choose files or small folders to protect"
        picker.message = "OpenFiles keeps local copies of saved changes while it is open. Folders are saved as complete snapshots, up to 100 MB each."
        picker.prompt = "Protect selected"
        picker.canChooseFiles = true; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        let urls = picker.urls
        Task {
            do { state = try await history.add(urls); error = nil; await checkNow() }
            catch { self.error = error.localizedDescription }
        }
    }
    func setEnabled(_ enabled: Bool, locationID: UUID? = nil) {
        Task {
            do {
                state = try await history.setEnabled(enabled, locationID: locationID)
                error = nil
                if enabled { await checkNow() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func remove(_ id: UUID) {
        Task {
            do { state = try await history.remove(id); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ProtectionView: View {
    @ObservedObject var model: ProtectionModel
    var openHistory: ((URL) -> Void)?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "clock.badge.checkmark").font(.system(size: 34)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep your saved work").font(.title2.weight(.semibold))
                        Text("Choose important files or small folders. OpenFiles remembers changes so you can return to an earlier version.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Automatic version protection", isOn: Binding(get: { model.state.enabled }, set: { model.setEnabled($0) }))
                            .toggleStyle(.switch).font(.headline)
                        Text("Checks every 30 seconds while OpenFiles is open. Only saved changes can be captured; rapid saves between checks may not appear separately.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button { model.chooseLocations() } label: { Label("Choose files or folders…", systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                            Button("Check now") { Task { await model.checkNow() } }
                                .disabled(model.checking || !model.state.enabled || model.state.locations.isEmpty)
                            if model.checking { ProgressView().controlSize(.small).accessibilityLabel("Checking protected locations") }
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if model.state.locations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.clock").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Start with a document that matters").font(.headline)
                        Text("A draft, presentation, or small project is a good place to start. Nothing is protected until you choose it.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 410)
                    }.padding(.vertical, 28).frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Protected locations").font(.headline)
                            Spacer()
                            Text("\(model.state.locations.count) of 20").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.state.locations) { location in locationRow(location) }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Stored on this Mac", systemImage: "internaldrive").font(.subheadline.weight(.semibold))
                    Text("\(model.state.savedCount) automatic versions · \(ByteCountFormatter.string(fromByteCount: model.state.storedBytes, countStyle: .file)) used")
                        .font(.callout)
                    Text("Keeps up to 20 automatic versions per location within a shared 1 GB allowance. Older automatic versions may be removed after a new one is safely saved. Manually saved versions are kept.")
                    Text("Folders are saved whole, with a 100 MB and 2,000-item limit. Hidden files, generated folders, symbolic links, indexing exclusions, and potentially sensitive content can prevent a snapshot. A skipped location shows its reason above.")
                    Text("This is local version history, not an independent backup. It cannot recover unsaved edits or protect against losing this Mac. Sensitive detection is only a hint; history is not encrypted storage.")
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
    }
    private func locationRow(_ location: ProtectedLocation) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: location.url.path)).resizable().frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.url.lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(location.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(location.url.path)
                    }
                    Spacer(minLength: 8)
                    Toggle("Protect \(location.url.lastPathComponent)", isOn: Binding(get: { location.enabled }, set: { model.setEnabled($0, locationID: location.id) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!model.state.enabled)
                }
                if !model.state.enabled || !location.enabled {
                    Label("Protection paused", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                } else if let issue = location.issue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let saved = location.lastSaved {
                    Label("Saved \(saved.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Waiting for its first snapshot", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let openHistory { Button("View versions") { openHistory(location.url) }.disabled(location.lastSaved == nil) }
                    Spacer()
                    Button("Stop protecting") { model.remove(location.id) }.buttonStyle(.borderless).font(.caption)
                        .help("Stops future checks. Existing saved versions remain available.")
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
