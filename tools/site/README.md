# Single-site apps (TrollStore)

Builds a TrollStore `.tipa` that opens one website full-screen on Gecko, with no browser UI.

## Build

GitHub → Actions → **Build Site App** → Run workflow:

| Input | Meaning |
|---|---|
| `site_url` | Start page, e.g. `https://example.com` |
| `app_name` | Name under the icon (default: the host) |
| `bundle_id` | Default: `site.<reversed host>`, e.g. `site.com.example`. Use a different one per app so apps don't overwrite each other |
| `allowed_hosts` | Extra hosts that stay inside the app, comma separated (login / payment domains such as `accounts.google.com`) |
| `external_links_in_safari` | `true`: links to other hosts open in Safari. `false`: everything stays in the app |
| `icon_url` | Icon image (default: the site's `apple-touch-icon`) |

The first run builds Gecko (hours) and caches it. Later runs reuse the cached engine and only rebuild the app (minutes),
until `engine/release.txt` or `patches/` change.

The result is the `<host>-TrollStore.tipa` artifact of the run. Install it with TrollStore. JIT is enabled automatically (ptrace).

## How it works

- `browser/Reynard/SiteMode/` – `SiteViewController` hosts one `GeckoSession`; `SceneDelegate` uses it whenever the
  app's Info.plist has `ReynardSiteURL`. Without that key the app is the normal Reynard browser.
- `tools/site/customize-app.sh` – writes the site keys, name and permission texts into the packaged app and drops the
  "Open in Reynard" extension. Called by `tools/release/create-ipa.sh` when `REYNARD_SITE_URL` is set.
- `tools/site/set-icon.py` – replaces `AppIcon.appiconset` before the Xcode build.
- `create-ipa.sh` reads `REYNARD_BUNDLE_ID` and rewrites the `application-identifier` entitlements to match.

In the app: edge swipe goes back, links to other hosts follow `external_links_in_safari`, `tel:`/`mailto:`/app links
open their apps, `target=_blank` and `window.open` stay in the same window, and downloads are not supported.
