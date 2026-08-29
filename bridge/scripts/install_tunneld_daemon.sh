#!/usr/bin/env bash
# tunneld を launchd の LaunchDaemon として登録し、OS に常駐させる。
#
# tunneld は root でしか起動できないため、アプリやデーモンからは制御できない。
# 代わりに OS 側(launchd)に任せる: このスクリプトを sudo で 1 回実行すれば、
# 以後は Mac を再起動しても自動で立ち上がり、プロセスが落ちても自動で復活する。
# 毎回 `sudo bridge/scripts/start_tunneld.sh` を手で叩く必要はなくなる。
#
# 使い方:
#   sudo bridge/scripts/install_tunneld_daemon.sh    # 登録して起動
#   bridge/scripts/uninstall_tunneld_daemon.sh       # やめるとき
#
# 確認:
#   curl -s http://127.0.0.1:49151/                  # tunneld の HTTP API が応答すれば OK
#   tail -f /var/log/mihari-tunneld.log              # ログ
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LABEL="com.thirdlf03.mihari.tunneld"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/mihari-tunneld.log"

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

if [[ "$(id -u)" -ne 0 ]]; then
  echo "LaunchDaemon の登録には root 権限が必要なため、sudo で再実行する。" >&2
  # sudo 後も呼び出したユーザーの uv を見つけられるよう、HOME 由来の探索結果を引き継ぐ。
  exec sudo UV_PATH="$(find_uv)" "${BASH_SOURCE[0]}"
fi

UV_BIN="$(find_uv)"
echo "==> uv: ${UV_BIN}"
echo "==> bridge: ${BRIDGE_DIR}"

# すでに登録済みなら一度外す(再インストールを何度やっても壊れないように)。
launchctl bootout "system/${LABEL}" 2>/dev/null || true

cat > "${PLIST}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${UV_BIN}</string>
        <string>run</string>
        <string>--project</string>
        <string>${BRIDGE_DIR}</string>
        <string>pymobiledevice3</string>
        <string>remote</string>
        <string>tunneld</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${BRIDGE_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF

# launchd は所有者 root・グループ等の書き込み不可を要求する。
chown root:wheel "${PLIST}"
chmod 644 "${PLIST}"

launchctl bootstrap system "${PLIST}"
launchctl kickstart "system/${LABEL}" 2>/dev/null || true

echo "==> 登録した: ${PLIST}"
echo "==> 状態: launchctl print system/${LABEL} | head"
echo "==> 数秒待ってから curl -s http://127.0.0.1:49151/ で応答を確認する"
