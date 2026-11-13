#!/bin/sh
#
# Turns a packaged Reynard.app into a single-site app.
# Called by tools/release/create-ipa.sh when REYNARD_SITE_URL is set.
#
# Environment:
#   REYNARD_SITE_URL             start page, e.g. https://example.com (required)
#   REYNARD_SITE_NAME            name under the home-screen icon (default: site host)
#   REYNARD_SITE_ALLOWED_HOSTS   extra hosts that stay in the app, comma separated (optional)
#   REYNARD_SITE_EXTERNAL_LINKS  "true" (default): links to other hosts open in Safari
#                                "false": every http(s) link stays in the app
#
# Usage: customize-app.sh path/to/Reynard.app

set -eu

APP_PATH="${1:?usage: customize-app.sh path/to/Reynard.app}"
INFO_PLIST="$APP_PATH/Info.plist"

SITE_URL="${REYNARD_SITE_URL:?REYNARD_SITE_URL is required}"
SITE_HOST="$(printf '%s' "$SITE_URL" | sed -E 's#^[a-zA-Z]+://##; s#[/?#].*$##; s#:.*$##')"
SITE_NAME="${REYNARD_SITE_NAME:-$SITE_HOST}"
ALLOWED_HOSTS="${REYNARD_SITE_ALLOWED_HOSTS:-}"
EXTERNAL_LINKS="${REYNARD_SITE_EXTERNAL_LINKS:-true}"

case "$SITE_URL" in
	http://*|https://*) ;;
	*)
		echo "REYNARD_SITE_URL must start with http:// or https:// (got: $SITE_URL)" >&2
		exit 1
		;;
esac

case "$EXTERNAL_LINKS" in
	true|false) ;;
	*)
		echo "REYNARD_SITE_EXTERNAL_LINKS must be true or false (got: $EXTERNAL_LINKS)" >&2
		exit 1
		;;
esac

set_string() {
	plutil -replace "$1" -string "$2" "$INFO_PLIST"
}

set_string ReynardSiteURL "$SITE_URL"
set_string ReynardSiteAllowedHosts "$ALLOWED_HOSTS"
plutil -replace ReynardSiteOpenExternalLinksOutside -bool "$EXTERNAL_LINKS" "$INFO_PLIST"

set_string CFBundleDisplayName "$SITE_NAME"
set_string CFBundleName "$SITE_NAME"

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
if [ -d "$EXTENSIONS_DIR/claude-bridge" ]; then
	rm -rf "$EXTENSIONS_DIR/readerview"
	mv "$EXTENSIONS_DIR/claude-bridge" "$EXTENSIONS_DIR/readerview"
	echo "Site bridge installed in the readerview extension slot"
fi

echo "Customized $(basename "$APP_PATH") for $SITE_URL as \"$SITE_NAME\""
plutil -p "$INFO_PLIST" | grep -E 'CFBundle(Identifier|DisplayName|Name)|ReynardSite' || true
