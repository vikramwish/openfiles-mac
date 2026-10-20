# Incremental indexing and transparency

Open **Indexing activity** from the sidebar, footer, or menu bar. Browsing and Spotlight keep working while indexing is running or paused.

## Work you can inspect

The activity panel reports discovery and processing separately, with counts for unchanged files, content-cache hits, new embeddings, content reads, word-count passes, bytes processed, active time, checkpoints, and exclusion reasons. The current path and last 100 decisions are visible for the session. Summary counters survive restart; recent activity paths do not.

The percentage applies to the files discovered for the current pass, not every file on the Mac. During discovery the denominator is not yet known, so progress is indeterminate. If the file limit is reached the panel says so explicitly: completing that pass does not mean the whole home folder was embedded. The limit can be set to 2,000, 10,000, or unlimited. This never caps directory listings or Spotlight's search scope.

Pause prevents new work after in-flight files finish. It is remembered across app launches. Stop retains completed checkpoints and content objects; start another pass to retry unfinished work. Quitting requests cancellation and awaits the active indexing task before terminating. Indexing does not move, rename, or delete original files.

## How the faster path works

1. **Stat cache before content reads.** A per-file signature records device, inode, size, nanosecond modification time, and change time. With a matching engine/preparation version and valid cached vector, an unchanged file does not get reopened for text extraction, word counting, or inference. Sensitive classifications are also reused until the signature changes. This follows Git's stat-cache approach; it is not a cryptographic defense against a hostile filesystem writer.
2. **Content-addressed objects.** Changed files are read within explicit bounds, then the prepared embedding input and model/preparation identifier are hashed with SHA-256. Identical document text can share one embedding even under different filenames. Concurrent requests for that object share one inference task. Filename search remains separate. Unsupported formats remain searchable by name without inference.
3. **Versioned cache keys.** The Apple English sentence-embedding revision and preparation version are part of the identity. Changing either invalidates reuse. Missing/unreadable objects are recomputed. Files are checked again after extraction and inference; changed files are skipped for a later pass.
4. **Bounded native workers.** The default is two utility-priority workers, each owning an isolated native embedding backend. Select one, two, or four workers; Low Power Mode limits a pass to one. This bounds concurrency rather than starting a task per file. More workers can increase CPU use and are not guaranteed to improve throughput.
5. **Accelerate vector math.** Document and query vectors are normalized once; compatible vectors use a dot product for cosine ranking. Apple's Accelerate chooses CPU vector instructions for the host. Repeated query vectors are memoized in a bounded in-memory cache.
6. **Checkpoints and responsive services.** The library actor yields while a separate indexing job runs. Browser navigation uses its own actor, and queries use a separate embedding backend. Completed file records are checkpointed at 2,048 records or after five seconds of pending work, and at the end/cancellation. Versions and organization settings are merged rather than replaced by checkpoints.

## Tokenization, bounds, and hardware

The current backend is **Apple NaturalLanguage / NLEmbedding**, not MLX. Apple owns the internal model tokenizer and compute placement. OpenFiles cannot report an accurate internal model-token count, GPU utilization, or Neural Engine use through this API. The panel labels search-tokenizer counts as **word units**, not model tokens. There is no separate NLTokenizer counting pass. Avoiding duplicate inference also avoids the model's duplicate tokenization. Search terms and word counts share one bounded cache across workers; duplicate text reuses them.

Text reads are capped at 64 KiB and retained transiently up to 12,000 characters; supported PDFs up to 5 MB are processed for at most 20 pages and 12,000 characters. Embedding input is capped at 4,000 characters. PDF byte metrics describe source bytes processed, not actual physical disk reads. Summed per-worker extraction/inference timings can exceed elapsed wall time.

Hidden items, symbolic links, app data/vault contents, Python environments (including custom names identified by pyvenv.cfg), package caches, and generated/system directories are excluded from semantic discovery by default. User exclusions are configurable in the panel. Cloud placeholders are not downloaded for content extraction. Format/size/cloud/locked-PDF limits produce metadata-only records with a visible reason; transient content-access failures are retried on later passes. Sensitive filename/content heuristics suppress embeddings but are incomplete, especially for opaque formats.

## Stored data

`~/Library/Application Support/OpenFiles/library.json` stores paths, stat signatures, classification, object keys, index settings, and summary counters. New vectors are stored once per object under `IndexObjects/<sha256>.json`; legacy inline vectors are read for migration. Full extracted text is not persisted. File records now retain normalized unique search terms from the first 6,000 extracted word units (at most 12,000 source characters) for inverted-index lookup. Sensitive-classified files retain no content terms. Terms can reveal document contents and are unencrypted, like filenames and embeddings. Saved smart-group query definitions are stored alongside index state. Objects contain the model identifier, normalized vector, word-unit count, input length, and timing metadata. Both the manifest and objects are local and **unencrypted**. Pause/exclusion does not securely erase previously computed objects; there is no object garbage collector yet. Existing history and encrypted vault storage are separate.

