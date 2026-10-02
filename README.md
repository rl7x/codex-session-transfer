# Codex Session Transfer

A macOS menu bar app that copies one Codex session to another Mac and installs it in `~/.codex`.

On the sending Mac the session can live in `~/.codex-work` or `~/.codex`. Lookup checks the work home first. The receiving Mac always writes `~/.codex`, including when that Mac has no work account.

## Build

```bash
./scripts/build-app.sh
open CodexSessionTransfer.app
```

Install the same app on both Macs. macOS will ask for local network access the first time the apps discover each other.

## Send a session

1. On the destination Mac, leave **Receive on this Mac** on and note the six-digit pairing code.
2. On the source Mac, paste the session id and choose **Look up**. The preview shows which home the session came from, its title, and the rollout size.
3. Other Macs show up under Destination. Pick one. A Mac that is already receiving is selected when it is the only one. Enter the pairing code and choose **Send**.
4. On the destination Mac, resume it with `codex resume <id>`. If Codex was already open, quit and reopen it so it reloads the thread list.

The session id can be the thread id, a unique thread name, or a rollout filename.

## What is copied

The package matches the local importer in `~/.local/bin/codex-import-session`, plus that thread's dynamic tools:

- The rollout transcript, copied byte for byte. History rows store offsets into this file.
- The `threads` row in `state_5.sqlite`. `rollout_path` is rewritten into the destination `~/.codex`. `project_id` and `thread_section_id` are cleared when that parent row does not exist there.
- `thread_dynamic_tools` for that thread.
- `thread_turns`, `thread_items`, and `thread_history_projection_state` in `thread_history_1.sqlite`.

`auth.json` and the rest of the Codex home stay put. Spawned child threads are separate sessions; transfer each id on its own. If the thread id is already on the destination, the import stops instead of overwriting it. If the rollout file is already there and the bytes differ, the import stops. If the `threads` or history columns do not match, update Codex on both Macs and try again.

The pairing code is the only check on the transfer. Traffic is unencrypted HTTP on the local network.
