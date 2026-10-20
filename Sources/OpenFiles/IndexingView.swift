import SwiftUI
import OpenFilesCore

struct IndexingView: View {
    @EnvironmentObject private var model: AppModel
    private var progress: IndexProgress { model.indexProgress }
    private var activityTitle: String {
        if model.indexSettings.paused || progress.phase == .paused { return "Paused" }
        switch progress.phase {
        case .paused: return "Paused"
        case .failed: return "Needs attention"
        case .cancelled: return "Stopped"
        case .discovering: return "Finding files…"
        case .indexing: return "Reading file contents…"
        case .idle, .completed: return model.indexing ? "Starting…" : "Ready"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your folders").font(.title2.weight(.semibold))
                    Text("OpenFiles keeps search up to date in the background. Choose what it can work with.").font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { model.showingIndexing = false }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    activity
                    scopes
                    exclusions
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        metric("New embeddings", value: "\(progress.embedded)", detail: "\(progress.tokenized) new tokenization passes")
                        metric("Reused", value: "\(progress.reused)", detail: "\(progress.statHits) unchanged · \(progress.objectHits) by content")
                        metric("Content reads", value: "\(progress.extracted)", detail: ByteCountFormatter.string(fromByteCount: progress.bytesRead, countStyle: .file) + " processed¹")
                        metric("Active time", value: String(format: "%.2fs", progress.activeSeconds), detail: String(format: "%.1f files/sec", progress.filesPerSecond))
                    }
                    HStack(alignment: .top, spacing: 20) { configuration; engine }
                    searchModel
                    exclusions
                    HStack(alignment: .top, spacing: 20) { scopes; skips }
                    events
                        }.padding(.top, 16)
                    }

                }.padding(24)
            }
        }.frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(activityTitle, systemImage: model.indexSettings.paused ? "pause.circle" : "waveform.path").font(.headline)
                Spacer()
                if model.indexing { Button("Stop after current files") { model.stopIndexing() } }
                Button(model.indexSettings.paused ? "Resume updates" : "Pause updates") { model.setIndexPaused(!model.indexSettings.paused) }
                if !model.indexing { Button("Check for changes") { model.startIndexing() }.disabled(model.indexSettings.paused) }
            }.buttonStyle(.bordered).controlSize(.small)
            if progress.fraction == nil && model.indexing { ProgressView().progressViewStyle(.linear) }
            else if let fraction = progress.fraction { ProgressView(value: fraction) }
            HStack {
                Text("\(progress.processed) of \(progress.discovered) files checked").font(.body.weight(.medium))
                Spacer()
                Text("Progress saved automatically").font(.callout).foregroundStyle(.secondary)
            }
            Text("\(model.library.searchCatalog.count) files available in search now").font(.callout).foregroundStyle(.secondary)
            if let path = progress.activePaths?.first, model.indexing {
                Label(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"), systemImage: "doc.text.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path)
            }
            if progress.phase == .failed || progress.phase == .cancelled || progress.phase == .paused {
                Text(progress.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(model.indexing ? "Completed batches are searchable immediately. Each batch prioritizes personal documents; the first scan can take several minutes." : "OpenFiles checks for changes while it’s running.").font(.callout).foregroundStyle(.secondary)
            }
            if progress.limitReached { Label("More files may be available. Adjust the file limit in Technical details to include them.", systemImage: "info.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }

        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
    private func metric(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 23, weight: .medium)).monospacedDigit(); Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }.padding(13).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Work budget").font(.headline)
            Picker("Semantic file limit", selection: Binding(get: { model.indexSettings.maxFiles }, set: { value in var settings = model.indexSettings; settings.maxFiles = value; model.updateIndexSettings(settings) })) { Text("2,000 files").tag(2000); Text("10,000 files").tag(10000); Text("No limit").tag(0) }
            Picker("Parallel workers", selection: Binding(get: { model.indexSettings.workers }, set: { value in var settings = model.indexSettings; settings.workers = value; model.updateIndexSettings(settings) })) { Text("1 · Low impact").tag(1); Text("2 · Balanced").tag(2); Text("4 · Faster / more CPU").tag(4) }
            Text("Settings apply to the next pass. Low Power Mode limits work to one worker. Pause finishes in-flight files; completed work is checkpointed.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .topLeading).disabled(model.indexing)
    }
    private var engine: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine & timing").font(.headline)
            Text(progress.modelAvailable ? "Vectors available" : progress.skipReasons["Model unavailable"] != nil ? "Model unavailable · filename search still works" : "Model is loaded only when needed").font(.caption).foregroundStyle(.secondary)
            Text(progress.engine).font(.callout)
            Text(progress.engineID.isEmpty ? "Model loads lazily when needed" : progress.engineID).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text("\(progress.workers) workers · CPU vector search via Accelerate").font(.caption)
            Text(String(format: "Extraction %.3fs · Word counting %.3fs · Inference %.3fs", progress.extractionSeconds, progress.tokenizationSeconds, progress.embeddingSeconds)).font(.caption).foregroundStyle(.secondary)
            Text("\(progress.wordUnits) word units newly counted using macOS word segmentation, separate from the search model’s tokens. Timings sum across workers, so may exceed wall time.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            Text("¹ Text reports bytes read; PDFs report source bytes processed, not physical disk I/O. Extracted document text is never saved to the index.").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var searchModel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Search model").font(.headline)
            Text(model.usesEmbeddingGemma ? "EmbeddingGemma 2 · on this Mac" : "Apple NaturalLanguage · English").font(.system(size: 11))
            if model.loadingEmbeddingModel {
                HStack { ProgressView().controlSize(.small); Text("Checking and loading the model…").font(.system(size: 11)) }
            }
            HStack {
                Button("Use EmbeddingGemma 2…") { model.chooseEmbeddingGemma() }.disabled(!model.supportsEmbeddingGemma)
                if model.usesEmbeddingGemma || model.embeddingModelNotice != nil {
                    Button("Use Apple model") { model.useAppleEmbeddings() }
                }
            }.disabled(model.indexing || model.busy || model.loadingEmbeddingModel)
            if !model.supportsEmbeddingGemma {
                Text("EmbeddingGemma is available in the optional Apple Silicon build.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Choose a downloaded model folder. Documents and queries stay on this Mac. Stop indexing before changing models; unchanged files are re-embedded when the model changes.").font(.system(size: 10)).foregroundStyle(.secondary)
            if let notice = model.embeddingModelNotice { Text(notice).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("Folders to leave out").font(.headline); Spacer(); Button("Exclude folder…") { model.addIndexExclusion() }.disabled(model.indexing) }
            Text("OpenFiles won’t analyze the contents of these folders. You can still browse them and find them through macOS search. System files, app data, and vault contents are left out automatically.").font(.caption).foregroundStyle(.secondary)
            if model.indexSettings.excludedFolders.isEmpty { Text("No additional exclusions").font(.callout).foregroundStyle(.secondary) }
            ForEach(model.indexSettings.excludedFolders, id: \.self) { folder in
                HStack { Text(folder.path).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button("Remove") { var settings = model.indexSettings; settings.excludedFolders.removeAll { $0 == folder }; model.updateIndexSettings(settings) }.disabled(model.indexing) }
            }
        }
    }
    private var scopes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Folders OpenFiles can see").font(.headline)
            ForEach(Array(Set(model.indexScopes)).sorted { $0.path < $1.path }, id: \.self) { url in Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Button("Add a folder…") { model.chooseOrganizationFolder() }
            Text("Some protected folders need permission from macOS. Large files and unsupported formats may only be searchable by name.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var skips: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Skipped / restricted items").font(.headline)
            if progress.skipReasons.isEmpty { Text("None reported in this pass").font(.caption).foregroundStyle(.secondary) }
            ForEach(progress.skipReasons.keys.sorted(), id: \.self) { reason in HStack { Text(reason); Spacer(); Text("\(progress.skipReasons[reason] ?? 0)").monospacedDigit() }.font(.caption).foregroundStyle(.secondary) }
            Text("Counts include directory exclusions. Sensitive detection is a heuristic, not encryption.").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var events: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recent activity · last 100 items this session").font(.headline)
            if progress.events.isEmpty { Text("Start a pass to see each file’s cache decision or exclusion reason.").font(.callout).foregroundStyle(.secondary) }
            ForEach(progress.events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Text(event.outcome).font(.system(size: 10, weight: .medium)).frame(width: 98, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(event.path)
                        Text(event.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                Divider().opacity(0.35)
            }
            Text("On disk: library.json stores paths, stat signatures, and summary counters; IndexObjects stores hashed embedding objects. Both are local and unencrypted. Activity paths above are session-only.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
}
