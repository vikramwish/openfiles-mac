import SwiftUI
import OpenFilesCore
import OpenFilesAgent

private typealias AgentViewState<Value> = SwiftUI.State<Value>

/// Reviewed agent actions: the model only proposes; every action needs the user's approval,
/// and all filesystem changes run through the app's existing verified flows.
struct AgentPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AgentViewState private var instruction = ""

    private var renames: [AgentAction] { model.agentPlan?.actions.filter { $0.kind == .rename } ?? [] }
    private var moves: [AgentAction] { model.agentPlan?.actions.filter { $0.kind == .move } ?? [] }
    private var navigations: [AgentAction] { model.agentPlan?.actions.filter { $0.kind == .navigate } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hermes agent").font(.title2.weight(.semibold))
            Text("Describe what you want done with the files you see. The agent proposes renames, moves and folders to open. You approve every action; nothing changes without your review.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Model service", systemImage: "sparkles").font(.headline)
                        Spacer()
                        if model.agentBusy { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        Picker("Service", selection: $model.agentEndpointBase) {
                            Text("OpenRouter").tag("https://openrouter.ai/api/v1")
                            Text("Hermes proxy").tag("http://127.0.0.1:8645/v1")
                            Text("LM Studio").tag("http://127.0.0.1:1234/v1")
                        }.pickerStyle(.segmented).frame(width: 260)
                        TextField("Endpoint base URL", text: $model.agentEndpointBase).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        TextField("Model", text: $model.agentModel).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Button("Load models") { Task { await model.testAgentConnection() } }
                        if !model.agentModelOptions.isEmpty {
                            Picker("Available models", selection: $model.agentModel) {
                                ForEach(model.agentModelOptions, id: \.self) { Text($0).tag($0) }
                            }.frame(maxWidth: 240)
                        }
                    }
                    HStack {
                        Text(model.agentHasKey ? "API key saved in Keychain" : "No API key saved")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Import key from Hermes…") { model.importAgentKeyFromHermes() }.disabled(model.agentHasKey)
                        Button("Remove key") { model.clearAgentKey() }.disabled(!model.agentHasKey)
                    }.buttonStyle(.borderless)
                    Toggle("Send short text excerpts so renames can reflect file content", isOn: $model.agentIncludeExcerpts)
                    DisclosureGroup("What is sent to the model service") {
                        Text("File names, folder paths, sizes and your request. With excerpts enabled, the first 400 characters of small text files are included. Potentially sensitive files and excerpts are excluded before anything is sent. Nothing is applied automatically; every action waits for your approval, and each change is re-verified against the file it came from.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                    if let connection = model.agentConnection { Text(connection).font(.caption).foregroundStyle(.secondary) }
                }.padding(8).font(.callout)
            }

            Text("Browsing \(model.currentFolder.path) · \(model.browserItems.count) visible items")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(model.currentFolder.path)

            HStack {
                TextField("e.g. Rename these files based on what they contain", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .onSubmit { Task { await model.requestAgentPlan(instruction) } }
                Button("Get suggestions") { Task { await model.requestAgentPlan(instruction) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.agentBusy)
            }

            if let error = model.agentError { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            if let plan = model.agentPlan {
                if plan.actions.isEmpty {
                    Text("The agent proposed no actions. Try naming the files or folders in your request.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    List {
                        if !renames.isEmpty {
                            Section("Renames") { ForEach(renames) { action in row(action) } }
                        }
                        if !moves.isEmpty {
                            Section("Moves") { ForEach(moves) { action in row(action) } }
                        }
                        if !navigations.isEmpty {
                            Section("Open folders") { ForEach(navigations) { action in row(action) } }
                        }
                        if !plan.ignored.isEmpty {
                            Section("Ignored by OpenFiles") {
                                Text(plan.ignored.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.listStyle(.inset)
                    HStack {
                        Button(model.agentSelection.count == plan.actions.count ? "Deselect all" : "Select all") {
                            model.agentSelection = model.agentSelection.count == plan.actions.count ? [] : Set(plan.actions.map(\.id))
                        }.disabled(model.agentBusy)
                        Spacer()
                        Button("Apply \(model.agentSelection.count) approved action\(model.agentSelection.count == 1 ? "" : "s")") {
                            Task { await model.applyAgentPlan() }
                        }.buttonStyle(.borderedProminent).disabled(model.agentSelection.isEmpty || model.agentBusy)
                    }
                }
            }

            if !model.agentOutcomes.isEmpty {
                Divider()
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.agentOutcomes.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(4)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 660, height: 680)
    }

    @ViewBuilder
    private func row(_ action: AgentAction) -> some View {
        Toggle(isOn: Binding(
            get: { model.agentSelection.contains(action.id) },
            set: { if $0 { model.agentSelection.insert(action.id) } else { model.agentSelection.remove(action.id) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                switch action.kind {
                case .rename:
                    if let source = action.source, let name = action.name {
                        Text("\(source.lastPathComponent) → \(name)").font(.body.weight(.medium))
                        Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(source.path)
                    }
                case .move:
                    if let source = action.source, let destination = action.destination {
                        Label("\(source.lastPathComponent) into \(destination.path)", systemImage: "arrow.turn.down.right")
                            .lineLimit(1).truncationMode(.middle).help(destination.path)
                        Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(source.path)
                    }
                case .navigate:
                    if let folder = action.folder {
                        Label(folder.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(folder.path)
                    }
                }
                if !action.reason.isEmpty {
                    Text(action.reason).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 2)
        }.toggleStyle(.checkbox).disabled(model.agentBusy)
    }
}
