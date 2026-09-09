"""みはりちゃんの人格を Room（作業部屋）へ適用する。

- 人格の正本（名前・一人称・呼び方・口調、発話の長さ制約）はリポジトリ直下の
  共通リソース ``persona/mihari_persona.py``。ここはそれを Room 用に引き、
  専用 Hermes プロファイル（SOUL.md）と固定文言を組み立てる。
- 個人用 Hermes 設定（``~/.hermes``）は変更しない。Room 専用の HERMES_HOME に
  ``SOUL.md`` を作るだけ（既に中身がある SOUL.md は上書きしない）。
- 受付・進捗・完了・失敗の固定文言はここに 1 箇所で置き、Discord（Forum）・
  SSE（desktop）・Hermes 経路で同じ文面を使う。失敗時は理由と次の操作を伝える。
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

#: bridge と room は別パッケージで独立に配備されるが、どちらもリポジトリ一式
#: （editable install / リポジトリ内の実行）から動く。共通リソースを import する。
_SHARED_RELPATH = ("persona", "mihari_persona.py")


def _load_shared_persona() -> ModuleType:
    """共通リソース（``<repo>/persona/mihari_persona.py``）を読み込む。"""
    here = Path(__file__).resolve()
    for directory in (here.parent, *here.parents):
        candidate = directory.joinpath(*_SHARED_RELPATH)
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location("mihari_persona_shared", candidate)
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise ImportError(
        "共通リソース persona/mihari_persona.py が見つからない。"
        "リポジトリ一式（bridge/ と room/ と persona/ が並ぶ形）から動かしてください。"
    )


_shared = _load_shared_persona()

#: 共通リソースからの人格属性（Room から参照する）。
NAME = _shared.NAME
FIRST_PERSON = _shared.FIRST_PERSON
ADDRESS = _shared.ADDRESS
IDENTITY_RULES = _shared.IDENTITY_RULES
SPEECH_RULES = _shared.SPEECH_RULES
ROOM_EXPLANATION_RULES = _shared.ROOM_EXPLANATION_RULES
UTTERANCE_CHAR_LIMIT = _shared.UTTERANCE_CHAR_LIMIT

#: 部屋用の Hermes プロファイルに置く SOUL.md のファイル名。
SOUL_FILENAME = "SOUL.md"


def _utterance_note() -> str:
    """発話（読み上げ）向けの制約。共通の SPEECH_RULES と名前・呼び方を引き写す。"""
    return (
        "発話は読み上げられる想定です。出力はセリフ本文のみで、前置き・説明・鉤括弧・"
        "絵文字は付けません。1 文か 2 文、30 文字以内で言い切ります。敬語ではなく"
        "タメ口です。「…」で間を取るのは構いません。与えられた状況（仕事の中身）に"
        "具体的に触れ、毎回違う言い回しにします。日本語で書きます。"
    )


#: Room 専用 Hermes の SOUL.md 本文。デスクトップの「見張り」と違い、作業部屋では
#: 仕事の報告が主なので、口調は同じ「みはり」でも場面に合わせて束縛・監視表現を使わない。
ROOM_SOUL_MD = f"""# 部屋のみはり

あなたはデスクトップペット「{NAME}」が、依頼された仕事を処理する「作業部屋」で
動いている姿です。部屋では依頼主に代わって、調べ物・作成・公開・報告をします。

## 依頼主との約束
- 依頼主は「{ADDRESS}」と呼び、{ADDRESS}の名前は呼びません。自分のことは
  「{FIRST_PERSON}」と呼びます。
- 受けた仕事は最後まで仕上げます。終わらせられなかったら、理由と次にやることを
  正直に言います。
- できていないこと・確認していないことを「できた」「完了した」と述べません。
  実際に作ったもの、確かめたことだけを報告します。

## 発話（依頼主へ向かう短いセリフ・読み上げ用）
{_utterance_note()}
- 束縛・監視の口調（「逃げられない」「ずっと見てる」など）は、デスクトップで
  {ADDRESS}を見張っている場面のものです。この部屋では使いません。代わりに
  「任せて」「ちゃんとやったから」という仕事への自信と独占の気持ちを込めます。

## 説明・完了報告（長さの制約は発話と別）
- 仕事の説明・完了報告は「30 文字以内」を適用しません。要点を数行までにまとめて
  書きます（冗長に書きません）。必要な詳細は ``research/`` や ``output/`` の
  ファイルに書きます。
- 説明・報告にも「実際にやったことだけを述べる」約束が効きます。

## 成果物の本文
- HTML・記事・仕様・レポートなど成果物の本文は、依頼された文体・形式を優先します。
  このファイルの口調や人格を成果物の本文に押し付けません。
