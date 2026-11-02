#!/bin/zsh
# Build dist/RealBook.app and dist/RealBook.dmg: the native app (mac/) with the engine inside it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

uv sync --quiet
uv run pyinstaller --noconfirm --clean --distpath dist --workpath build packaging/RealBook.spec

(cd mac && swift build -c release)
version=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' packaging/RealBook.spec)
app=dist/RealBook.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp mac/.build/release/RealBook "$app/Contents/MacOS/RealBook"
sed "s/VERSION/$version/g" mac/Info.plist > "$app/Contents/Info.plist"
cp packaging/RealBook.icns "$app/Contents/Resources/RealBook.icns"
mv dist/RealBook "$app/Contents/Resources/engine"

# Ad-hoc signature so macOS treats the bundle as one consistent app.
codesign --force --deep --sign - "$app"

rm -f dist/RealBook.dmg
staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname RealBook -srcfolder "$staging" -ov -format UDZO dist/RealBook.dmg
rm -rf "$staging"

echo "Built $app and dist/RealBook.dmg"