## Benchmark

Run the disposable benchmark in release mode:

```sh
swift run --build-system native -c release OpenFilesBenchmark --count 48
```

Three alternating baseline/optimized runs on the initial developer's **Apple M3 Max (arm64, 16 active CPUs)** used 48 bounded text documents containing 24 unique contents, with no user files. The table reports medians. Both versions used the same Apple native sentence-embedding backend and the same corpus generator. The baseline was repository commit `144b5d8`, built separately; build time is excluded.

| Pass | Baseline | Incremental implementation | Observed ratio |
| --- | ---: | ---: | ---: |
| Cold corpus | 2.128 s | 1.069 s | 2.0× faster |
| Warm refresh, same process | 0.064 s | 0.008 s | 8.0× faster |

This is a small synthetic comparison, not a universal speed claim. The optimized cold range was 1.064–1.083 s; warm range 0.008–0.010 s. All three warm passes reported zero content reads, zero new word-count/tokenization passes, zero inference calls, and 48 stat-cache hits. Duplicate content favors object reuse. Whole-home performance depends on file formats, storage, model initialization, cache state, temperature, and permissions. The benchmark also reports inference/read/tokenization counters and a restart-inclusive warm scan. Tests use an injectable backend to verify that warm scans perform zero content reads and zero inference, and that restart, cancellation, replacement, model-version changes, and missing objects behave correctly.

## References and extension boundary

