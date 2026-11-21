# ChatGPT desktop

Pin a conversation from the session library or paste a private ChatGPT conversation URL. The library checks the local desktop catalog for conversation IDs, titles, dates and reported activity. Recent active-turn records can surface a Work conversation before its title arrives. Pinned conversations refresh in the background. The tile can show statuses such as “Writing a response,” “Working in the background” and “A new response is ready.” The catalog supplies activity metadata only.

Type a follow-up below **Jump in**. **Copy & open** places that tile’s draft on the clipboard and opens the conversation for you to paste and send. **Jump in** tries to select the chat in the running desktop app. The globe button opens its private URL in your browser.

**Find on this Mac** looks for visited conversation links in readable Safari, Chrome, Edge, Brave, Arc, Dia, Chromium, Firefox and desktop browser histories on request. You can also import a ChatGPT export ZIP or conversations JSON file. The picker retains titles, IDs and dates. Live status becomes available when the matching conversation appears in the desktop activity source. [Export instructions](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data)

## Add a conversation

Copy the address of a conversation you own from ChatGPT's web address bar. Use a direct URL of the form `https://chatgpt.com/c/<UUID>`. A title is stored locally. From the `mac/` directory, run the following command with that address and your chosen title.

```sh
python3 Adapters/ChatGPT/register.py 'https://chatgpt.com/c/<UUID>' --title 'Market research'
```

The helper canonicalizes the UUID, discards the query and fragment, and atomically writes one private JSON file in `~/Library/Application Support/Mac Notch Session Companion/Sessions`. Set `NOTCH_SESSION_DIR` to use a separate test directory. Registering the same link with a new title renames that session. Reusing the same title for two different links keeps the sessions independent. The helper runs locally and never fetches the link. Conversation access when opening it depends on the signed-in account. The external HTTPS handler can open a browser.

Ordinary chats and cloud Work chats sync across surfaces. A desktop-local Work task may lack a corresponding web conversation URL. Use the originating desktop chat for those tasks. A public share link is a separate snapshot and is rejected by this adapter. [ChatGPT Work and Codex](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)

## Verification on this Mac

Tested on macOS 26.5.2 with ChatGPT desktop 26.1117.41037. The installed app is `/Applications/ChatGPT.app`, bundle identifier `com.openai.codex`. The catalog reported that a pinned Work conversation was writing a response. Synthetic imports covered separate IDs with the same title, renames and private file permissions. **Jump in** uses macOS window and navigation metadata to identify a conversation in the running app. macOS may ask for Accessibility permission. The ChatGPT catalog does not supply message bodies or actionable approval requests.

The official integration guides describe using ChatGPT to access a selected application's content, and the desktop interface for Chat and Work. Neither guide documents a third-party subscription to individual Chat or Work session events. This is a conclusion about the interfaces checked for this prototype. [Work with Apps](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos) · [ChatGPT Work and Codex](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)

## Reproduce

From this directory, run the following commands.

```sh
python3 -B -m unittest -v
swift -module-cache-path /private/tmp/notch-chatgpt-swift-cache AXProbe.swift
```

The tests exercise desktop metadata, browser and export imports, link validation, deduplication and private file permissions. The optional Accessibility probe reports the permission state and available window metadata.
