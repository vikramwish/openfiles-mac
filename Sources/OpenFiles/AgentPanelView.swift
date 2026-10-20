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
    @AgentViewState private var showSettings = false

    private var renames: [AgentAction] { model.agentPlan?.actions.filter { $0.kind == .rename } ?? [] }
    private var moves: [AgentAction] { model.agentPlan?.actions.filter { $0.kind == .move } ?? [] }
    private var navigations: [AgentAction] { model.agentPlan?.actions.filter { $0.kind == .navigate } ?? [] }

    private var serviceName: String {
        if model.agentEndpointBase.contains("openrouter") { return "OpenRouter" }
        if model.agentEndpointBase.contains("127.0.0.1:8645") { return "Hermes proxy" }
        if model.agentEndpointBase.contains("127.0.0.1:1234") { return "LM Studio" }
        return model.agentEndpointBase
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showSettings { settings } else { summary }
                    context
                    request
                    if let error = model.agentError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    plan
                    outcomes
                }.padding(20)
            }
        }.frame(width: 680, height: 700)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hermes").font(.system(size: 15, weight: .semibold))
                Text("proposes · you approve every change").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: showSettings ? "xmark.circle.fill" : "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }.buttonStyle(.borderless).help(showSettings ? "Hide settings" : "Model service, key and privacy settings")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Compact service summary

    private var summary: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.agentHasKey ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(model.agentHasKey ? Color.green : Color.orange)
                Text("\(serviceName) · \(model.agentModel)").lineLimit(1).truncationMode(.middle)
                Text(model.agentHasKey ? "key in Keychain" : "no key")
                    .foregroundStyle(model.agentHasKey ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                Text("·").foregroundStyle(.secondary)
                Text(model.agentIncludeExcerpts ? "content previews on" : "previews off").foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }.font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var context: some View {
        Text("Browsing \(model.currentFolder.path) · \(model.browserItems.count) visible items")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .help(model.currentFolder.path)
    }

    // MARK: Request

    private var request: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("e.g. Rename these screenshots based on what they show", text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
                .onSubmit { ask() }
            Button {
                ask()
            } label: {
                if model.agentBusy { ProgressView().controlSize(.small) }
                else { Label("Ask", systemImage: "arrow.up.circle.fill") }
            }.buttonStyle(.borderedProminent)
            .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.agentBusy)
        }
    }

    private func ask() {
        Task { await model.requestAgentPlan(instruction) }
    }

    // MARK: Settings

    private var settings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Model service", systemImage: "sparkles").font(.headline)
                    Spacer()
                    Button("Hide") { showSettings = false }.buttonStyle(.borderless)
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
                Toggle("Send content previews: text excerpts and downscaled images", isOn: $model.agentIncludeExcerpts)
                DisclosureGroup("What is sent to the model service") {
                    Text("File names, folder paths, sizes and your request. With previews enabled, the first 400 characters of small text files are included, and up to four image files are attached as downscaled JPEG previews (~1024 px) so screenshots can be renamed from what they show. Potentially sensitive files and excerpts are excluded before anything is sent. Nothing is applied automatically; every action waits for your approval, and each change is re-verified against the file it came from.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                if let connection = model.agentConnection { Text(connection).font(.caption).foregroundStyle(.secondary) }
            }.padding(8).font(.callout)
        }
    }

    // MARK: Proposed plan

    @ViewBuilder
    private var plan: some View {
        if let plan = model.agentPlan {
            if plan.actions.isEmpty {
                Text("The agent proposed no actions. Try naming the files or folders in your request.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !renames.isEmpty { section("Renames", systemImage: "pencil.and.list.clipboard", renames) }
                    if !moves.isEmpty { section("Moves", systemImage: "arrow.turn.down.right", moves) }
                    if !navigations.isEmpty { section("Open folders", systemImage: "folder", navigations) }
                }
                if !plan.ignored.isEmpty {
                    DisclosureGroup("Ignored by OpenFiles") {
                        Text(plan.ignored.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    }.font(.caption)
                }
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
    }

    private func section(_ title: String, systemImage: String, _ actions: [AgentAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(actions.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quinary, in: Capsule())
            }.padding(.bottom, 4)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                row(action)
                if index < actions.count - 1 { Divider() }
            }
        }.padding(.bottom, 12)
    }

    @ViewBuilder
    private func row(_ action: AgentAction) -> some View {
        let unavailable = model.agentAvailability(action)
        Toggle(isOn: Binding(
            get: { model.agentSelection.contains(action.id) },
            set: { if $0 { model.agentSelection.insert(action.id) } else { model.agentSelection.remove(action.id) } }
        )) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(action.kind))
                    .foregroundStyle(unavailable == nil ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    switch action.kind {
                    case .rename:
                        if let source = action.source, let name = action.name {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                                Label(name, systemImage: "arrow.right").font(.body.weight(.medium))
                            }
                        }
                    case .move:
                        if let source = action.source, let destination = action.destination {
                            Text("\(source.lastPathComponent) → \(destination.path)").font(.body.weight(.medium))
                                .lineLimit(1).truncationMode(.middle).help(destination.path)
                        }
                    case .navigate:
                        if let folder = action.folder {
                            Text(folder.path).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle).help(folder.path)
                        }
                    }
                    if !action.reason.isEmpty {
                        Text(action.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let unavailable {
                        Label(unavailable, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 4)
        }.toggleStyle(.checkbox).disabled(model.agentBusy || unavailable != nil)
    }

    private func icon(_ kind: AgentAction.Kind) -> String {
        switch kind {
        case .rename: return "pencil.line"
        case .move: return "arrow.turn.down.right"
        case .navigate: return "folder"
        }
    }

    // MARK: Outcomes

    @ViewBuilder
    private var outcomes: some View {
        if !model.agentOutcomes.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.agentOutcomes.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: line.hasPrefix("Rename") || line.hasPrefix("Renamed") || line.hasPrefix("Moved") || line.hasPrefix("Opened")
                          ? "checkmark.circle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(line.contains("failed") || line.contains("refused") ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
