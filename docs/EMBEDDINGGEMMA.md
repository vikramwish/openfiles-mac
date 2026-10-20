# EmbeddingGemma 2 search

OpenFiles can use [google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2) through Apple's MLX implementation. This integration embeds text extracted from documents and filenames. Image, audio, and video encoders are not used.

## Build and select a model

The optional build requires Apple Silicon, full Xcode with Swift 6.3+, and the Metal toolchain. The pinned MLX runtime requires Swift 6.3 even though the higher-level MLX model package declares Swift 6.2. Check `xcrun swift --version` and `xcodebuild -version`. Select the appropriate Xcode installation if necessary. The default Apple backend still builds with Swift 5.9+ and Command Line Tools.

From the repository root:

```sh
OPENFILES_MLX=1 make test
OPENFILES_MLX=1 make build
OPENFILES_MLX=1 make run
```

These commands use `xcodebuild` for the optional build. Plain `swift build` does not compile MLX's Metal shaders. The app assembly script copies the generated package resource bundles into `OpenFiles.app/Contents/Resources` before ad-hoc signing. `OPENFILES_MLX=1 make release` builds the optimized variant. Set `OPENFILES_MLX=1` for every command that should include the MLX backend; it changes the package graph at manifest evaluation time. For Xcode editing, launch Xcode with that environment variable set, or use the command-line scripts.

The direct MLX, model implementation, and tokenizer dependencies are pinned in `Package.swift`; the default build resolves none of them. The MLX backend lives in `Sources/OpenFilesMLX/` and conforms to the existing core `EmbeddingBackend` protocol.

Download a checkpoint using Hugging Face's CLI on the Mac. Apple's embedder registry recommends the following MLX conversion of EmbeddingGemma 2:

```sh
# Install the hf CLI separately if needed: https://huggingface.co/docs/huggingface_hub/guides/cli
hf download mlx-community/embeddinggemma-2-bf16 \
  --local-dir "$HOME/Library/Application Support/OpenFiles/Models/embeddinggemma-2"
```

Review the checkpoint's model card and license before downloading. If a repository requires access, complete that on Hugging Face and authenticate the CLI locally. OpenFiles does not need a Hugging Face token. Keep the complete checkpoint together, including `config.json`, `tokenizer.json`, `tokenizer_config.json`, and all safetensors shards/indexes. Wait for the download to finish and do not edit checkpoint files while they are loaded. A compatible `embedding_gemma2` or `embedding_gemma2_text` checkpoint is required; the earlier EmbeddingGemma 300M architecture is rejected. Quantized variants get separate cache identities.

Open **Indexing activity**, stop any current pass, and choose **Search model → Use EmbeddingGemma 2…**. Select the downloaded folder. Loading hashes the checkpoint, loads the tokenizer and text model, and performs a probe query before saving the selection. One model container is shared by queries and indexing workers, with serialized inference to bound memory. MLX loads text weights; media encoders remain unused.

The selected folder is remembered in local app preferences. If it cannot be loaded after a restart, the app reports the problem in Indexing activity and uses the Apple backend. Select the repaired folder to retry, or choose **Use Apple model** to clear the preference. Switching is disabled during an indexing pass. If indexing is paused, resume it to rebuild the vectors.

## What changes in search

1. Existing extraction and sensitive-file exclusions run before inference. Text still uses the bounded 4,000-character input, and unsupported formats use their filename. Equal document text can share an embedding; filenames are ranked separately.
2. Documents receive `title: none | text: ` and queries receive `task: search result | query: `. The query keeps its original natural-language wording, bounded to the same input length. Lexical matching still uses the existing grouped terms and aliases.
3. The tokenizer adds the checkpoint's special tokens. Input is capped at 8,192 tokens. The model's own pooled/projected output is normalized to a 768-dimensional vector. Non-finite, zero, or unexpected-size output is rejected. No second mean-pooling step is applied.
4. Compatible query/document vectors are compared locally with Accelerate. Similarity orders index candidates and boosts grounded matches under the existing relevance rules. A high vector similarity alone does not admit unrelated results, and this change does not implement image/audio retrieval or a chat interface.
5. Each cache identity includes the checkpoint contents (weights, configuration, tokenizer), pinned inference runtime, dimensions, and prompt-preparation version. Selecting a different checkpoint invalidates stat and content cache reuse for that embedding space. Legacy vectors without an engine identifier are accepted only by the original Apple backend. Changing models also clears query memoization and discards results from queries still running on the old model.

Prior embedding objects remain on disk, allowing reuse if you switch back. Their hashes identify model inputs; they are not encryption. Existing limits remain: bounded text/PDF extraction, a configurable file cap, and at most 240 candidates receiving content checks per search.

## Verification

`make test` includes checks for query/document routing, sensitive exclusion, checkpoint identity changes, switching during an active pass, incompatible/legacy vectors, and a query finishing after its backend has changed. These use temporary fixtures and injected backends, without model downloads. With `OPENFILES_MLX=1`, the same checks also compile the native integration and Metal resources.

To exercise actual model weights on a compatible Mac:

```sh
OPENFILES_MLX=1 \
OPENFILES_TEST_EMBEDDINGGEMMA_MODEL="$HOME/Library/Application Support/OpenFiles/Models/embeddinggemma-2" \
make test
```

That additional check loads the real checkpoint and verifies vector dimensions, normalization, and that a honey-making document scores above an unrelated budget document for a query about bees. Without the variable it explicitly reports `SKIP`; the deterministic core scenarios still run. CI compiles both default and MLX builds; it does not download weights or validate real inference by default.

For the GUI smoke check, choose a model, index disposable text fixtures, search known filenames and natural-language queries, restart to verify the saved model selection, then switch back to Apple. Verify that the assembled app still loads the model when launched outside the build directory so missing Metal/tokenizer bundles are detected. Full native compilation, these GUI checks, and real-model inference require macOS; Linux parsing or manifest checks do not establish them.

## Implementation references

- [Google model](https://huggingface.co/google/embeddinggemma-2).
- [Apple's pinned EmbeddingGemma 2 usage and task prompts](https://github.com/ml-explore/mlx-swift-lm/blob/48114eedf3c3d4a682a6b1d644cc5af5c2945d10/Libraries/MLXEmbedders/README.md#embeddinggemma-2).
- [Apple's pinned model registry and local loading](https://github.com/ml-explore/mlx-swift-lm/blob/48114eedf3c3d4a682a6b1d644cc5af5c2945d10/Libraries/MLXEmbedders/ModelFactory.swift).
- [MLX Metal build instructions](https://github.com/ml-explore/mlx-swift/blob/0.32.3/README.md#xcodebuild).
