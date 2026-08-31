#!/bin/sh
#
# 起動中の Mihari 本体と、それを立て直す監視プロセスを止める。
#
# 本体は SIGTERM を握り、生きているあいだは 20 秒ごとに watchdog を再登録する。
# watchdog は LaunchAgent の KeepAlive で kill されても launchd が立て直す。
# そのため「本体を SIGKILL → LaunchAgent を bootout → 監視プロセスを SIGKILL」
# の順で止める。plist も消して、次のログインで勝手に戻らないようにする。
#
# 使い方:
#   ./desktop/kill.sh
#   make kill
#
set -eu

LABEL="com.thirdlf03.mihari.watchdog"
UID_NUM="$(id -u)"
SERVICE="gui/${UID_NUM}/${LABEL}"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

kill_matching() {
  pattern="$1"
  pids="$(pgrep -f "${pattern}" || true)"
  if [ -n "${pids}" ]; then
    echo "==> kill -9 (${pattern})"
    # 改行区切りの PID をまとめて渡す。空のときは上で弾いている。
    echo "${pids}" | xargs kill -9
  else
    echo "==> いない: ${pattern}"
  fi
}

echo "==> Mihari 本体を SIGKILL"
# SIGTERM はアプリ側で握られる。生きていると watchdog を再登録するので先に落とす。
kill_matching '/Mihari.app/Contents/MacOS/Mihari$'

echo "==> watchdog LaunchAgent を bootout"
launchctl bootout "${SERVICE}" 2>/dev/null || true

echo "==> MihariWatchdog を SIGKILL"
kill_matching 'MihariWatchdog'

if [ -f "${PLIST}" ]; then
  echo "==> LaunchAgent plist を削除: ${PLIST}"
  rm -f "${PLIST}"
else
  echo "==> plist は既に無い: ${PLIST}"
fi

sleep 1

if pgrep -f '/Mihari.app/Contents/MacOS/Mihari$' >/dev/null \
  || pgrep -f 'MihariWatchdog' >/dev/null; then
  echo "残っているプロセスがある:" >&2
  pgrep -lf Mihari || true
  exit 1
fi

if launchctl print "${SERVICE}" >/dev/null 2>&1; then
  echo "watchdog がまだ launchd に残っている: ${SERVICE}" >&2
  exit 1
fi

echo "==> 停止した: Mihari / ${LABEL}"