- [Git index format](https://git-scm.com/docs/index-format): stat data and index caching.
- [MLX Swift LM / MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm): native Swift model isolation and local embedding implementations; a candidate backend for separately benchmarked GPU inference.
- [Hugging Face swift-transformers](https://github.com/huggingface/swift-transformers): tokenizer and model-loading APIs; useful if a model with an exposed tokenizer is introduced.
- [Apple Accelerate](https://developer.apple.com/documentation/accelerate): CPU vector arithmetic.

`EmbeddingBackend` is the small injectable boundary for a future MLX/Core ML backend. No MLX package, model weights, external runtime, or model download is added by this change. A future backend must supply a stable model/tokenizer identity and reindex compatible objects; it should not label diagnostic word counts as model tokens.


## Instant navigation and live reconciliation

`SearchCatalog` builds inverted postings and token-set/metadata caches from persisted file records at startup. Checkpoint and delta updates refresh those relationships; readers use a COW snapshot. Prefix lookup uses a sorted vocabulary, metadata predicates narrow candidates, and bounded top-K selection avoids sorting the complete result set. Fast results require no source-file reads, file metadata calls, or inference. Query embeddings are optional, memoized refinement after the first response. A missing model does not disable cached text or metadata lookup.

`NavigationQuery` deterministically parses common file kinds, known or quoted folder names, recent-first ordering, and today/yesterday/this-week/last-week/this-month/last-month/this-year modification filters. Group-by-folder/project uses folder relationships; kind and month are metadata groups. This is a supported query grammar, not general conversation or inferred project membership. The panel displays group counts for its bounded result set. A saved group stores the query, not a stale list of files.

File-level FSEvents notifications feed an 800 ms debounce and a retry queue. Individual changes are reconciled without walking unrelated roots; new/renamed directories enumerate their own subtree. The stat/content cache still avoids unchanged extraction and inference. Events are collected during indexing and pause. Full reconciliation happens on launch, wake, overflow/root changes, and every five minutes. No event journal cursor is persisted; startup reconciliation recovers changes missed while the app was closed. Watcher failure is reported and periodic reconciliation remains available. Index limits and unavailable locations mean this is not a claim to have mapped every file on the machine.

Source files are read-only to search/sync/grouping. Filesystem events update the index rather than authorizing moves or deletions. Unattended physical organization is disabled; original-file writes are separate explicit user operations. Content-based sensitivity checks remain heuristic and do not make the derived index encrypted.


## Image pixels and OCR

Raster images are processed by `NativeImageContent` with native Vision classification and accurate OCR on an ImageIO thumbnail (orientation applied, maximum side 2,048 pixels). Encoded files over 50 MB and unavailable cloud placeholders remain filename-only. GIF analysis uses the first frame. Up to 12 classifications at confidence >= 0.25 are retained. OCR candidates below 0.5 confidence are discarded, and extracted OCR text is transiently bounded to 12,000 characters. Only normalized OCR terms, predicted labels/confidences, and the Vision/preparation revision are persisted in `imageContent`.

The indexing worker applies the existing filename/content sensitivity checks before retaining visual metadata. A positive OCR-content sensitivity match discards both image metadata and searchable content terms. This is a heuristic, not a guarantee of private-image detection. Vision does not identify people or run a face-recognition feature here.

Image analysis revision is checked independently of the text embedding engine so previously filename-only images migrate on the next indexing pass. Stat-stable results, including completed filename-only size skips, are reused without pixel decoding; transient decoder/model/cloud failures remain retryable. Both full scans and incremental changes share the same worker. Fast search uses persisted labels/OCR postings rather than executing Vision. Neither requests nor extracted images are sent to a cloud service.

`EmbeddingBackend` is the injectable boundary for native inference. Its default query implementation preserves compatibility with existing backends; retrieval models can provide separate query prompting. The optional `OpenFilesMLX` target implements EmbeddingGemma 2. It requires a user-selected local checkpoint, fingerprints weights and tokenizer for cache compatibility, and reindexes after model changes. No automatic model download is performed. Diagnostic word counts remain separate from model tokens.

### Photo location metadata

The image revision also controls GPS/IPTC metadata refresh. `PhotoLocation` validates finite coordinates, latitude/longitude ranges and N/S/E/W references, retaining coordinates only as a complete pair. Embedded city, sublocation, province/state and country names are bounded to 200 characters each. Invalid or absent GPS never defaults to `(0, 0)`. Sensitive-classified records discard the entire image payload, including location.

`NavigationQuery` parses trailing `taken/captured/shot in/near/around/at <place>` and, for image-kind queries, `in/near/around/at <place>`. Folder filters take precedence. Catalog updates create normalized exact-name place postings plus a bounded offline city-radius lookup; query lookup needs no image read, location permission, or network service. Place names and GPS coordinates are unencrypted derived metadata in the local manifest. City radii are approximate, coverage is limited (see README), and geographic hierarchy and capture-date filtering are not implemented.


## Bounded streaming and relationship graph (October 2026)

Discovery feeds windows of 512 candidates into the worker pool instead of retaining an entire home-folder candidate list before processing begins. Each window favors personal documents, then media, then source code, with newer files first within each priority. Generated Doxygen trees are recognized by their marker files and skipped with an inspectable reason. The denominator stays indeterminate until discovery completes. Completed checkpoint batches become searchable during the scan.

Atomic delta checkpoints under `IndexCheckpoints/` replace repeated full-manifest writes. Startup replays them; a successful full save compacts them. The app initially loads metadata and lexical postings without opening every vector object. Query refinement hydrates up to 256 lexical candidates, and indexing workers recover unchanged cached vectors on demand. Global semantic coverage therefore builds as vectors become available during reconciliation.

The relationship graph reuses file-to-term postings: up to 24 rare features, 128 neighbors per feature and 1,024 total candidates, followed by compatible-vector reranking. Sensitive records are excluded. Related Files shows shared-term evidence. A small bounded semantic fallback handles sparse overlap; this is approximate candidate retrieval, not exact global nearest-neighbor search. No quadratic all-pairs graph is stored. Writers prepare COW snapshots outside the reader lock; unchanged upserts preserve the revision. Cached vector norms and date ordering avoid repeated normalization and full sorting for recent-file queries.

### Reproducible optimization measurements

Release binaries on Apple M3 Max, three alternating runs against commit `19b29d5`, same disposable 400-file corpus (320 unsupported binary files, 80 text files / 40 unique contents), medians excluding builds:

| Measurement | Before | After |
| --- | ---: | ---: |
| Cold indexing | 2.694 s | 2.218 s |
| Cached rescan | 0.148 s | 0.101 s |
| New inference calls | 360 | 40 |
| Warm content reads / inference | 0 / 0 | 0 / 0 |

A separate 1,000-iteration, 12,000-character ASCII tokenizer comparison measured 0.233 s for the previous Foundation path and 0.064 s for the fast path (3.7×); Unicode parity is covered separately by checks. A synthetic 10,000-file, 512-dimensional clustered graph measured 2.08 ms median / 2.56 ms p95 over 100 relationship queries, with a 1,024-candidate budget. These results are workload-specific and do not predict a whole-Mac scan or general semantic recall.

Run `OpenFilesBenchmark --mixed --count 400`, `--tokens`, or `--graph` with a release build. `OpenFilesChecks --index` exercises cache reuse, limits, pause/cancel, checkpoint recovery before completion, lazy hydration, tokenizer parity, graph updates and concurrent readers.