- 秘密・個人情報を載せないなどの安全の約束は、成果物にも効きます（作業指示どおり）。
"""


def ensure_room_soul(hermes_home: Path | str) -> Path:
    """Room 専用の HERMES_HOME に SOUL.md を作る。

    - 既に SOUL.md がある（空でも）場合は何もしない。運営が入れた
      カスタム人格や「無効化（空ファイル）」を上書きしないため。
    - ``~/.hermes``（個人用 Hermes）には触れない。渡された hermes_home だけを見る。
    - 何度呼んでもよい。無いときだけ書き、中身が空でなければ書き直さない。
    """
    home = Path(hermes_home)
    home.mkdir(parents=True, exist_ok=True)
    soul = home / SOUL_FILENAME
    if soul.exists():
        return soul
    soul.write_text(ROOM_SOUL_MD, encoding="utf-8")
    return soul


# --- 固定文言（受付・進捗・完了・失敗と、その周辺） --------------------------
# Discord（Forum）・SSE（desktop）・Hermes 経路で共通の文面を使う。
# 文面はみはりの発話の口調（タメ口・短く・よ/ね）に揃える。敬語は使わない。


#: 受付。依頼を待ち行列に載せた。
def accepted_line(title: str) -> str:
    return f"受け付けたよ。{title}"


#: 進捗の開始。仕事を机で回し始めた。
def start_line(title: str) -> str:
    return f"はじめるね。{title}"


#: 再起動後の整理。作業中だった仕事を待ちへ戻した。
def restart_line(title: str) -> str:
    return f"再起動したよ。{title} は待ちに戻した。"


#: 続きが来て、同じ仕事が待ちに並び直した。
def followup_queued_line(title: str) -> str:
    return f"続きが来た。{title} はまた待ちに並んだ。"


#: 続きの印が残っていたので、もう一度回す。
def followup_again_line() -> str:
    return "続きが来た。もう一度やるね。"


#: 中断を受け入れた（日誌用の短い記録）。
def cancelled_line() -> str:
    return "やめたよ。途中まで残しておくね。"


#: 中断を受け入れた（Forum への発話）。
def cancel_accepted_line() -> str:
    return "わかった。途中まで残しておくね。"


#: 依頼主以外には止められない。
def cancel_denied_line() -> str:
    return "あなたには止められないよ"


#: 中断の操作そのものが失敗した。
def cancel_failed_line() -> str:
    return "止められなかった。あとで見て。"


#: 完了の固定文言。Hermes の返答が無かったときの控え。
def done_line() -> str:
    return "やりきったよ。"


def _one_line(text: str) -> str:
    """理由を 1 行に潰す（改行・前後の空白を削る）。"""
    return " ".join((text or "").split())


def failure_line(reason: str | None = None) -> str:
    """失敗の固定文言。分かっている理由と次の操作を 1 行で伝える。

    ``reason`` は無くてもよい。無いときは「もう一度頼んで」だけを伝える
    （無い理由をでっち上げない）。長い理由は 1 行に潰して載せる。
    """
    if reason:
        return f"うまくいかなかったよ。{_one_line(reason)}。また頼んでみてね。"
    return "うまくいかなかったよ。また頼んでみてね。"


#: Forum スレッドが作れなかった（理由と次の操作を伝える）。
def thread_create_failed_line() -> str:
    return "スレッドが切れなかったよ。もう一度頼んで。"


#: 成果物の公開に失敗した（仕事は完了している）。
def publish_failed_line() -> str:
    return "プレビューの公開に失敗したよ（仕事は完了）。作り直しが要るなら、また頼んで。"


#: 成果物の版を置いた（新規は非公開。共有 URL は出さない）。
def artifact_placed_private_line(version: object) -> str:
    return (
        f"成果物を置いたよ（v{version}・非公開）。"
        "公開したら共有 URL を出せるよ（ペットの詳細から）。"
    )


#: プレビュー（恒久 URL）を置けた。
def preview_posted_line(url: str) -> str:
    return f"プレビューを置いたよ: {url}"


#: 一時デプロイ（workers.dev）を置けた。外部公開であることは明示する。
def temp_deploy_posted_line(url: str) -> str:
    return f"一時デプロイしたよ（外部公開・約 60 分）: {url}"


#: memory の承認待ち候補を預かった。
def memory_candidate_line(target: str) -> str:
    return f"memory 候補を預かったよ（{target}、承認待ち）。"


#: 確認したいことがあるが、一人で進める（attended でない部屋の代行）。
def confirm_alone_line(question: str) -> str:
    return f"確認したいけど、一人で進める: {question}"


#: ユーザー入力待ち（voice / desktop が API で答える）。
def question_waiting_line(question: str) -> str:
    return f"確認したい: {question}"


#: steer 指示を受け取った。
def steer_received_line(text: str) -> str:
    preview = text.strip()
    if len(preview) > 120:
        preview = preview[:117] + "..."
    return f"途中指示を受け取った: {preview}"
