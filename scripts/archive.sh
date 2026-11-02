#!/bin/sh
# Archives the app for upload to App Store Connect, then opens it in Xcode's Organizer.
#   scripts/archive.sh          Beta, with Demo Mode, for TestFlight
#   scripts/archive.sh Release  no Demo Mode, for the App Store
# The build number is the commit count, so builds from main always go up. Run on the Mac that has
# Config/Backend.local.xcconfig: the backend address, demo key and signing team come from it.
set -eu
cd "$(dirname "$0")/.."

configuration="${1:-Beta}"
archive="build/CyclingCompanion-$configuration.xcarchive"

grep -q '^CC_DEMO_ACCESS_TOKEN = .' Config/Backend.local.xcconfig || {
    echo "Config/Backend.local.xcconfig needs CC_DEMO_ACCESS_TOKEN" >&2
    exit 1
}

xcodegen generate
xcodebuild archive \
    -project CyclingCompanion.xcodeproj \
    -scheme CyclingCompanion \
    -configuration "$configuration" \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"
open "$archive"
