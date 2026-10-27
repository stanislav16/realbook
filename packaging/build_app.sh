#!/bin/zsh
# Build dist/RealBook.app and dist/RealBook.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

uv sync --quiet
uv run pyinstaller --noconfirm --clean --distpath dist --workpath build packaging/RealBook.spec

# Ad-hoc signature so macOS treats the bundle as one consistent app.
codesign --force --deep --sign - dist/RealBook.app

rm -f dist/RealBook.dmg
staging=$(mktemp -d)
cp -R dist/RealBook.app "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname RealBook -srcfolder "$staging" -ov -format UDZO dist/RealBook.dmg
rm -rf "$staging"

echo "Built dist/RealBook.app and dist/RealBook.dmg"
