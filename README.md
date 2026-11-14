# Reynard Site Apps

Full-screen iPhone apps for websites, running on **Gecko** (the Firefox engine) instead of the WebKit that ships with iOS.
Built on [Reynard](https://github.com/minh-ton/reynard-browser) and installed with
[TrollStore](https://github.com/opa334/TrollStore).

It exists for one situation: your iPhone's iOS is too old for a service's own app, and too old for Safari's engine to
run the service's website. Gecko is bundled with the app, so the site gets a current engine on an old iOS.

Two kinds of app come out of the same code:

- **Single-site app** – one website, full screen, with its own icon and name. Example: Claude.
- **Hub** – several websites in one app behind a bottom switcher. Example: Claude, ChatGPT and Z.ai. More sites can be
  added on the device.

> [!NOTE]
> These are unofficial wrappers. They load the real websites and are not made by, endorsed by or affiliated with
> Anthropic, OpenAI, Z.ai, Mozilla or anyone else whose site you open in them. Names and icons belong to their owners.

## Status

Experimental. This is what has been confirmed on a real device so far (iPhone, iOS 16.2, TrollStore); treat
everything else on this page as built but untested:

| | State |
|---|---|
| Install, launch, sign in, chat (single-site app, claude.ai) | Confirmed |
| Hub, loading screen, "return to where you were" | Built, not yet confirmed |
| Notifications when a response is ready | Built, not yet confirmed |
| ChatGPT and Z.ai inside the hub | Built, not yet confirmed |

Battery use and heat are higher than Safari; that comes with Reynard's engine port (see its
[FAQ](https://github.com/minh-ton/reynard-browser/issues/130)).

## What the apps do

- **No browser UI.** Full screen, status bar tinted to the page, edge swipe to go back.
- **Loading screen** with the app's icon instead of a progress bar.
- **Sign-in** stays inside the app, including Google, Apple and Microsoft sign-in windows.
- **Keyboard** pushes the page up so the message box stays visible.
- **Uploads, camera and microphone** through the normal iOS prompts.
- **Downloads** open the share sheet (Save to Files).
- **Links to other websites** that a site opens in a new window go to Safari.
- **Returns to where you were** when reopened within 30 minutes.
- **Notifications** when a response is ready while you are in another app (or, in a hub, in another site):
  - the app notices when a chat site finishes writing a response;
  - a site's own web notifications (`Notification` API) are delivered through iOS as well;
  - by default the app behaves like any other app: iOS freezes it shortly after you leave, so only a response that
    finishes within that short time is announced. An option in the app menu keeps the app awake in the background
    (up to 15 minutes) while a response is still being written, at the cost of battery.
- **Recovers on return.** If iOS closed or froze the page while the app was away, the page is reloaded
  automatically; a page that keeps closing gets a "try again / start page" choice instead of a blank screen.
- **Hub:** switcher with site icons, "+" to add a site, long-press a site to reload it, return to its start page or
  remove it. The most recently used sites stay loaded; older ones reload when selected.
- **App menu:** long-press with two fingers for Start page, Reload, and a status sheet for notifications.

## Install a prebuilt app

Requires TrollStore (iOS 14 – 16.6.1, or 17.0). Open the link on the iPhone and install the file with TrollStore.
JIT is enabled automatically.

| App | Download |
|---|---|
| Claude (claude.ai) | [`claude.ai-TrollStore.tipa`](https://github.com/dovi20/reynard-browser/releases/download/app-claude.ai/claude.ai-TrollStore.tipa) |
| AI Hub (Claude, ChatGPT, Z.ai) | [`ai-hub-TrollStore.tipa`](https://github.com/dovi20/reynard-browser/releases/download/app-ai-hub/ai-hub-TrollStore.tipa) |

Each app has its own bundle ID and data, so they install side by side. An update installs over the previous version.

## Build your own app

No Mac needed; GitHub builds it.

1. Fork this repository and open the **Actions** tab of your fork. GitHub disables workflows on new forks; enable them.
2. Choose **Build Site App** → **Run workflow** and fill in:

   | Input | Meaning |
   |---|---|
   | `site_url` | One address (`https://example.com`) for a single-site app. Several, comma separated, for a hub; each can carry a name: `Claude=https://claude.ai, ChatGPT=https://chatgpt.com` |
   | `app_name` | Name under the icon (default: the site's host, or "AI Hub" for a hub) |
   | `bundle_id` | Default: `site.<reversed host>`, or `site.hub.<name>` for a hub |
   | `allowed_hosts` | Extra hosts that should stay inside the app, comma separated |
   | `external_links_in_safari` | Off: links to other websites stay in the app |
   | `icon_url` | App icon image (default: the site's own icon; a generated icon for a hub) |

3. Download the result from your fork's **Releases**: `app-<name>` → `<name>-TrollStore.tipa`.

The first run in a fork builds the Gecko engine, which takes several hours and can hit GitHub's 6-hour limit; if it
does, run the workflow again and it continues from the cached compile results. After that the engine is reused and a
build takes about 10 minutes. Builds in a public fork do not use up your Actions minutes.

## Notifications on TrollStore

TrollStore registers apps as system apps. iOS does not show its "allow notifications" alert for those, so the app asks
the question itself on first launch, and a site that wants to send notifications gets its own in-app question.
If nothing arrives, open the app menu → **Notifications and status**: it shows what iOS reports and can send a test
notification. Notification settings for the app are under Settings → Notifications.

## How it works

Reynard already contains the hard part: Gecko running on iOS, with a Swift wrapper (`GeckoView`). This project adds a
second front end next to Reynard's browser UI. When the app's `Info.plist` lists websites, the app starts the site
front end instead of the browser:

- `browser/Reynard/SiteMode/` – the site front end (root, one controller per site, loading screen, notifications).
- `browser/SiteExtensions/site-bridge/` – a built-in WebExtension that reports when a site finishes a response and
  provides the web `Notification` API.
- `tools/site/` – packaging: icon, site list, name and bundle ID are written into the built app.
- `.github/workflows/build-site.yml` – the build described above.

Details for contributors are in [`tools/site/README.md`](tools/site/README.md). Everything else in the repository is
Reynard; its own documentation is in [`README.reynard.md`](README.reynard.md).

## Limitations

- TrollStore only. Gecko on iOS needs entitlements that the App Store and ordinary sideloading do not grant.
- No push notifications. A notification can only be posted while the app is still alive in the background.
- Response detection is tuned for Claude, ChatGPT and Z.ai; other sites are detected only when they stream answers
  as an event stream.
- Whether a given website works depends on Reynard's engine port.

## Credits and license

- [Reynard](https://github.com/minh-ton/reynard-browser) by Minh Ton – the Gecko port and browser this is built on.
- [Gecko / Firefox](https://github.com/mozilla-firefox/firefox) by Mozilla.
- [TrollStore](https://github.com/opa334/TrollStore) by opa334.

Like Reynard, this project is licensed under [GPL-3.0](LICENSE); the engine patches in `patches/` are under
[MPL-2.0](LICENSE.firefox). If you distribute an app built from it, the GPL requires you to make your source available.
