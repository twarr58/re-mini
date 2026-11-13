#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=ReMini.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp AppIcon.icns $APP/Contents/Resources/
swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/ReMini
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.remini</string>
  <key>CFBundleName</key><string>ReMini</string>
  <key>CFBundleExecutable</key><string>ReMini</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
codesign -s - --force $APP
echo "built $APP"
