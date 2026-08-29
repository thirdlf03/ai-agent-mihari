#!/usr/bin/env bash
# iPhone のスクリーンショットを撮れる状態にするまでを一気に通す。
#
# 前提:
#   - iPhone を USB ケーブルで Mac に繋いでいること(「信頼」を許可しておく)
#     DeveloperDiskImage のアップロードは Wi-Fi 経由では通らない
#   - iPhone の 設定 > プライバシーとセキュリティ > デベロッパモード が オン
#
# 使い方:
#   sudo bridge/scripts/setup_iphone_screenshot.sh
#
# tunneld の起動に root が必要なため、全体を sudo で実行する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_uv() {
  if [[ -n "${UV_PATH:-}" ]]; then echo "${UV_PATH}"; return; fi
  local candidate
  for candidate in "${HOME}/.local/bin/uv" "/opt/homebrew/bin/uv" "/usr/local/bin/uv"; do
    [[ -x "${candidate}" ]] && { echo "${candidate}"; return; }
  done
  echo "error: uv が見つからない。UV_PATH を設定する" >&2
  exit 1
}

UV="$(find_uv)"
run() { (cd "${BRIDGE_DIR}" && "${UV}" run "$@"); }

echo "==> 1/4 接続を確認"
run device-bridge list

echo "==> 2/4 DeveloperDiskImage をマウント"
if run pymobiledevice3 mounter list | grep -q Personalized; then
  echo "    すでにマウント済み"
else
  # 初回はイメージのダウンロードが走る。USB で繋がっていないとここで切れる。
  run pymobiledevice3 mounter auto-mount
fi

echo "==> 3/4 tunneld を起動(バックグラウンド)"
if curl -s -m 2 http://127.0.0.1:49151 >/dev/null 2>&1; then
  echo "    すでに起動している"
else
  (cd "${BRIDGE_DIR}" && nohup "${UV}" run pymobiledevice3 remote tunneld >/tmp/mihari-tunneld.log 2>&1 &)
  echo "    起動した(ログ: /tmp/mihari-tunneld.log)"
  echo "    トンネル確立まで数秒待つ"
  sleep 8
fi

echo "==> 4/4 前提が揃ったか確認"
run python -c "
import asyncio, json
from device_bridge.commands import screenshot
from device_bridge.commands.screenshot_source import LiveScreenshotSource

result = asyncio.run(screenshot.run_preflight(LiveScreenshotSource()))
payload = result.to_payload()
print()
for check in payload['checks']:
    print(('  OK  ' if check['ok'] else '  NG  ') + check['label'])
    if check.get('remediation'):
        print('      -> ' + check['remediation'])
print()
print('撮れる状態: ' + ('はい' if payload['ready'] else 'いいえ'))
"
