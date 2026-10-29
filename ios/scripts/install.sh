#!/usr/bin/env bash
# Sign your own DSH Duo, install it on your iPhone, and give this Mac's dsh plugin
# the matching Apple push key so it can notify the phone while the app is closed.
#
#   ios/scripts/install.sh [--team ID] [--bundle-id ID] [--device UDID]
#                          [--apns-key AuthKey_XXXXXXXXXX.p8 [--apns-key-id XXXXXXXXXX]]
#                          [--no-install]
#
#   --team        Apple Developer Team ID (default: the first team signed in to Xcode)
#   --bundle-id   App bundle ID (default: ai.deepseek.harness.duo.<team id, lowercased>)
#   --device      iPhone UDID (default: the first connected, available iPhone)
#   --apns-key    APNs auth key from developer.apple.com > Keys (enables push from this Mac)
#   --apns-key-id Its 10-character Key ID (default: taken from the AuthKey_<ID>.p8 file name)
#   --no-install  Build and sign only
#
# Push credentials stay on this Mac in $DSH_HOME/duo-remote/ (mode 0600); the shared
# relay never sees them.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
team="" bundle="" device="" apns_key="" apns_key_id="" install=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --team) team=$2; shift 2 ;;
    --bundle-id) bundle=$2; shift 2 ;;
    --device) device=$2; shift 2 ;;
    --apns-key) apns_key=$2; shift 2 ;;
    --apns-key-id) apns_key_id=$2; shift 2 ;;
    --no-install) install=0; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [[ -z $team ]]; then
  team=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -n 's/.*teamID = \([A-Z0-9]\{10\}\);.*/\1/p' | head -1)
  [[ -n $team ]] || { echo "No team found. Sign in to Xcode (Settings > Accounts) or pass --team." >&2; exit 1; }
fi
bundle=${bundle:-ai.deepseek.harness.duo.$(tr '[:upper:]' '[:lower:]' <<<"$team")}
echo "Team $team, bundle $bundle"

if [[ -n $apns_key ]]; then
  [[ -f $apns_key ]] && grep -q "BEGIN PRIVATE KEY" "$apns_key" || { echo "$apns_key is not a .p8 key" >&2; exit 1; }
  apns_key_id=${apns_key_id:-$(basename "$apns_key" | sed -n 's/^AuthKey_\([A-Z0-9]\{10\}\)\.p8$/\1/p')}
  [[ $apns_key_id =~ ^[A-Z0-9]{10}$ ]] || { echo "Pass --apns-key-id (10 characters)." >&2; exit 1; }
fi

build="$here/build"
archive="$build/DSHDuo.xcarchive"
rm -rf "$archive"
echo "Archiving and signing…"
xcodebuild -project "$here/DSHDuo.xcodeproj" -scheme DSHDuo -configuration Release \
  -destination generic/platform=iOS -archivePath "$archive" \
  DEVELOPMENT_TEAM="$team" DSH_BUNDLE_ID="$bundle" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -quiet archive

cat > "$build/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$build/export" \
  -exportOptionsPlist "$build/ExportOptions.plist" -allowProvisioningUpdates -quiet
ipa=$(ls "$build"/export/*.ipa)
echo "Signed: $ipa"

if [[ -n $apns_key ]]; then
  dir="${DSH_HOME:-$HOME/.dsh}/duo-remote"
  mkdir -p "$dir" && chmod 700 "$dir"
  install -m 600 "$apns_key" "$dir/AuthKey_$apns_key_id.p8"
  umask 077
  printf '{\n  "keyId": "%s",\n  "teamId": "%s",\n  "keyFile": "AuthKey_%s.p8",\n  "topic": "%s"\n}\n' \
    "$apns_key_id" "$team" "$apns_key_id" "$bundle" > "$dir/apns.json"
  echo "Push: wrote $dir/apns.json. Restart dsh to send notifications to this app."
else
  echo "Push: skipped (no --apns-key). Notifications still work while the app is open."
fi

[[ $install == 1 ]] || exit 0
if [[ -z $device ]]; then
  json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null
  device=$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("deviceType") == "iPhone" and cp.get("tunnelState") != "unavailable":
        print(hw["udid"]); break' "$json")
  rm -f "$json"
  [[ -n $device ]] || { echo "No iPhone connected. Plug it in, unlock it, or pass --device." >&2; exit 1; }
fi
echo "Installing on ${device}…"
xcrun devicectl device install app --device "$device" "$archive/Products/Applications/DSHDuo.app"
if xcrun devicectl device process launch --device "$device" "$bundle" >/dev/null 2>&1; then
  echo "Launched DSH Duo."
else
  echo "Installed. Unlock the iPhone and open DSH Duo."
fi
