#!/usr/bin/env bash
# iOS 17+ の developer 系サービス(スクリーンショット含む)を使うのに必要な tunneld を
# root 権限で起動する。
#
# tunneld は RemoteXPC トンネルを維持し続ける常駐プロセスで、root でなければ
# 起動できない。Ctrl-C で終了するまでフォアグラウンドで動き続ける。
# デーモン化したい場合は `nohup` 等で自前にバックグラウンド化すること。
#
# 使い方:
#   bridge/scripts/start_tunneld.sh          # 直接実行(root でなければ自動で sudo する)
#   sudo bridge/scripts/start_tunneld.sh     # 先に sudo を付けてもよい
#
# `uv` が PATH に無い環境向けに `UV_PATH` で明示的に指定できる(ルート README.md の
# 環境変数の説明と同じ探索順)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_uv() {
  if [[ -n "${UV_PATH:-}" ]]; then
    echo "${UV_PATH}"
    return
  fi
  local candidate
  for candidate in "${HOME}/.local/bin/uv" "/opt/homebrew/bin/uv" "/usr/local/bin/uv"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
  command -v uv
}

UV_BIN="$(find_uv)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tunneld は root 権限が必要なため、sudo で再実行する。" >&2
  exec sudo "${UV_BIN}" run --project "${BRIDGE_DIR}" pymobiledevice3 remote tunneld
fi

exec "${UV_BIN}" run --project "${BRIDGE_DIR}" pymobiledevice3 remote tunneld
