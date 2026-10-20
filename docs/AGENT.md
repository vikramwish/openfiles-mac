# Hermes agent suggestions

OpenFiles can ask a Hermes agent for help with the files you are looking at. The agent is a planning model: it only proposes actions, and OpenFiles applies them through the same reviewed, verified flows used everywhere else. Nothing changes without your explicit approval.

Open **Ask Hermes…** in the browser toolbar, or choose **Ask Hermes about files…** in the OpenFiles menu (⌘⇧A).

## What the agent can propose

- **Renames** — better filenames for the files you see. Applied through the reviewed rename flow: the file is re-read, the suggested name is validated (same extension, no path tricks, no sensitive files), copies are verified byte-for-byte, and the original is removed only after the replacement is confirmed.
- **Moves** — move a file into a destination folder. The preview refuses sensitive files, symbolic links, files outside your personal folders, protected/system locations and destinations outside your scope; applying re-verifies stamps and digests, never replaces an existing file (a suffixed copy is proposed instead), and removes the original only after the copy is verified.
- **Navigation** — open a folder in the browser so you can inspect what the agent found.

The agent cannot invent paths, touch files outside your personal folders, act on sensitive files, or apply anything on its own. Unknown action kinds are refused and reported, and plans are capped at 12 actions.

## Model service

The panel speaks the OpenAI-compatible chat API. Presets cover **OpenRouter** (default, `https://openrouter.ai/api/v1`), the local **Hermes proxy** (`http://127.0.0.1:8645/v1`), and **LM Studio** (`http://127.0.0.1:1234/v1`); any compatible endpoint can be entered. The model is selectable; **Load models** lists the endpoint's models.

The API key is stored only in the macOS **Keychain** (like cloud registration fields) and is never written to library.json, UserDefaults or logs. **Import key from Hermes…** copies your existing `OPENROUTER_API_KEY` from the Hermes configuration (`~/.hermes/.env` or `~/.hermes/profiles/*/.env`) into Keychain. **Remove key** deletes it.

## What is sent

For the folder you are browsing: file names, folder paths, sizes and your request. With **excerpts** enabled (the default), the first 400 characters of small text files (≤ 64 KB, up to 20 files) are included so renames can reflect content. Potentially sensitive files and excerpts are filtered out locally before anything is sent, and at most 60 entries are included. File contents are read for no other purpose and never leave your Mac except as these excerpts. Each request opens with a system prompt that constrains the model to the paths in context.

## Checks

`make test` runs `OpenFilesAgentChecks`: plan decoding and refusal of unknown kinds, invalid names, invented paths and duplicate or oversized plans; prompt boundaries and excerpt omission; the client's request shape, key handling and provider errors; and move preview/apply guards on temporary fixtures (changed sources, symlinks, out-of-scope and sensitive files, collisions). No network, keys or personal folders are involved.

The agent has no write access of its own: the model endpoint only receives the planning prompt, and every filesystem change is executed by OpenFiles after your approval.
