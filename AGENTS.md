# WatchNotch integration

The published source is `erezlev13/watchnotch` on `main`. Mac code lives in `mac/`, Windows code in `windows/`, shared adapters in `shared/`, and the website in `docs/`.

Use feature worktrees for changes. Hand the integration owner a tested commit hash and any verification limits. The shared local preview comes from `integration/local-preview`. The integration owner combines the commits there, runs both platform suites, and installs the signed Mac preview at `~/Applications/watchnotch.app`. Coordinate any change of installer with the other active WatchNotch threads.

Run feature UI checks with disposable app data and quit those instances when finished. Use the installed copy for user testing. Sign its updates with the same Apple Development identity so macOS can recognize its existing permissions. Use `mac/scripts/install-preview` from the clean integration checkout to update the canonical app. The Desktop shortcut points there. Inspect the installed revision with `/usr/bin/plutil -extract WatchNotchSourceRevision raw ~/Applications/watchnotch.app/Contents/Info.plist`.

The website owner uses release tags for download claims and the tested integration revision for local-preview claims.
