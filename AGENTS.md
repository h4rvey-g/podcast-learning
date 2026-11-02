# Agent notes

Read `README.md` for app architecture, build/test commands, and signing setup. The backend runs on-device; there is no server to deploy.

## Install on an iPhone through LiveContainer

Use this route when standalone installation is blocked by the free-developer three-app limit. Keep the phone paired, unlocked, and connected by USB. LiveContainer must already be installed with working guest-app signing.

Discover the phone with `xcrun devicectl list devices`. If the LiveContainer bundle ID changes, find it with `xcrun devicectl device info apps --device "$DEVICE_ID" --search LiveContainer`.

Run from the repository root. Replace the phone UDID; the other defaults below are the current working signing/bundle IDs and can be overridden for another account:

```bash
export DEVICE_ID='<connected iPhone UDID>'
export TEAM_ID='Y77KRPY77N'
export LC_BUNDLE_ID='com.kdt.livecontainer.Y77KRPY77N'
export APP_BUNDLE_ID='com.howieguo8.PodcastLearning'

(
  set -eu
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/podcast-livecontainer.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p build "$WORK/Payload"
  printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' > "$WORK/Local.entitlements"

  # Local-only guest build; keep the repository's normal entitlements unchanged.
  # Disable the debug-dylib trampoline so LiveContainer gets a standalone executable.
  xcodebuild -project PodcastLearning.xcodeproj -scheme PodcastLearning \
    -configuration Release -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath DerivedData -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" APP_BUNDLE_ID="$APP_BUNDLE_ID" \
    CODE_SIGN_ENTITLEMENTS="$WORK/Local.entitlements" APP_GROUP_ID= \
    ENABLE_CLOUD_SYNC=NO ENABLE_DEBUG_DYLIB=NO build \
    > build/livecontainer-build.log 2>&1

  ditto DerivedData/Build/Products/Release-iphoneos/PodcastLearning.app \
    "$WORK/Payload/PodcastLearning.app"
  # LiveContainer cannot register guest extensions. Remove only the staged copy.
  rm -rf "$WORK/Payload/PodcastLearning.app/PlugIns"
  ditto -c -k --norsrc --noextattr --noqtn --keepParent \
    "$WORK/Payload" build/PodcastLearning-LiveContainer.ipa

  xcrun devicectl device copy to --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$LC_BUNDLE_ID" \
    --source build/PodcastLearning-LiveContainer.ipa \
    --destination Documents/PodcastLearning-LiveContainer.ipa

  # Container UUIDs change after reinstalls: resolve the current path every time.
  xcrun devicectl device info apps --device "$DEVICE_ID" \
    --bundle-id "$LC_BUNDLE_ID" --include-container-paths \
    --json-output "$WORK/livecontainer.json"
  IMPORT_URL=$(python3 - "$WORK/livecontainer.json" <<'PY'
import json
import sys
from pathlib import Path

apps = json.loads(Path(sys.argv[1]).read_text())["result"]["apps"]
assert len(apps) == 1 and apps[0].get("containerAccessible"), "LiveContainer data container is unavailable"
print((Path(apps[0]["dataContainerPath"]) / "Documents/PodcastLearning-LiveContainer.ipa").as_uri())
PY
  )
  xcrun devicectl device process launch --device "$DEVICE_ID" \
    --payload-url "$IMPORT_URL" "$LC_BUNDLE_ID"
)
```

**Verify:** wait for LiveContainer to finish importing and show **Learn**, then tap **Run**. A successful `devicectl` launch only proves the IPA URL was delivered, not that import or guest launch succeeded. If a replacement confirmation appears, verify it targets Learn and preserve its existing data. Never remove unrelated apps to make room without the user's approval.

The output IPA is `build/PodcastLearning-LiveContainer.ipa`; build failures are in `build/livecontainer-build.log`. If URL delivery fails, import that IPA on the phone using LiveContainer's **+** button and its Documents folder in Files.

**Scope:** this is a local-only LiveContainer guest, not a standalone installation. Guest share extensions, App Groups, iCloud sync, and native-install signing behavior are not covered. Keep real API keys and sensitive transcripts out of container testing: LiveContainer guests share a host sandbox. [Upstream installation and limitations](https://github.com/LiveContainer/LiveContainer/blob/main/README.md).
