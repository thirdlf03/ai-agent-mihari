#!/usr/bin/env bash
#
# Mihari を .app バンドルとしてビルドし、署名する。
#
# swift run で直接実行すると、TCC(カメラ / 画面収録 / 入力監視 / モーション)のプロンプトが
# 正しく出ない。用途文字列を持つ Info.plist 入りの署名済み .app バンドルである必要があるため、
# swift build の生成物をここでバンドル化している。
#
# 署名に使う identity は次の順で決まる(詳細は README の「署名について」)。
#   1. 環境変数 CODESIGN_IDENTITY
#   2. キーチェーンにある最初の Apple Development 証明書(自動検出)
#   3. どちらも無ければ ad-hoc(-)
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Mihari"
CONFIG="${CONFIG:-release}"
APP_DIR="./${APP_NAME}.app"

# security find-identity -v -p codesigning の出力(標準入力)から、最初の
# Apple Development 証明書を "<SHA-1ハッシュ> <名前>" の 1 行で返す。無ければ何も出さない。
#
# 想定する入力の形:
#   1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Apple Development: Taro Yamada (ABCD123456)"
#
# 同名の証明書が複数ある(更新して古いものが残っている等)と名前では一意に決まらないため、
# 署名には SHA-1 ハッシュのほうを使う。
extract_apple_development_identity() {
    grep -E '^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]{40}[[:space:]]+"Apple Development: ' \
        | head -n 1 \
        | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]{40})[[:space:]]+"(.*)"[[:space:]]*$/\1 \2/'
}

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

# ペットのスプライト等は SwiftPM がリソースバンドルにまとめる。.app 直下に置くと
# codesign --verify --strict が落ちるので、必ず Contents/Resources に入れる。
BUNDLE_NAME="${APP_NAME}_MihariCore.bundle"
BUNDLE_PATH="${BIN_DIR}/${BUNDLE_NAME}"
if [ ! -d "${BUNDLE_PATH}" ]; then
    echo "error: リソースバンドルが見つからない: ${BUNDLE_PATH}" >&2
    exit 1
fi
cp -R "${BUNDLE_PATH}" "${APP_DIR}/Contents/Resources/${BUNDLE_NAME}"

# 署名に使う identity を決める。
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="${CODESIGN_IDENTITY}"
    SIGN_LABEL="${CODESIGN_IDENTITY}(環境変数 CODESIGN_IDENTITY)"
else
    DETECTED="$(security find-identity -v -p codesigning 2>/dev/null | extract_apple_development_identity || true)"
    if [ -n "${DETECTED}" ]; then
        SIGN_IDENTITY="${DETECTED%% *}"
        SIGN_LABEL="${DETECTED#* }(自動検出 ${SIGN_IDENTITY})"
    else
        SIGN_IDENTITY="-"
        SIGN_LABEL="ad-hoc"
        echo "warning: ad-hoc 署名のため再ビルドごとに TCC の許可が無効になる。Apple Development 証明書を作ると持続する(README 参照)。" >&2
    fi
fi

# Hardened Runtime(--options runtime)は付けない。付けるとカメラ / マイクに
# com.apple.security.device.* の entitlements が別途必要になる。
echo "==> 署名: ${SIGN_LABEL}"
codesign --force --deep --sign "${SIGN_IDENTITY}" \
    --entitlements "Resources/${APP_NAME}.entitlements" \
    "${APP_DIR}"

echo "==> 署名の検証"
codesign --verify --strict "${APP_DIR}"
codesign -dv --entitlements - "${APP_DIR}" 2>&1 | sed 's/^/    /'

# TCC がアプリを同一視する根拠。証明書署名なら Team ID を含む要件、ad-hoc なら cdhash になる。
# cdhash は再ビルドのたびに変わるので、許可も毎回リセットされる。
codesign -d --requirements - "${APP_DIR}" 2>&1 | grep -m 1 'designated =>' | sed 's/^/    /' || true

echo ""
echo "==> 生成物: $(cd "${APP_DIR}" && pwd)"
