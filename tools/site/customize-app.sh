#!/bin/sh
#
# Turns a packaged Reynard.app into a site app: one website full-screen, or a hub
# of several websites behind a switcher.
# Called by tools/release/create-ipa.sh when REYNARD_SITES is set.
#
# Environment:
#   REYNARD_SITES                websites, comma separated; each "https://a.example" or
#                                "Name=https://a.example" (required). More than one = hub.
#   REYNARD_SITE_NAME            name under the home-screen icon (default: first site's host)
#   REYNARD_SITE_HUB             "true": show the site switcher even for a single site
#   REYNARD_SITE_ALLOWED_HOSTS   extra hosts that stay in the app, comma separated (optional)
#   REYNARD_SITE_EXTERNAL_LINKS  "true" (default): links to other hosts open in Safari
#                                "false": every http(s) link stays in the app
#   REYNARD_SITE_ICONS_DIR       folder with app.png and <site id>.png from set-icon.py (optional)
#
# Usage: customize-app.sh path/to/Reynard.app

set -eu

APP_PATH="${1:?usage: customize-app.sh path/to/Reynard.app}"
INFO_PLIST="$APP_PATH/Info.plist"

SITES="${REYNARD_SITES:-${REYNARD_SITE_URL:-}}"
if [ -z "$SITES" ]; then
	echo "REYNARD_SITES is required" >&2
	exit 1
fi
SITE_COUNT="$(printf '%s\n' "$SITES" | tr ',;' '\n\n' | grep -c '[^[:space:]]' || true)"
FIRST_SITE="$(printf '%s\n' "$SITES" | tr ',;' '\n\n' | grep '[^[:space:]]' | head -n 1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
FIRST_HOST="$(printf '%s' "$FIRST_SITE" | sed -E 's#^[^=/?]*=##; s#^[[:space:]]*##; s#^[a-zA-Z]+://##; s#[/?#].*$##; s#:.*$##')"
SITE_NAME="${REYNARD_SITE_NAME:-$FIRST_HOST}"
ALLOWED_HOSTS="${REYNARD_SITE_ALLOWED_HOSTS:-}"
EXTERNAL_LINKS="${REYNARD_SITE_EXTERNAL_LINKS:-true}"
HUB="${REYNARD_SITE_HUB:-false}"
if [ "$SITE_COUNT" -gt 1 ]; then
	HUB=true
fi

case "$EXTERNAL_LINKS" in
	true|false) ;;
	*)
		echo "REYNARD_SITE_EXTERNAL_LINKS must be true or false (got: $EXTERNAL_LINKS)" >&2
		exit 1
		;;
esac

case "$HUB" in
	true|false) ;;
	*)
		echo "REYNARD_SITE_HUB must be true or false (got: $HUB)" >&2
		exit 1
		;;
esac

set_string() {
	plutil -replace "$1" -string "$2" "$INFO_PLIST"
}

set_string ReynardSites "$SITES"
set_string ReynardSiteAllowedHosts "$ALLOWED_HOSTS"
plutil -replace ReynardSiteOpenExternalLinksOutside -bool "$EXTERNAL_LINKS" "$INFO_PLIST"
plutil -replace ReynardSiteHub -bool "$HUB" "$INFO_PLIST"

set_string CFBundleDisplayName "$SITE_NAME"
set_string CFBundleName "$SITE_NAME"

# TrollStore registers apps as system apps; a system app that posts local
# notifications is expected to declare this key
plutil -replace SBAppUsesLocalNotifications -bool true "$INFO_PLIST"

# The site app should not claim reynard:// / http(s) links or Firefox add-on files
plutil -remove CFBundleURLTypes "$INFO_PLIST" 2>/dev/null || true
plutil -remove UTImportedTypeDeclarations "$INFO_PLIST" 2>/dev/null || true

# Permission prompts mention the app, not "this browser"
set_string NSCameraUsageDescription "$SITE_NAME uses the camera when the website asks for it."
set_string NSMicrophoneUsageDescription "$SITE_NAME uses the microphone when the website asks for it."
set_string NSLocationWhenInUseUsageDescription "$SITE_NAME uses your location when the website asks for it."
set_string NSPhotoLibraryUsageDescription "$SITE_NAME lets the website upload photos and videos you choose."
set_string NSPhotoLibraryAddUsageDescription "$SITE_NAME saves images you download from the website to Photos."
set_string NSBluetoothAlwaysUsageDescription "$SITE_NAME uses Bluetooth when the website asks for it."

# "Open in Reynard" share extension has no place in a single-site app
rm -rf "$APP_PATH/PlugIns/OpenIn.appex"

# Gecko accepts built-in extensions only from resource://app/extensions/readerview/
# (patches/mobile/shared/modules/geckoview/GeckoViewWebExtension.sys.mjs.patch).
# The site shell has no reader mode, so the site bridge takes that slot.
EXTENSIONS_DIR="$APP_PATH/Frameworks/GeckoView.framework/Frameworks/extensions"
if [ -d "$EXTENSIONS_DIR/site-bridge" ]; then
	rm -rf "$EXTENSIONS_DIR/readerview"
	mv "$EXTENSIONS_DIR/site-bridge" "$EXTENSIONS_DIR/readerview"
	echo "Site bridge installed in the readerview extension slot"
fi

# Icons the app shows itself: loading screen (app.png) and hub switcher (<site id>.png)
ICONS_DIR="${REYNARD_SITE_ICONS_DIR:-}"
if [ -n "$ICONS_DIR" ] && [ -d "$ICONS_DIR" ]; then
	rm -rf "$APP_PATH/SiteIcons"
	mkdir -p "$APP_PATH/SiteIcons"
	find "$ICONS_DIR" -maxdepth 1 -name '*.png' -exec cp {} "$APP_PATH/SiteIcons/" \;
	echo "Bundled icons: $(ls "$APP_PATH/SiteIcons" | tr '\n' ' ')"
fi

echo "Customized $(basename "$APP_PATH") for $SITES as \"$SITE_NAME\" (hub: $HUB)"
plutil -p "$INFO_PLIST" | grep -E 'CFBundle(Identifier|DisplayName|Name)|ReynardSite|SBAppUsesLocalNotifications' || true
