#!/bin/bash
set -e

SIGNING_IDENTITY="Developer ID Application: Cara Brocklin (Z3ZSL4VU7F)"
TEAM_ID="Z3ZSL4VU7F"

echo "Building Meeting Recorder..."
swift build -c release 2>&1

echo "Packaging app bundle..."
cp .build/release/MeetingRecorder MeetingRecorder.app/Contents/MacOS/MeetingRecorder

# Bundle Python pipeline script into Resources
mkdir -p MeetingRecorder.app/Contents/Resources
cp Resources/call-analyzer.py MeetingRecorder.app/Contents/Resources/call-analyzer.py

echo "Code signing..."
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    MeetingRecorder.app 2>&1

echo "Verifying signature..."
codesign --verify --deep --strict MeetingRecorder.app 2>&1
echo "Signature valid."

echo ""
echo "Done! App bundle at: $(pwd)/MeetingRecorder.app"
echo ""
echo "To launch:  open MeetingRecorder.app"
echo "To install: cp -r MeetingRecorder.app /Applications/"
