#!/usr/bin/env bash
#
# ビルドしてから Mihari.app を起動する。
#
# アプリの標準出力やログをターミナルで見たい場合は open ではなく
# ./Mihari.app/Contents/MacOS/Mihari を直接実行する。バンドル内の実行ファイルを直接叩いても
# バンドル ID と署名は変わらないため、TCC のプロンプトは同じように出る。
#
set -euo pipefail

cd "$(dirname "$0")"

./build.sh
echo "==> Mihari.app を起動"
open ./Mihari.app
