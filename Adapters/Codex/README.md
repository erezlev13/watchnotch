# Codex session monitoring

Connect a chosen thread by pasting its UUID or an original `codex://threads/UUID` link into the companion's Codex connection field. The monitor asks the local daemon for that thread's metadata every 2.5 seconds. The title comes from the thread name when available. The companion builds a **Jump in** desktop link from the thread UUID and accepts an optional corresponding web address in Manage sessions.

From the repository root, the same monitor can run on its own.

```sh
/usr/bin/python3 Adapters/Codex/monitor.py 'codex://threads/YOUR-THREAD-UUID'
```

The adapter uses Python 3.9 or later and the running local Codex App Server. Check its availability with `codex app-server daemon version`. To observe a server with a custom local socket, pass `--socket /path/to/socket`. The ordinary socket is under `$CODEX_HOME/app-server-control`, which defaults to `~/.codex/app-server-control`. The adapter never starts or restarts the daemon.

The monitor writes a snapshot in `~/Library/Application Support/Mac Notch Session Companion/Sessions`. Set `NOTCH_SESSION_DIR` to select another directory. Each thread has a distinct file and a single writer. Quiet polls leave the file untouched. On a disconnect after discovery, its last sentence stays visible and its state becomes unavailable. The monitor retries the connection while it runs. Control-C or SIGTERM closes the monitor and marks the card unavailable.

The reply field at the bottom of each tile sends text to the selected thread using the local App Server. The adapter checks the thread identity and state first, then calls `turn/start`. A returned turn ID confirms acceptance. If delivery is uncertain, the draft stays on the tile for inspection in the original session.

The library checks active workers under account-visible pinned parents every three seconds while the row is open. It identifies delegated workers by their spawn metadata, confirms their current runtime status, and uses the thread title or task path for the label. Background Guardian reviews are excluded. Forks are discovered separately using `forkedFromId`. Select the compact branch tile to open that specific Codex thread.

## What was verified

On November 21, 2026, the installed standalone CLI and running App Server both reported **0.171.0**. The local desktop bundle was **ChatGPT.app 26.1117.41037** (bundle identifier `com.openai.codex`, bundled CLI **0.171.0-alpha.13**).

| Surface | Verification |
| --- | --- |
| Two independent clients of the installed local daemon | One client started an ephemeral thread in a temporary folder. A second client observed the same stable ID change from ready to running and back to ready while the first ran a five-second sleep. |
| Replies | Two independent disposable threads received their own test messages through the local adapter. |
| Quiet cards, disconnect, restart | The test compared snapshot bytes across quiet polls, terminated the monitor and verified unavailable state with the previous sentence, then restarted it and verified the same ID came back ready. |
| Native desktop origin | The desktop automation tool refused access to `com.openai.codex`. No synthetic desktop-created thread was observed end to end. An ID owned by a different runtime can be missing or report `notLoaded`. |
| Approval | App Server reports waiting-on-approval and waiting-on-user-input flags. The adapter displays a source-session status when either flag appears. It exposes no in-notch decision buttons for Codex. A flag does not carry a request ID or command. |
| Open session and results | The installed desktop bundle registers the Codex URL scheme. A user-supplied original link is retained verbatim in canonical UUID form. Native navigation to a synthetic desktop thread and direct result opening remain unverified. |

Repeat the local test from the repository root while the daemon is running.

```sh
/usr/bin/python3 -B Adapters/Codex/verify.py
```

The test opens a disposable thread, runs the fixed command `/bin/sleep 5` and exits. It makes no model call. A successful run prints the four observations above the command prompt.

## Protocol and scope

Opening the session library pages through `thread/list` on the local Unix socket. The library retains thread IDs, titles and update times in memory. Each pinned monitor polls `thread/read`, looks up the latest turn with `thread/turns/list`, and requests a limited descending page from `thread/items/list` for that turn. The card uses a short excerpt from a visible agent update or a description of a file, command or search event. Reasoning, raw commands and tool output are excluded from the displayed sentence. The picker polls loaded, account-visible threads while open. The info button uses the configured model and effort from the thread and the locally recorded token count for that ID. Missing values stay unreported. Only the resulting snapshot is persisted. Older daemons and ephemeral sessions fall back to the available title and state. [OpenAI App Server guide](https://developers.openai.com/codex/app-server/)

Codex also documents project-scoped command hooks. A trusted `PermissionRequest` hook can return an allow or deny decision on its own invocation. This prototype uses the metadata observer so it can attach to a selected session without changing the user's hook configuration. Live native hook delivery and native approval routing were not demonstrated. [OpenAI hooks guide](https://developers.openai.com/codex/hooks/)
