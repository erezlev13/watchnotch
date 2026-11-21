# watchnotch

![watchnotch owl](docs/media/owl-small.png)

Keep selected Codex and ChatGPT sessions within reach from a small desktop strip. Codex cards can show local thread activity. Saved ChatGPT cards reopen the conversation.

| Platform | Start here |
| --- | --- |
| macOS | Build and open the Swift app from the [Mac directory](mac/README.md), or use the [Mac preview download](https://erezlev13.github.io/watchnotch/). |
| Windows | Launch the Python desktop preview with `py -3 windows\watchnotch.pyw`. See the [Windows setup and verification notes](windows/README.md). |

## What you can do

| Workflow | On the desktop |
| --- | --- |
| Find and pin sessions | Search the library, filter to **Active**, paste a private ChatGPT link or add a Codex UUID. ChatGPT discovery can use the local desktop catalog, an on-demand browser history lookup or a conversation export. Pins keep their order. |
| Follow work | Expand the strip to see which thread is working, waiting for input, ready or offline. The owl follows recent activity. Status sentences wrap and queue so each one has time to be read. Click to reveal the full sentence or use the system’s reduced-motion setting. |
| Follow related threads | Working or waiting Codex subagents appear under the pinned parent. Select one to open it. Idle workers disappear and saved forks stay available. |
| Inspect details | In the Mac source build, open ⓘ for the reported Codex model, reasoning effort and account usage windows. Preview 0.1.7 shows recorded session tokens. On Windows, open **Account usage** for reported percentages. |
| Reply or hand off | A connected Codex thread accepts replies from its own tile. Each tile keeps its draft. The Mac source build also sends text through the verified ChatGPT desktop composer with Accessibility access. **Copy & open** lets you finish a draft in the original session. |
| Handle a request | The Mac source build displays supported Codex questions and one-time approvals, plus visible single-choice and approval cards in desktop ChatGPT. On Windows, review requests in the original session. |
| Return to the work | **Jump in** opens the selected session. On Mac, the globe or **Open in browser** uses a saved web link, and **Open result** opens an available result separately. |

## Choose a build

- **Mac preview 0.1.7** is an ad-hoc signed download for Apple silicon on macOS 13 or later. It includes queued status updates, active subagent tiles, Codex replies and ChatGPT draft handoff. [Preview and release notes](https://github.com/erezlev13/watchnotch/releases/tag/v0.1.7)
- **Mac source on main** adds desktop reconnects, direct ChatGPT text replies, and actionable questions and approvals. The Mac guide covers setup, Accessibility access, demo sessions, local storage and verification. [Mac guide](mac/README.md)
- **Mac features in development** include a preview of the last assistant reply seen in an open pinned ChatGPT conversation, queued text follow-ups when the desktop composer offers **Queue**, multiline drafts and one screenshot per draft. Connected Codex threads can receive the caption and image together. ChatGPT uses a clipboard handoff for images. [Watch the feature film](https://erezlev13.github.io/watchnotch/#tour)
- **Windows source preview** runs with Python 3.9+ and Tkinter. It supports session discovery, activity, branches, account usage, Codex text replies and ChatGPT handoff. The Windows guide lists prerequisites and native verification status. [Windows guide](windows/README.md)

For provider behavior, connection options and verification details, see the [Codex adapter guide](mac/Adapters/Codex/README.md) and the [ChatGPT desktop guide](mac/Adapters/ChatGPT/README.md).
