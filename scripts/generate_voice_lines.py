#!/usr/bin/env python3
"""lines.json のセリフを VOICEVOX で合成し、アプリに同封する .m4a を書き出す。

同封音声(`MIHARI_VOICE_MODE=bundled`。既定)はここで作ったファイルをそのまま鳴らすだけで、
実行時に VOICEVOX を叩かない。セリフを足したり直したりしたら、このスクリプトを流し直す。

    python3 scripts/generate_voice_lines.py             # 全区分
    python3 scripts/generate_voice_lines.py --only idle # 区分を絞る

依存は Python 3 の標準ライブラリと macOS の afconvert だけ。uv は要らない。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# このスクリプトはリポジトリ直下の scripts/ に置いてある。
REPO_ROOT = Path(__file__).resolve().parent.parent
VOICE_DIR = REPO_ROOT / "desktop" / "Sources" / "MihariCore" / "Resources" / "voice"
LINES_JSON = VOICE_DIR / "lines.json"

DEFAULT_URL = "http://127.0.0.1:50021"
AFCONVERT = "/usr/bin/afconvert"

# `Pet/PetVoice.swift` の `VoicevoxQueryTuning.standard` と同じ値・同じキー。
# 同封音声と live(その場で合成)の声質を揃えるため、片方だけ変えないこと。
QUERY_TUNING = {
    "speedScale": 1.1,
    "intonationScale": 1.3,
    "pitchScale": 0.0,
    "prePhonemeLength": 0.05,
    "postPhonemeLength": 0.05,
    "pauseLengthScale": 0.9,
}

QUERY_TIMEOUT = 10.0
SYNTHESIS_TIMEOUT = 60.0


def audio_query(base_url: str, text: str, speaker: int) -> dict:
    """テキストから合成用のクエリを作らせる。"""
    query = urllib.parse.urlencode({"text": text, "speaker": speaker})
    request = urllib.request.Request(f"{base_url}/audio_query?{query}", method="POST")
    with urllib.request.urlopen(request, timeout=QUERY_TIMEOUT) as response:
        return json.load(response)


def synthesis(base_url: str, query: dict, speaker: int) -> bytes:
    """クエリから WAV を合成させる。"""
    params = urllib.parse.urlencode({"speaker": speaker})
    request = urllib.request.Request(
        f"{base_url}/synthesis?{params}",
        data=json.dumps(query).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "audio/wav"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=SYNTHESIS_TIMEOUT) as response:
        return response.read()


def to_m4a(wav: bytes, destination: Path) -> None:
    """WAV を AAC(.m4a)に変換して置く。アプリはこの形のまま再生する。"""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav") as source:
        source.write(wav)
        source.flush()
        subprocess.run(
            [AFCONVERT, "-f", "m4af", "-d", "aac", "-b", "64000", source.name, str(destination)],
            check=True,
            capture_output=True,
        )


def prune(directory: Path, keep: int) -> list[Path]:
    """セリフを減らしたときに残る、番号が後ろの古いファイルを消す。"""
    if not directory.is_dir():
        return []
    removed = []
    for path in sorted(directory.glob("*.m4a")):
        if not path.stem.isdigit() or int(path.stem) >= keep:
            path.unlink()
            removed.append(path)
    return removed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=DEFAULT_URL, help=f"VOICEVOX のアドレス (既定: {DEFAULT_URL})")
    parser.add_argument("--only", metavar="KIND", help="この区分だけを作り直す (例: idle)")
    args = parser.parse_args()

    base_url = args.url.rstrip("/")
    document = json.loads(LINES_JSON.read_text(encoding="utf-8"))
    speaker = int(document["speaker"])
    kinds: dict[str, list[str]] = document["kinds"]

    if args.only is not None:
        if args.only not in kinds:
            print(f"知らない区分: {args.only}(あるのは {', '.join(kinds)})", file=sys.stderr)
            return 1
        kinds = {args.only: kinds[args.only]}

    written = 0
    for kind, lines in kinds.items():
        directory = VOICE_DIR / kind
        for path in prune(directory, keep=len(lines)):
            print(f"削除 {path.relative_to(REPO_ROOT)}")
        for index, text in enumerate(lines):
            destination = directory / f"{index:02d}.m4a"
            try:
                query = audio_query(base_url, text, speaker)
                query.update(QUERY_TUNING)
                to_m4a(synthesis(base_url, query, speaker), destination)
            except urllib.error.URLError as error:
                print(f"VOICEVOX に繋がらない({base_url}): {error}", file=sys.stderr)
                return 1
            except subprocess.CalledProcessError as error:
                print(f"afconvert が失敗した: {error.stderr.decode('utf-8', 'replace')}", file=sys.stderr)
                return 1
            written += 1
            print(f"{destination.relative_to(REPO_ROOT)}  {text}")

    print(f"{written} 本を書き出した。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
