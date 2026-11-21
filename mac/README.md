# watchnotch

![watchnotch owl](../docs/media/owl-small.png)

[Website and Mac download](https://erezlev13.github.io/watchnotch/)

Watch selected ChatGPT Work conversations and Codex threads from the notch on your Mac. Click the strip by the camera or use the menu bar item to expand the pinned row. The owl follows the latest live update. Each tile types one short status in white and grows vertically to show the whole sentence. Typing slows at punctuation. Click the summary to reveal it immediately, or enable Reduce Motion to show every update in full.

When Codex reports a subagent or fork, a small clickable tile inside the pinned parent opens that branch. Each pinned tile is at most 300 points wide. Your display determines how many fit. On a smaller screen, scroll horizontally to reach existing pins.

![Two example Mac tiles with a wrapped Codex build summary, a direct reply field and a ChatGPT Work draft field](../docs/media/reply-tiles.png)

## Build and open

On this Mac, run the following from the `mac/` directory.

```sh
./scripts/build.sh
open ".build/watchnotch.app"
```

The app starts with three labeled demo cards. Open the sliders or choose **Session library…** in the menu bar to search local sessions and manage pins. Choose **Active** to find sessions that are working or waiting for input. You can also paste a private ChatGPT conversation link into search. The ChatGPT tab also offers browser history lookup and account export import for chats outside the catalog. Imports retain titles, IDs and dates on this Mac. Pins retain their order across launches. The menu bar item also lets you quit.

| Source | How to connect | What the card can do |
| --- | --- | --- |
| Codex | Pin a local thread from the library, or use **Add link** with its UUID or desktop link. | Shows a summary from visible agent messages and recognized activity. The ⓘ button shows the configured model, reasoning effort and account usage percentages when available. Use the reply arrow to send to the selected thread. |
| ChatGPT and ChatGPT Work | Pin a conversation from the desktop catalog, browser history or an export, or paste its private conversation link. | Shows status supplied by the desktop app. **Copy & open** places your draft on the clipboard and opens the conversation for you to paste and send. A conversation known only by its link can still open in the browser. |
| Demo | Pin a sample from the picker. **Replay demo events** resets the timeline. | Simulates independent approvals and replies. Approve once writes the selected session’s sample file. Deny skips it. Decisions expire after two minutes. |

## Reply from the notch

Expand the pinned row and type in **Reply to this session** below **Jump in**. Drafts stay with their own tile when you switch tiles or collapse the row. Press Return or click the arrow to send to a connected Codex thread. If the thread is offline or awaiting input, use **Copy & open** to continue in the original session. ChatGPT uses **Copy & open** for every draft.

The Codex monitor polls its local App Server about every 2.5 seconds. ChatGPT activity refreshes about every three seconds while a chat is pinned or the library is open. The desktop app may report an active Work turn before supplying its title. watchnotch displays that conversation by ID until the title arrives. Account exports and browser imports supply conversation links. Live updates depend on a matching desktop activity signal.

Pins, demo outputs and snapshots are stored locally in the Mac Notch Session Companion folder under Application Support. Independent disposable Codex threads were used to verify delivery of distinct replies to the selected sessions. [Codex adapter](Adapters/Codex/README.md) · [ChatGPT adapter](Adapters/ChatGPT/README.md)

## Jump back to a session

Choose **Jump in** on a linked tile, including while a decision is pending. The panel collapses after macOS accepts the handoff. **Open result** remains a separate action. Control-click **Jump in** and choose **Open in browser** to use the saved web address directly.

For ChatGPT, **Jump in** looks for the selected conversation in the running desktop app. macOS Accessibility permission can help watchnotch find it in the app’s navigation. Use the globe button to open the private web address directly. If the desktop app is closed, the conversation opens in your default browser.

Codex threads use their desktop UUID route. Pair a cloud counterpart by entering the local UUID and the private web URL in Manage sessions. The provider handles thread loading and account access.

## Verify

```sh
./scripts/test.sh
/usr/bin/python3 -B Adapters/Codex/verify.py
/usr/bin/python3 -B scripts/verify-panel.py
/usr/bin/python3 -B scripts/verify-panel.py --five
```

The first script tests session identity, pin persistence, adaptive tile width and pin capacity, result creation, and duplicate, expired and disconnected decisions. The Codex check needs the running local daemon. The final two commands also need a graphical desktop. They use disposable directories, capture only the companion's own window and save the images to Demo.

Coucou inspired the small notch strip and the ability to act on a session without switching windows. [Coucou](https://github.com/Louis-CFM/coucou)
