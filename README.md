# watchnotch

![watchnotch owl](docs/media/owl-small.png)

**More AI sessions. Less switching.** WatchNotch is a productivity companion for **anyone juggling parallel AI conversations**, whether they are researching, writing, learning, planning, working on a business idea or coding. Follow selected sessions from a compact desktop strip, understand what needs your attention and jump directly back in. Every session keeps its own identity and context; related topics are never automatically merged.

The current public Mac preview centers on **Codex and ChatGPT**. The local development build adds **Claude Desktop and Claude Code**. Provider actions vary by integration and release: don't assume that every chat supports direct replies or approvals. The [build guide below](#choose-a-build) identifies the currently available features. Our [product vision and provider roadmap](docs/PRODUCT_VISION.md) covers the goal of supporting more AI tools globally, including Qwen, Kimi and DeepSeek.

| Platform | Start here |
| --- | --- |
| macOS | Build and open the Swift app from the [Mac directory](mac/README.md), or use the [Mac preview download](https://erezlev13.github.io/watchnotch/). |
| Windows | Launch the Python desktop preview with `py -3 windows\watchnotch.pyw`. See the [Windows setup and verification notes](windows/README.md). |

## Who it is for

- **Everyone using AI for productivity:** research, writing, travel planning, learning, shopping decisions, entrepreneurship and everyday projects.
- **People using more than one AI provider:** a unified place to see sessions while keeping each conversation independent. The global-provider support roadmap is not yet implemented.
- **Developers:** code agents and approvals are important workflows, but they are not the whole product.

See [our product vision, audience and future provider roadmap](docs/PRODUCT_VISION.md). The [WatchNotch Space](https://chatgpt.com/space/page_6b0170689bfc8191894b3d0655910426) stores the longer-term strategy, competitive research, naming alternatives and future integration workstreams.

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

The film shows example sessions from local preview `177379b`. These notes include the saved-job status update in tested revision `1f0dd9d`.

- **Claude Desktop and Claude Code on Mac and Windows.** Pin a private Claude Desktop chat link and hand off drafts with **Copy & open**. Mac Accessibility can report activity in open Claude Desktop chats. Claude Code uses the local CLI’s agent list and offers a command to attach to a background job or resume a session in its project terminal.
- **Session controls on Mac.** Use **+** to open a new Codex, ChatGPT or ChatGPT Work composer. **Automatically show active sessions** temporarily adds working or waiting threads alongside your pins. **End session** offers to archive a Codex thread. **Stop response** stops a supported desktop ChatGPT turn and keeps the conversation available.

For provider behavior, connection options and verification details, see the [Codex adapter guide](mac/Adapters/Codex/README.md) and the [ChatGPT desktop guide](mac/Adapters/ChatGPT/README.md).

## License

WatchNotch is open source under the [MIT License](LICENSE). Copyright © 2026 Erez Lev.
