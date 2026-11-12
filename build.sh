#!/bin/zsh
# Builds "build/Usage Meter.app" (universal: Apple silicon + Intel, macOS 12+) with swiftc. No Xcode project.
# Usage: zsh build.sh [install]
set -e
here=${0:A:h}; app="$here/build/Usage Meter.app"; obj="$here/build/obj"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$obj"
src=("$here/App/UsageMeter.swift" "$here/App/UsageLog.swift" "$here/App/Limits.swift" "$here/App/Gauge.swift" "$here/App/History.swift")
if [[ ! -f "$here/App/AppIcon.icns" ]]; then
  swiftc -swift-version 5 "$here/App/Gauge.swift" "$here/tools/icon/main.swift" -o "$obj/make-icon"
  "$obj/make-icon" "$obj/icon.png"; set_="$obj/AppIcon.iconset"; mkdir -p "$set_"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$obj/icon.png" --out "$set_/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$obj/icon.png" --out "$set_/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_" -o "$here/App/AppIcon.icns"
fi
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos12.0" $src -o "$obj/UsageMeter-$arch"
done
lipo -create "$obj/UsageMeter-arm64" "$obj/UsageMeter-x86_64" -output "$app/Contents/MacOS/UsageMeter"
cp "$here/App/Info.plist" "$app/Contents/Info.plist"; cp "$here/App/AppIcon.icns" "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "built: $app ($(lipo -archs "$app/Contents/MacOS/UsageMeter"))"
if [[ $1 == install ]]; then
  pkill -x UsageMeter 2>/dev/null || true
  ditto "$app" "/Applications/Usage Meter.app"; open "/Applications/Usage Meter.app"
  echo "installed: /Applications/Usage Meter.app"
fi
