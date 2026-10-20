# Incremental indexing and transparency

Open **Indexing activity** from the sidebar, footer, or menu bar. Browsing and Spotlight keep working while indexing is running or paused.

## Work you can inspect

The activity panel reports discovery and processing separately, with counts for unchanged files, content-cache hits, new embeddings, content reads, word-count passes, bytes processed, active time, checkpoints, and exclusion reasons. The current path and last 100 decisions are visible for the session. Summary counters survive restart; recent activity paths do not.

The percentage applies to the files discovered for the current pass, not every file on the Mac. During discovery the denominator is not yet known, so progress is indeterminate. If the file limit is reached the panel says so explicitly: completing that pass does not mean the whole home folder was embedded. The limit can be set to 2,000, 10,000, or unlimited. This never caps directory listings or Spotlight's search scope.

Pause prevents new work after in-flight files finish. It is remembered across app launches. Stop retains completed checkpoints and content objects; start another pass to retry unfinished work. Quitting requests cancellation and awaits the active indexing task before terminating. Indexing does not move, rename, or delete original files.

## How the faster path works

1. **Stat cache before content reads.** A per-file signature records device, inode, size, nanosecond modification time, and change time. With a matching engine/preparation version and valid cached vector, an unchanged file does not get reopened for text extraction, word counting, or inference. Sensitive classifications are also reused until the signature changes. This follows Git's stat-cache approach; it is not a cryptographic defense against a hostile filesystem writer.
2. **Content-addressed objects.** Changed files are read within explicit bounds, then the prepared embedding input and model/preparation identifier are hashed with SHA-256. Identical document text can share one embedding even under different filenames. Concurrent requests for that object share one inference task. Filename search remains separate. Unsupported formats embed the filename instead.
3. **Versioned cache keys.** The Apple English sentence-embedding revision and preparation version are part of the identity. Changing either invalidates reuse. Missing/unreadable objects are recomputed. Files are checked again after extraction and inference; changed files are skipped for a later pass.
4. **Bounded native workers.** The default is two utility-priority workers, each owning an isolated native embedding backend. Select one, two, or four workers; Low Power Mode limits a pass to one. This bounds concurrency rather than starting a task per file. More workers can increase CPU use and are not guaranteed to improve throughput.
5. **Accelerate vector math.** Document and query vectors are normalized once; compatible vectors use a dot product for cosine ranking. Apple's Accelerate chooses CPU vector instructions for the host. Repeated query vectors are memoized in a bounded in-memory cache.
6. **Checkpoints and responsive services.** The library actor yields while a separate indexing job runs. Browser navigation uses its own actor, and queries use a separate embedding backend. Completed file records are checkpointed at 128 records or after five seconds of pending work, and at the end/cancellation. Versions and organization settings are merged rather than replaced by checkpoints.

## Tokenization, bounds, and hardware

The default backend is **Apple NaturalLanguage / NLEmbedding**. Apple owns its internal model tokenizer and compute placement. An optional Apple Silicon build supports **EmbeddingGemma 2 through MLX**, using one shared model container and distinct retrieval-query/document prompts; see [EMBEDDINGGEMMA.md](EMBEDDINGGEMMA.md). OpenFiles does not report model-token counts, GPU utilization, or Neural Engine use. The panel labels its diagnostic `NLTokenizer` counts as **word units**, separate from either model's tokenizer. Avoiding duplicate inference also avoids duplicate model tokenization. Word counting happens once per newly computed content object, not for stat/content cache hits.

Text reads are capped at 64 KiB and retained transiently up to 12,000 characters; supported PDFs up to 5 MB are processed for at most 20 pages and 12,000 characters. Embedding input is capped at 4,000 characters. PDF byte metrics describe source bytes processed, not actual physical disk reads. Summed per-worker extraction/inference timings can exceed elapsed wall time.

Hidden items, symbolic links, app data/vault contents, Python environments (including custom names identified by pyvenv.cfg), package caches, and generated/system directories are excluded from semantic discovery by default. User exclusions are configurable in the panel. Cloud placeholders are not downloaded for content extraction. Format/size/cloud/locked-PDF limits produce filename-only embeddings with a visible reason; transient content-access failures are retried on later passes. Sensitive filename/content heuristics suppress embeddings but are incomplete, especially for opaque formats.

## Stored data

`~/Library/Application Support/OpenFiles/library.json` stores paths, stat signatures, classification, object keys, index settings, and summary counters. New vectors are stored once per object under `IndexObjects/<sha256>.json`; legacy inline vectors are read for migration. Extracted text and diagnostic word lists are not persisted. Objects contain the model identifier, normalized vector, word-unit count, input length, and timing metadata. Both the manifest and objects are local and **unencrypted**. Pause/exclusion does not securely erase previously computed objects; there is no object garbage collector yet. Existing history and encrypted vault storage are separate.

## Benchmark

Run the disposable benchmark in release mode:

```sh
swift run --build-system native -c release OpenFilesBenchmark --count 48
```

A single comparison on the initial developer's **Apple M3 Max (arm64, 16 active CPUs)** used 48 bounded text documents containing 24 unique contents, with no user files. Both versions used the same Apple native sentence-embedding backend and the same corpus generator. The baseline was repository commit `144b5d8`, built separately; build time is excluded.

| Pass | Baseline | Incremental implementation | Observed ratio |
| --- | ---: | ---: | ---: |
| Cold corpus | 2.034 s | 0.975 s | 2.1× faster |
| Warm refresh, same process | 0.062 s | 0.007 s | 8.9× faster |

This is one small synthetic run, not a universal speed claim. Duplicate content favors object reuse. Whole-home performance depends on file formats, storage, model initialization, cache state, temperature, and permissions. The benchmark also reports inference/read/tokenization counters and a restart-inclusive warm scan. Tests use an injectable backend to verify that warm scans perform zero content reads and zero inference, and that restart, cancellation, replacement, model-version changes, and missing objects behave correctly.

## References and extension boundary

- [Git index format](https://git-scm.com/docs/index-format): stat data and index caching.
- [MLX Swift LM / MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm): native Swift model isolation and local embedding implementations; a candidate backend for separately benchmarked GPU inference.
- [Hugging Face swift-transformers](https://github.com/huggingface/swift-transformers): tokenizer and model-loading APIs; useful if a model with an exposed tokenizer is introduced.
- [Apple Accelerate](https://developer.apple.com/documentation/accelerate): CPU vector arithmetic.

`EmbeddingBackend` is the injectable boundary for native inference. Its default query implementation preserves compatibility with existing backends; retrieval models can provide separate query prompting. The optional `OpenFilesMLX` target implements EmbeddingGemma 2. It requires a user-selected local checkpoint, fingerprints weights and tokenizer for cache compatibility, and reindexes after model changes. No automatic model download is performed. Diagnostic word counts remain separate from model tokens.
