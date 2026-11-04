#!/usr/bin/env bash
# Chrome Web Store'a yüklenecek zip'i oluşturur: dist/virtual-camera-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(python3 -c "import json;print(json.load(open('manifest.json'))['version'])")
out="dist/virtual-camera-$version.zip"
mkdir -p dist
rm -f "$out"
zip -qr "$out" manifest.json _locales icons ./*.js ./*.html ./*.css -x '.*' -x '__MACOSX/*'
echo "$out"
unzip -l "$out" | tail -1
