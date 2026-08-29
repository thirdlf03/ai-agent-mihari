#!/usr/bin/env bash
#
# Mihari を .app バンドルとしてビルドし、署名する。
#
# swift run で直接実行すると、TCC(カメラ / 画面収録 / 入力監視 / モーション)のプロンプトが
# 正しく出ない。用途文字列を持つ Info.plist 入りの署名済み .app バンドルである必要があるため、
# swift build の生成物をここでバンドル化している。
#
# 組み立ては一時ディレクトリ(.build/staging.XXXXXX)の中で行い、署名と検証まで通ってから
# ./Mihari.app へ mv で差し替える。既存の ./Mihari.app を先に rm -rf すると、そのバンドルを
# 起動中のプロセスの足元から Info.plist が消え、TCC が用途文字列を読めずに
# __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__ で落ちるため。
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
PREVIOUS_DIR="./.build/${APP_NAME}.app.previous"

# 失敗しても中途半端な staging を残さない。差し替えに成功した時点で空になる。
STAGING_DIR=""
cleanup_staging() {
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup_staging EXIT

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

# staging は ./Mihari.app と同じファイルシステム上に置く。最後の差し替えを
# コピーではなく rename にするため。
mkdir -p ./.build
STAGING_DIR="$(mktemp -d ./.build/staging.XXXXXX)"
STAGING_APP="${STAGING_DIR}/${APP_NAME}.app"

echo "==> ${APP_NAME}.app を組み立て(${STAGING_APP})"
mkdir -p "${STAGING_APP}/Contents/MacOS"
mkdir -p "${STAGING_APP}/Contents/Resources"

cp "${BIN_PATH}" "${STAGING_APP}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${STAGING_APP}/Contents/Info.plist"
printf 'APPL????' > "${STAGING_APP}/Contents/PkgInfo"

# ペットのスプライト等は SwiftPM がリソースバンドルにまとめる。.app 直下に置くと
# codesign --verify --strict が落ちるので、必ず Contents/Resources に入れる。
BUNDLE_NAME="${APP_NAME}_MihariCore.bundle"
BUNDLE_PATH="${BIN_DIR}/${BUNDLE_NAME}"
if [ ! -d "${BUNDLE_PATH}" ]; then
    echo "error: リソースバンドルが見つからない: ${BUNDLE_PATH}" >&2
    exit 1
fi
cp -R "${BUNDLE_PATH}" "${STAGING_APP}/Contents/Resources/${BUNDLE_NAME}"

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
# ここで失敗したら trap が staging を消し、./Mihari.app には一切触れずに終わる。
echo "==> 署名: ${SIGN_LABEL}"
codesign --force --deep --sign "${SIGN_IDENTITY}" \
    --entitlements "Resources/${APP_NAME}.entitlements" \
    "${STAGING_APP}"

echo "==> 署名の検証"
codesign --verify --strict "${STAGING_APP}"
codesign -dv --entitlements - "${STAGING_APP}" 2>&1 | sed 's/^/    /'

# TCC がアプリを同一視する根拠。証明書署名なら Team ID を含む要件、ad-hoc なら cdhash になる。
# cdhash は再ビルドのたびに変わるので、許可も毎回リセットされる。
codesign -d --requirements - "${STAGING_APP}" 2>&1 | grep -m 1 'designated =>' | sed 's/^/    /' || true

# 起動中のプロセスは差し替え後も古いバンドル(.previous)を参照し続けるため、
# 新しいバンドルは次回起動からしか効かない。
RUNNING_PIDS="$(pgrep -x "${APP_NAME}" | tr '\n' ' ' || true)"
RUNNING_PIDS="${RUNNING_PIDS% }"
if [ -n "${RUNNING_PIDS}" ]; then
    echo "warning: ${APP_NAME} が起動中(pid ${RUNNING_PIDS})。ビルド後のバンドルは次回起動から有効。起動中のアプリは一度終了して起動し直すこと" >&2
    if [ "${MIHARI_BUILD_REQUIRE_QUIT:-}" = "1" ]; then
        echo "error: MIHARI_BUILD_REQUIRE_QUIT=1 のため差し替えを中止した。${APP_NAME} を終了してからやり直すこと" >&2
        exit 1
    fi
fi

# 同一ファイルシステム上の mv なので rename になり、途中経過が外から見えない。
echo "==> ${APP_DIR} へ差し替え"
if [ -d "${APP_DIR}" ]; then
    rm -rf "${PREVIOUS_DIR}"
    mv "${APP_DIR}" "${PREVIOUS_DIR}"
    echo "    旧バンドルを退避: ${PREVIOUS_DIR}"
fi
mv "${STAGING_APP}" "${APP_DIR}"

echo ""
echo "==> 生成物: $(cd "${APP_DIR}" && pwd)"
