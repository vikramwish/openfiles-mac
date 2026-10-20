import SwiftUI
import OpenFilesCore

struct IndexingView: View {
    @EnvironmentObject private var model: AppModel
    private var progress: IndexProgress { model.indexProgress }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Indexing activity").font(.system(size: 24, weight: .semibold)).tracking(-0.6)
                    Text("See what’s processed, reused, and left out. Your files stay on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { model.showingIndexing = false }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    activity
                    HStack(spacing: 12) {
                        metric("New embeddings", value: "\(progress.embedded)", detail: "\(progress.tokenized) new tokenization passes")
                        metric("Reused", value: "\(progress.reused)", detail: "\(progress.statHits) unchanged · \(progress.objectHits) by content")
                        metric("Content reads", value: "\(progress.extracted)", detail: ByteCountFormatter.string(fromByteCount: progress.bytesRead, countStyle: .file) + " processed¹")
                        metric("Active time", value: String(format: "%.2fs", progress.activeSeconds), detail: String(format: "%.1f files/sec", progress.filesPerSecond))
                    }
                    HStack(alignment: .top, spacing: 20) { configuration; engine }
                    exclusions
                    HStack(alignment: .top, spacing: 20) { scopes; skips }
                    events
                }.padding(24)
            }
        }.frame(width: 900, height: 730)
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.indexSettings.paused ? "Paused" : progress.phase.rawValue.capitalized, systemImage: model.indexSettings.paused ? "pause.circle" : "waveform.path").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.indexing { Button("Stop after current files") { model.stopIndexing() } }
                Button(model.indexSettings.paused ? "Resume indexing" : "Pause indexing") { model.setIndexPaused(!model.indexSettings.paused) }
                if !model.indexing { Button("Check for changes") { model.startIndexing() }.disabled(model.indexSettings.paused) }
            }.buttonStyle(.bordered).controlSize(.small)
            if progress.phase == .discovering { ProgressView().progressViewStyle(.linear) }
            else if let fraction = progress.fraction { ProgressView(value: fraction).tint(.primary) }
            HStack {
                Text("\(progress.processed) processed / \(progress.discovered) discovered").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(progress.checkpointed) checkpointed").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(progress.message).font(.system(size: 11)).foregroundStyle(.secondary)
            if progress.limitReached { Label("This pass reached the semantic file limit. More files may remain; raise the limit below. Browsing and Spotlight still cover accessible locations.", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            ForEach(progress.activePaths ?? [], id: \.self) { path in Text("Assigned: " + path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path) }
            if !progress.currentPath.isEmpty { Text("Latest decision: " + progress.currentPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(progress.currentPath) }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
    private func metric(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 23, weight: .medium)).monospacedDigit(); Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }.padding(13).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Work budget").font(.headline)
            Picker("Semantic file limit", selection: Binding(get: { model.indexSettings.maxFiles }, set: { value in var settings = model.indexSettings; settings.maxFiles = value; model.updateIndexSettings(settings) })) { Text("2,000 files").tag(2000); Text("10,000 files").tag(10000); Text("No limit").tag(0) }
            Picker("Parallel workers", selection: Binding(get: { model.indexSettings.workers }, set: { value in var settings = model.indexSettings; settings.workers = value; model.updateIndexSettings(settings) })) { Text("1 · Low impact").tag(1); Text("2 · Balanced").tag(2); Text("4 · Faster / more CPU").tag(4) }
            Text("Settings apply to the next pass. Low Power Mode limits work to one worker. Pause finishes in-flight files; completed work is checkpointed.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .topLeading).disabled(model.indexing)
    }
    private var engine: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine & timing").font(.headline)
            Text(progress.modelAvailable ? "Vectors available" : progress.skipReasons["Model unavailable"] != nil ? "Model unavailable · filename search still works" : "Model is loaded only when needed").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(progress.engine).font(.system(size: 11))
            Text(progress.engineID.isEmpty ? "Model loads lazily when needed" : progress.engineID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text("\(progress.workers) workers · CPU vector search via Accelerate").font(.system(size: 10))
            Text(String(format: "Extraction %.3fs · Word counting %.3fs · Inference %.3fs", progress.extractionSeconds, progress.tokenizationSeconds, progress.embeddingSeconds)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("\(progress.wordUnits) word units newly counted. These are not model tokens: Apple owns internal tokenization and does not expose GPU/Neural Engine placement. Timings sum across workers, so may exceed wall time.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            Text("¹ Text reports bytes read; PDFs report source bytes processed, not physical disk I/O. Extracted document text is never saved to the index.").font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("Your exclusions").font(.headline); Spacer(); Button("Exclude folder…") { model.addIndexExclusion() }.disabled(model.indexing) }
            Text("Exclusions affect semantic indexing only. Browsing and macOS Spotlight remain available. Defaults also exclude hidden items, symbolic links, generated/system directories, app data, and vault contents.").font(.system(size: 10)).foregroundStyle(.secondary)
            if model.indexSettings.excludedFolders.isEmpty { Text("No additional exclusions").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(model.indexSettings.excludedFolders, id: \.self) { folder in
                HStack { Text(folder.path).font(.system(size: 10)).lineLimit(1).truncationMode(.middle); Spacer(); Button("Remove") { var settings = model.indexSettings; settings.excludedFolders.removeAll { $0 == folder }; model.updateIndexSettings(settings) }.disabled(model.indexing) }
            }
        }
    }
    private var scopes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Discovery scope").font(.headline)
            ForEach(Array(Set(model.indexScopes)).sorted { $0.path < $1.path }, id: \.self) { url in Text(url.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Text("Content bounds: 5 MB files; 64 KiB text reads; up to 20 PDF pages; 4,000 input characters per embedding. Unsupported formats use their filename.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var skips: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Skipped / restricted items").font(.headline)
            if progress.skipReasons.isEmpty { Text("None reported in this pass").font(.system(size: 10)).foregroundStyle(.secondary) }
            ForEach(progress.skipReasons.keys.sorted(), id: \.self) { reason in HStack { Text(reason); Spacer(); Text("\(progress.skipReasons[reason] ?? 0)").monospacedDigit() }.font(.system(size: 10)).foregroundStyle(.secondary) }
            Text("Counts include directory exclusions. Sensitive detection is a heuristic, not encryption.").font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var events: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recent activity · last 100 items this session").font(.headline)
            if progress.events.isEmpty { Text("Start a pass to see each file’s cache decision or exclusion reason.").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(progress.events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Text(event.outcome).font(.system(size: 10, weight: .medium)).frame(width: 98, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.path).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(event.path)
                        Text(event.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.date, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                Divider().opacity(0.35)
            }
            Text("On disk: library.json stores paths, stat signatures, and summary counters; IndexObjects stores hashed embedding objects. Both are local and unencrypted. Activity paths above are session-only.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
}
