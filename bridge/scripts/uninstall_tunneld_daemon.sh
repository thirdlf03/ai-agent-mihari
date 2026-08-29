#!/usr/bin/env bash
# install_tunneld_daemon.sh で登録した tunneld の LaunchDaemon を外す。
#
# 使い方:
#   sudo bridge/scripts/uninstall_tunneld_daemon.sh
set -euo pipefail

LABEL="com.thirdlf03.mihari.tunneld"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "LaunchDaemon の解除には root 権限が必要なため、sudo で再実行する。" >&2
  exec sudo "${BASH_SOURCE[0]}"
fi

launchctl bootout "system/${LABEL}" 2>/dev/null || true
rm -f "${PLIST}"
echo "==> 解除した: ${LABEL}"
