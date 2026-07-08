#!/bin/bash
# Builds LocalModelsBar.app in the project root.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="LocalModelsBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LocalModelsBar "$APP/Contents/MacOS/"
cp -R .build/release/LocalModelsBar_LocalModelsBar.bundle "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LocalModelsBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.sriinnu.localmodelsbar</string>
    <key>CFBundleName</key>
    <string>LocalModelsBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

echo "Built $APP — open it with: open $APP"
