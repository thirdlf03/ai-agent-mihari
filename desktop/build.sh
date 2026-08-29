#!/usr/bin/env bash
#
# Mihari を .app バンドルとしてビルドし、ad-hoc 署名する。
#
# swift run で直接実行すると、TCC(カメラ / 画面収録 / 入力監視 / モーション)のプロンプトが
# 正しく出ない。用途文字列を持つ Info.plist 入りの署名済み .app バンドルである必要があるため、
# swift build の生成物をここでバンドル化している。
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Mihari"
CONFIG="${CONFIG:-release}"
APP_DIR="./${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    echo "error: ビルド済みバイナリが見つからない: ${BIN_PATH}" >&2
    exit 1
fi

echo "==> ${APP_NAME}.app を組み立て"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> ad-hoc 署名"
codesign --force --deep --sign - \
    --entitlements "Resources/${APP_NAME}.entitlements" \
    "${APP_DIR}"

echo "==> 署名の検証"
codesign --verify --strict "${APP_DIR}"
codesign -dv --entitlements - "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo ""
echo "==> 生成物: $(cd "${APP_DIR}" && pwd)"
