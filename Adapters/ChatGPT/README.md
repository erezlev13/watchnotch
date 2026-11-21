# ChatGPT desktop

A private conversation URL can be added as a session in the companion. Select the session in the companion’s picker to pin it. Its **Jump in** action checks for a matching open window or app-associated link before opening the conversation URL in the default browser. Automatic updates, results, and approval controls are unavailable for these saved links.

## Add a conversation

Copy the address of a conversation you own from ChatGPT's web address bar. Use a direct URL of the form `https://chatgpt.com/c/<UUID>`. A title is stored locally. From the project root, run the following command with that address and your chosen title.

```sh
python3 Adapters/ChatGPT/register.py 'https://chatgpt.com/c/<UUID>' --title 'Market research'
```

The helper canonicalizes the UUID, discards the query and fragment, and atomically writes one private JSON file in `~/Library/Application Support/Mac Notch Session Companion/Sessions`. Set `NOTCH_SESSION_DIR` to use a separate test directory. Registering the same link with a new title renames that session. Reusing the same title for two different links keeps the sessions independent. The helper runs locally and never fetches the link. Conversation access when opening it depends on the signed-in account. The external HTTPS handler can open a browser.

Ordinary chats and cloud Work chats sync across surfaces. A desktop-local Work task may lack a corresponding web conversation URL. Use the originating desktop chat for those tasks. A public share link is a separate snapshot and is rejected by this adapter. [ChatGPT Work and Codex](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)

## Verification on this Mac

Tested on macOS 26.5.2 with ChatGPT desktop 26.1117.41037. The installed app is `/Applications/ChatGPT.app`, bundle identifier `com.openai.codex`. Its declared URL schemes include `codex`, `http`, and `https`. This declaration alone does not prove a route to a particular desktop task.

| Capability | Chat | Work | Evidence |
| --- | --- | --- | --- |
| Stable identity and local title | Direct conversation URL and manual title | Same for a cloud task with a direct URL | Two distinct synthetic UUIDs with matching titles produced two records. Reimporting one with a different title updated that record only. |
| Open source session | Direct HTTPS link | Direct HTTPS link when available | Canonical URL verified in generated snapshot. Actual private conversation reopening requires the owning account and was not exercised. |
| Discover title, progress or result | Unverified | Unverified | Desktop Accessibility trust check returned false both in the sandbox and in the approved desktop context. |
| Track multiple native chats across app switches | Unverified | Unverified | Saved links persist independently. Native background changes could not be observed through Accessibility. |
| Deliver a decision to an exact request | Unavailable | Unverified | No documented external request/response mechanism identified for this surface. The adapter emits no request or decision controls. |

The official integration guides describe using ChatGPT to access a selected application's content, and the desktop interface for Chat and Work. Neither guide documents a third-party subscription to individual Chat or Work session events. This is a conclusion about the interfaces checked for this prototype. [Work with Apps](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos) · [ChatGPT Work and Codex](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)

## Reproduce

From this directory, run the following commands.

```sh
python3 -B -m unittest -v
swift -module-cache-path /private/tmp/notch-chatgpt-swift-cache AXProbe.swift
```

The two importer tests passed. They cover deduplication, renaming, independent identities, link validation, unavailable status, and private file permissions. The probe printed `Accessibility granted to this process: false` and exited with code 2. It makes no permission request. With an existing grant, it reports ChatGPT window counts and available metadata attribute names without reading titles, text, or conversation identifiers.

For a native follow-up, use a test account with one synthetic Chat and one synthetic Work session. Give each a unique title, record its direct URL if available, and check the reopened session against that title. While a task is running, switch to another app and compare distinct per-session events against the source. A visible window title alone is insufficient to prove background updates. Exercise a benign Work approval only if the source exposes both a stable session ID and a stable pending request ID. Record cancellation, resolution, and duplicate delivery before enabling any external action.

The adapter's current shipping decision is to support saving and opening a user-supplied conversation link. Tracking a native chat, extracting a final result, and replying to Work requests remain unverified.
