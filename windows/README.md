# watchnotch for Windows

The Windows preview places a collapsible session strip at the top of the primary display. Click the owl to expand pinned cards. Open **Library** to find sessions, paste a link, or unpin a card. Cards keep their pin order across launches and page across narrower displays. The owl follows the most recently changed pinned session that is working or needs input. Status updates wrap in the card and appear top to bottom. New sentences wait until the current one has had time to be read. Click an update to reveal it immediately. With Windows animations disabled, the full update appears at once.

## Run

Use a Windows desktop with Python 3.9 or newer and Tkinter (included with the standard python.org Windows installer). From this repository in PowerShell, run

```powershell
py -3 windows\watchnotch.pyw
```

For a console-free launch, double-click `watchnotch.pyw` with the Python windowed launcher associated. Choose **Quit** from the expanded strip or library to exit.

## Connect sessions

| Source | In the library | On the card |
| --- | --- | --- |
| Codex | Choose **Refresh Codex**, or paste a UUID or `codex://threads/<UUID>`. | The local daemon supplies state and a short visible activity update. **Jump in** uses the Windows handler registered for the Codex link. Working and waiting subagents appear under their pinned parent and disappear when their turn ends. Direct forks remain available. Click either to open its thread. Review approvals inside Codex. |
| ChatGPT | Paste a private `https://chatgpt.com/c/<UUID>` link, paste its link into library search, or choose **Import export** for a conversations JSON or export ZIP. | **Jump in** opens the canonical conversation URL in its registered HTTPS handler. |
| Local discovery | **Desktop chats** reads the conversation index and its reported ChatGPT Work activity when the desktop app exposes it under `CODEX_HOME/sqlite/codex.db`. **Visited chats** searches accessible Edge, Chrome, Brave, Chromium and Firefox histories on request. | Choose **Pin / unpin** to add the selected conversation. Profiles locked by a running browser can be skipped. |

Codex monitoring requires a native `codex.exe` with `app-server proxy` and an existing local daemon that can see the selected thread. Check it with `codex app-server daemon version`. The companion uses the standalone executable under `CODEX_HOME` (default `~/.codex`) or a native executable on PATH. It requests thread details only for pinned Codex IDs, polls about every 2.5 seconds, and retries after disconnects. The last observed sentence stays visible with an **Unavailable** label while disconnected. Saved ChatGPT links work independently of Codex. [Codex daemon platform support](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)

Open **Library** and select **Active** for working or waiting Codex threads and ChatGPT conversations with a running catalog status. The app checks for the packaged Codex desktop window in the current Windows session. A matched catalog conversation shows **Monitoring** while the app is open and quiet, and **Offline** when it closes. A browser or export link alone has no activity signal. New Work turns can appear before their title arrives when the local catalog identifies the same account and desktop profile.

Type below **Jump in** on a pinned card. Return or **Send** submits a draft to that specific connected Codex thread. **Copy & open** keeps the draft for you to paste into ChatGPT or a Codex thread that needs input or is unavailable. An unconfirmed send keeps the draft and switches it to **Copy & open**. Drafts stay in memory per tile while the app is open.

Pins and imported conversation titles, IDs and dates are stored in `%LOCALAPPDATA%\watchnotch\library.json`. Browser history is opened read-only. Conversation bodies from exports and observed Codex progress stay out of the saved library.

Open **Account usage** on a Codex card to see the percentage used in each reported account window. The app reads the limits on demand. If the account supplies no percentages, the window displays **Account usage unavailable**.

## Verification and remaining parity work

Run `py -3 -m unittest discover -s windows -v` from the repository root. The native window test pins a synthetic conversation through the library, exercises a mocked URL handoff, then removes the pin. The portable tests cover persistence, read-only discovery, imports, progress and reconnects.

The proxy transport observed a disposable real thread progress from ready to running and back to ready on macOS. A native Windows desktop still needs an end-to-end check against a desktop-created Codex thread, the installed URL handlers and actual profile/catalog locations. The Windows preview uses the registered URL handler for conversation handoffs. Native ChatGPT navigation, the Mac demo approval/result flow and multi-monitor placement remain platform differences.
