#!/usr/bin/env bash
# =============================================================================
# mihari-room バックアップ（部屋 + Hermes 専用プロファイル）
#
# 撮るもの:
#   $HERMES_HOME      Hermes 専用プロファイル（state.db, config.yaml, .env,
#                     sessions/, memories/, skills/, hooks/, cron/, plugins/, pairing/）
#   $MIHARI_ROOM_ROOT 部屋（jobs/ と、実装が進んだら messages.db, archive/, previews/）
#
# 約束:
#   - set -euo pipefail
#   - パスは明示（環境変数のみ）。HOME や"現在のディレクトリ"には依存しない
#   - シンボリックリンクのルートと "/" は拒否
#   - 停止した状態か --live-consistent（sqlite3 .backup）で一貫したスナップショットを撮る。
#     Hermes の state.db は WAL（journal_mode=wal）なので、稼働中に生コピーすると壊れる。
#   - .env などの秘密は tar には入るが、標準出力・エラーには一切出さない
#   - 成果物は mode 600、ディレクトリは 700
#   - rm は使わない。古いバックアップの削除は手動
#
# 使い方:
#   sudo -u mihari env MIHARI_ROOM_ROOT=/var/lib/mihari/room \
#       HERMES_HOME=/var/lib/mihari/hermes \
#       ./backup.sh                     # サービス停止を要求
#   ./backup.sh --live-consistent       # 動いたまま撮る（sqlite3 必須）
#
# 実行例（systemd 環境）:
#   systemctl stop mihari-room && sudo -u mihari MIHARI_ROOM_ROOT=... HERMES_HOME=... ./backup.sh && systemctl start mihari-room
# =============================================================================
set -euo pipefail
umask 077

BACKUP_DIR="${MIHARI_BACKUP_DIR:-/var/lib/mihari/backups}"
LIVE_OK=0
ASSUME_STOPPED=0

usage() {
    cat >&2 <<'EOF'
使い方: backup.sh [--live-consistent] [--assume-stopped]

  --live-consistent   サービスを止めずに撮る（sqlite3 .backup で DB だけ整合化）
  --assume-stopped    systemd の無い環境で「停止している」ことを表明する（自己責任）

環境変数（必須）:
  MIHARI_ROOM_ROOT   部屋のルート
  HERMES_HOME        Hermes 専用プロファイルのホーム
  MIHARI_BACKUP_DIR  バックアップ先（既定 /var/lib/mihari/backups）
EOF
}

for arg in "$@"; do
    case "$arg" in
        --live-consistent) LIVE_OK=1 ;;
        --assume-stopped) ASSUME_STOPPED=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage; echo "backup.sh: 不明な引数: $arg" >&2; exit 64 ;;
    esac
done

: "${MIHARI_ROOM_ROOT:?MIHARI_ROOM_ROOT を設定して}"
: "${HERMES_HOME:?HERMES_HOME を設定して}"

die() {
    echo "backup.sh: $*" >&2
    exit 1
}

# --- ルート検証: 実在ディレクトリ / シンボリックリンク拒否 / "/" 拒否 ---
check_root() {
    local name="$1" path="$2" real
    [ -n "$path" ] || die "$name が空"
    [ -d "$path" ] || die "$name はディレクトリではない: $path"
    if [ -L "$path" ]; then
        die "$name はシンボリックリンク。実パスを指定して: $path"
    fi
    real="$(cd "$path" && pwd -P)"
    [ "$real" != "/" ] || die "$name は / を指す（broad root は拒否）: $path"
    printf '%s' "$real"
}

