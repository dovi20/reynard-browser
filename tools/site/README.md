# Site apps: technical notes

What the project is and how to use it is in the [main README](../../README.md). This page is for working on the code.

Builds a TrollStore `.tipa` that opens websites full-screen on Gecko, with no browser UI:

- **Single-site app** – one website (for example Claude).
- **Hub** – several websites behind a bottom switcher (for example Claude, ChatGPT and Z.ai). More sites can be
  added on the device with the "+" button.

Each build is its own app with its own bundle ID, sign-ins and data, so a single-site app and a hub can be installed
side by side.

## Build

GitHub → Actions → **Build Site App** → Run workflow:

| Input | Meaning |
|---|---|
| `site_url` | One address (`https://claude.ai`) for a single-site app. Several, comma separated, for a hub; each can carry a name: `Claude=https://claude.ai, ChatGPT=https://chatgpt.com, Z.ai=https://chat.z.ai` |
| `app_name` | Name under the icon (default: the host, or "AI Hub" for a hub) |
| `bundle_id` | Default: `site.<reversed host>` (e.g. `site.ai.claude`), or `site.hub.<name>` for a hub. Use a different one per app so apps don't overwrite each other |
| `allowed_hosts` | Extra hosts that stay inside the app, comma separated |
| `external_links_in_safari` | `true`: links that open a new window to other hosts go to Safari. `false`: everything stays in the app |
| `icon_url` | App icon image (default: the site's `apple-touch-icon`; a generated icon for a hub) |

The first run builds Gecko (hours) and keeps it both in the Actions cache and as a release asset (`engine-<hash>`).
Later runs reuse it and only rebuild the app (about 10 minutes), until `engine/release.txt` or `patches/` change.

The result is published at a fixed link: `releases/download/app-<name>/<name>-TrollStore.tipa`
(`app-claude.ai/claude.ai-TrollStore.tipa`, `app-ai-hub/ai-hub-TrollStore.tipa`). Install it with TrollStore.
JIT is enabled automatically (ptrace).

## How it works

- `browser/Reynard/SiteMode/`
  - `SiteConfiguration.swift` – the sites from Info.plist (`ReynardSites`) plus sites added on the device.
  - `SiteRootViewController.swift` – root of the app; hosts one `SiteViewController` per site and the hub switcher.
    `SceneDelegate` uses it whenever Info.plist lists sites. Without them the app is the normal Reynard browser.
  - `SiteViewController.swift` – one site: Gecko session, loading screen, keyboard, errors, popups, downloads.
  - `SiteActivityCenter.swift` – background keep-alive and "response finished" notifications.
- `browser/SiteExtensions/site-bridge/` – built-in extension: `content.js` and `background.js` report when a site
  starts and finishes writing a response; `notifications.js` replaces `window.Notification` in the page (Gecko on iOS
  has no backend for it) and hands the site's notifications to the app. Copied into the app by `browser/Scripts/AddGecko.sh`. Gecko only accepts built-in extensions from
  `resource://app/extensions/readerview/`, so `customize-app.sh` moves the bridge into that folder (site apps have
  no reader mode). Gecko reinstalls it only when the manifest `version` changes, so bump it with every change.
- `tools/site/set-icon.py` – sets `AppIcon.appiconset` before the Xcode build and exports the icons the app shows
  itself (loading screen, switcher).
- `tools/site/customize-app.sh` – writes the site keys, name and permission texts into the packaged app, bundles the
  icons, and drops the "Open in Reynard" extension. Called by `tools/release/create-ipa.sh` when `REYNARD_SITES` is set.
- `create-ipa.sh` reads `REYNARD_BUNDLE_ID` and rewrites the `application-identifier` entitlements to match.

## In the app

- Loading shows the icon and a spinner until the site has painted; there is no progress line.
- Edge swipe goes back. Navigations of the page itself stay in the app (sign-in flows); links that open a new window
  go to Safari, except sign-in pages (Google, Apple, Microsoft), which open in a full-screen popup that keeps the opener.
- Downloads open the share sheet (Save to Files).
- Reopening within 30 minutes returns to the page the site was on; later it starts at the site's start page.
- While a site is writing a response and the app goes to the background, the app keeps itself alive (silent audio,
  up to 15 minutes) and posts a local notification when the response is done. Detection: a known chat request
  (Claude, ChatGPT, Z.ai) or, on other sites, a POST answered with an event stream.
- TrollStore registers apps as system apps. iOS shows no "allow notifications" alert for those, and TrollStore's
  author points to the Info.plist key `SBAppUsesLocalNotifications` for system apps that post local notifications
  (set by `customize-app.sh`; not yet confirmed to be what was missing).
  The app therefore asks its own question on first launch, and shows an in-app question when a site calls
  `Notification.requestPermission()`. A site notification and the app's own "response finished" notification for
  the same site within 8 seconds count as one.
- **App menu**: long-press with two fingers anywhere (in a hub also: long-press a site in the switcher) for Start page,
  Reload, and "Notifications and status", which shows what the app knows (permission, bridge extension, last event)
  and can send a test notification.
- **Hub**: the switcher keeps the two or three most recently used sites loaded (by device memory) and reloads older
  ones when selected; a site that is still writing a response is not unloaded.
