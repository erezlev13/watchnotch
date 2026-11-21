# Product vision: AI sessions for everyone

> **Core promise:** Keep all your AI sessions in sight, whatever you are working on and whichever provider you prefer. **More AI sessions. Less switching.**

WatchNotch is a productivity companion for **anyone using multiple AI conversations or agents in parallel**, not a developer-only coding monitor. Developers are one important audience, but never the entire target market. The core problem is losing track of independent conversations across apps, tasks and windows—not writing code.

## Who this is for

- **Researchers and students:** compare sources, follow longer investigations, learn subjects and resume study sessions.
- **Creators and writers:** juggle drafts, idea exploration and feedback.
- **Entrepreneurs and professionals:** follow market research, planning, documents and business workflows.
- **People organizing everyday life:** keep travel, shopping decisions, hobbies and personal plans moving.
- **Developers:** watch coding agents, tasks, questions and approvals alongside everything else.

These are intended **use cases**, not a claim that every provider or workflow is fully automated today.

## Product principles

1. **Broad by design.** Use plain-language copy and onboarding; avoid assuming terminal commands, programming, or knowledge of coding agents.
2. **Provider-agnostic.** A consistent session card and capability-based UI works across tools from any region. We aim to support Chinese AI harnesses and models as well as American and European providers.
3. **Parallel sessions, not one merged chat.** Pin up to five existing sessions and keep each session's identity, context, title and draft independent—even when multiple sessions discuss the same topic.
4. **Status at a glance.** Show what is running, what needs input, what finished, and when it last changed. Favor an understandable one-sentence update.
5. **Act only when verified.** Open the right source session; where official or permission-safe interfaces allow, reply or approve directly. Never fake actions or imply support that does not exist.
6. **Respect privacy and user control.** Opt-in connections; prefer local read-only monitoring; protect session data and credentials; don't silently merge or transmit conversation content.

## Clear positioning

**Headline:** More AI sessions. Less switching.

**One sentence:** Keep up with your research, writing, planning and coding conversations from one small companion on your desktop.

**Supporting line:** Follow what changed, see what needs you, and jump back into the right session—without hunting through windows.

**Avoid:** "A Mac notch for Claude Code," "AI coding agent dashboard," "for developers," or "works with every AI" (until true). Notch is currently the interface; productivity across parallel sessions is the long-term product value.

## Delivery reality vs roadmap

| Layer | Current documented behavior | Direction |
| --- | --- | --- |
| Codex | Mac preview monitors local threads; some actions available by build | Reliable status, replies, decisions and handoff |
| ChatGPT Chat and Work | Mac preview pins sessions, opens them, and supports selected source-build interactions | Robust general-purpose conversations first class |
| Claude Desktop and Claude Code | Local development support; actions and verification vary | Complete lifecycle and handoff where available |
| Windows | Separate Python preview with a narrower feature set | Consistent cross-platform experience |
| Qwen Code and Kimi Code CLI | Not integrated | Feasibility study and read-only adapters |
| MiniMax Code, DeepSeek Harness, ZCode/GLM, TRAE, Qoder | Not integrated | Evaluate official session/hook interfaces |
| Qwen Chat, Kimi Chat, DeepSeek Chat and other consumer apps | Not integrated | Explore permission-safe existing-session access |

**Important technical distinction:** A *harness/app adapter* monitors existing conversation sessions; a *model integration* calls a model to start a new session. Supporting DeepSeek/Qwen/Kimi as models alone does not let us observe conversations inside their apps. Treat harness and model identity separately and show per-provider capabilities. See [Global AI Provider & Chinese Harness Support](https://chatgpt.com/space/page_b488179cfd5881918f6873392f26c35f).

## Market and differentiation research

The broad "AI in the Mac notch" space is competitive. The working estimate of 10–20 relatively close alternatives is directional rather than verified market size. Review [Cowork Island](https://coworkisland.com), [Super Notch](https://www.supernotch.ai), [Perch](https://perchapp.dev), [NotchDeck](https://www.notchdeck.app), [Coucou](https://github.com/Louis-CFM/coucou) and [KIKUmap](https://github.com/tang1693/KIKUmap). Differentiate on reliable **mixed-purpose conversations**, clear nontechnical UX and trustworthy cross-provider coverage—not notch visuals alone. Full [Space strategy and naming notes](https://chatgpt.com/space/page_7113521c10288191869b330f14c9ff3d).

## Validation and follow-up

- Run hands-on feature and reliability tests with direct competitors.
- Test the landing page with at least one person who does not code: can they describe its value in a sentence?
- Measure time saved from switching windows, session connect success, status latency, correct-session navigation, and usefulness after a week.
- Maintain a provider capability matrix; make Qwen Code and Kimi Code CLI the first Chinese-origin harness spike.
- Test the name **WatchNotch** against alternatives such as SessionNest, ThreadNest and OwlDesk. No rebrand until availability, trademark and customer comprehension have been investigated.
- Track work in the repository's [GitHub issues](https://github.com/erezlev13/watchnotch/issues). The product strategy and workstream live in the [WatchNotch Space](https://chatgpt.com/space/page_6b0170689bfc8191894b3d0655910426).

## GitHub follow-up tracker

These issues make the discussion actionable; they are **planned work, not shipped features**.

1. **Audience-first UX and user testing:** [#10](https://github.com/erezlev13/watchnotch/issues/10) — highest priority.
2. **Competitor comparison and differentiation:** [#11](https://github.com/erezlev13/watchnotch/issues/11).
3. **Provider-neutral session architecture:** [#12](https://github.com/erezlev13/watchnotch/issues/12).
4. **Qwen and Kimi CLI adapter POC:** [#13](https://github.com/erezlev13/watchnotch/issues/13).
5. **MiniMax/DeepSeek/ZCode/TRAE/Qoder research:** [#14](https://github.com/erezlev13/watchnotch/issues/14).
6. **Ordinary consumer AI chat interoperability:** [#15](https://github.com/erezlev13/watchnotch/issues/15).
7. **Name and branding research:** [#16](https://github.com/erezlev13/watchnotch/issues/16).
8. **Mixed-purpose end-to-end demo and metrics:** [#17](https://github.com/erezlev13/watchnotch/issues/17).