ROOM_ROOT="$(check_root MIHARI_ROOM_ROOT "$MIHARI_ROOM_ROOT")"
HERMES="$(check_root HERMES_HOME "$HERMES_HOME")"
[ "$ROOM_ROOT" != "$HERMES" ] || die "MIHARI_ROOM_ROOT と HERMES_HOME が同じ: $ROOM_ROOT"
# ルートが互いに親子になっていたら拒否（入れ子バックアップ防止）
case "$ROOM_ROOT/" in
    "$HERMES"/*) die "HERMES_HOME が ROOM_ROOT の親。狭いルートを指定して: $HERMES -> $ROOM_ROOT" ;;
esac
case "$HERMES/" in
    "$ROOM_ROOT"/*) die "ROOM_ROOT が HERMES_HOME の親。狭いルートを指定して: $ROOM_ROOT -> $HERMES" ;;
esac

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)"
[ "$BACKUP_DIR" != "/" ] || die "MIHARI_BACKUP_DIR が / を指す"
case "$BACKUP_DIR/" in
    "$ROOM_ROOT"/* | "$HERMES"/*)
        die "MIHARI_BACKUP_DIR は ROOM_ROOT / HERMES_HOME の外に置いて: $BACKUP_DIR" ;;
esac

# --- サービス停止の確認（quiescence） ---
# systemd が居なければ state=unknown。--assume-stopped か --live-consistent を強制する。
SERVICE="mihari-room.service"
state="unknown"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --type=service "$SERVICE" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$SERVICE"; then
        state="running"
    else
        state="stopped"
    fi
fi

MODE=""
case "$state" in
    running)
        if [ "$LIVE_OK" -eq 1 ]; then
            MODE="live"
        else
            die "mihari-room が動いています。先に systemctl stop $SERVICE してから、か --live-consistent を使って"
        fi
        ;;
    stopped) MODE="stopped" ;;
    unknown)
        if [ "$LIVE_OK" -eq 1 ]; then
            MODE="live"
        elif [ "$ASSUME_STOPPED" -eq 1 ]; then
            MODE="stopped"
        else
            die "systemd が見えない。--assume-stopped か --live-consistent を付けて"
        fi
        ;;
esac

if [ "$MODE" = "live" ] && ! command -v sqlite3 >/dev/null 2>&1; then
    die "--live-consistent には sqlite3 が必要"
fi

# --- 一時領域と成果物 ---
STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$BACKUP_DIR/mihari-room-$STAMP"
mkdir -p "$STAGE"
TAR="$BACKUP_DIR/mihari-room-$STAMP.tar.gz"

ROOM_REL="${ROOM_ROOT#/}"
HERM_REL="${HERMES#/}"
BACKUP_REL="$BACKUP_DIR"
BACKUP_REL="${BACKUP_REL#/}/mihari-room-$STAMP"

# --- DB の一貫性 ---
# stopped:            DB と -wal / -shm の三つをそのまま入れる（WAL の三つ組）。
#                     サービス停止状態ならこのコピーで一貫している。
messages_db="$ROOM_ROOT/messages.db"
if [ "$MODE" = "live" ]; then
    # 動いたまま撮る: 各 DB を sqlite3 .backup で整合スナップショットに。
    # この場合 -wal/-shm は tar には入れない（.backup が正本）。
    for f in "$HERMES/state.db" "$messages_db"; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        sqlite3 "$f" ".backup '$STAGE/$name'"
        echo "snapshot: $f -> $STAGE/$name"
    done
fi

# --- tar の除外（秘密は入れないのではなくキャッシュを除く。.env は復元用に入れる） ---
EXCL=(
    --exclude='*.pyc'
    --exclude='*/__pycache__'
    --exclude='*/.ruff_cache'
    --exclude='*/.pytest_cache'
    --exclude='*/.venv'
    --exclude="$HERM_REL/image_cache"
    --exclude="$HERM_REL/audio_cache"
    --exclude="$HERM_REL/bootstrap-cache"
    --exclude="$HERM_REL/logs"
)
if [ "$MODE" = "live" ]; then
    # 生の main db は動いたままのファイルなので tar に入れない（スナップショットが正本）
    EXCL+=(--exclude="$HERM_REL/state.db" --exclude="$HERM_REL/state.db-wal" --exclude="$HERM_REL/state.db-shm")
    if [ -f "$messages_db" ]; then
        EXCL+=(--exclude="$ROOM_REL/messages.db" --exclude="$ROOM_REL/messages.db-wal" --exclude="$ROOM_REL/messages.db-shm")
    fi
    # スナップショットの横に出来る空の -wal/-shm 付け合わせは要らない
    EXCL+=(--exclude="$BACKUP_REL/state.db-wal" --exclude="$BACKUP_REL/state.db-shm")
    EXCL+=(--exclude="$BACKUP_REL/messages.db-wal" --exclude="$BACKUP_REL/messages.db-shm")
fi
# 自分自身（今まさに書きかけの tar）を中に入れない
EXCL+=(--exclude="$BACKUP_REL.tar.gz")

# --- manifest（サイズと経路だけ。中身は出さない） ---
{
    echo "created: $(date -u +%FT%TZ)"
    echo "mode: $MODE"
    echo "service: $SERVICE state=$state"
    echo "room_root: $ROOM_ROOT"
    echo "hermes_home: $HERMES"
    echo "backup_file: $TAR"
    echo "sources: $ROOM_REL $HERM_REL $BACKUP_REL"
    for f in "$HERMES/state.db" "$messages_db"; do
        [ -f "$f" ] || continue
        size="$(wc -c < "$f" | tr -d ' ')"
        echo "db: $f ($size bytes)"
        if [ "$MODE" = "stopped" ] && command -v sqlite3 >/dev/null 2>&1; then
            check="$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1 || true)"
            echo "db_integrity: $f -> ${check:-skip}"
        fi
    done
    if [ "$MODE" = "live" ] && [ -d "$STAGE" ]; then
        for f in "$STAGE"/*.db; do
            [ -f "$f" ] || continue
            check="$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>/dev/null | head -n 1 || true)"
            echo "snapshot_integrity: $f -> ${check:-skip}"
        done
    fi
} >"$STAGE/manifest.txt"

# --- 本体 ---
tar -C / -czf "$TAR" "${EXCL[@]}" "$ROOM_REL" "$HERM_REL" "$BACKUP_REL"

chmod 600 "$TAR"
chmod 600 "$STAGE/manifest.txt"

count="$(tar -tzf "$TAR" | wc -l | tr -d ' ')"
size="$(wc -c < "$TAR" | tr -d ' ')"
echo "backup: $TAR ($size bytes, $count entries, mode=$MODE)"
echo "manifest: $STAGE/manifest.txt"
echo "古いバックアップの削除は自動ではしない（手動で rm して。rm はこのスクリプトでは動かさない）"