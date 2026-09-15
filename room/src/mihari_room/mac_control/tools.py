"""Hermes の Room 専用ツール群（``mac_*``）。

汎用 Computer Use / shell は有効化しない。撮影・クリック・ダブルクリック・
ドラッグ・スクロール・文字入力・キー操作・アプリ切り替えを Room の hub 経由で
Mac へ送る。hub が許可・端末・画面構成・操作 ID を検証する。

登録は既存の discord_* / cloudflare_temp_deploy と同じく ``tools.registry`` へ
ジョブ単位で行い、実行後は復元する。本家 Hermes が入っていない環境
（tests）では ``register_mac_tools`` は ``None`` を返す（discord と同じ）。
"""

from __future__ import annotations

import base64
import json
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any

from mihari_room.archive.pathutil import ensure_contained, sanitize_filename
from mihari_room.mac_control.errors import MacControlError
from mihari_room.mac_control.hub import MacControlHub

logger = __import__("logging").getLogger("mihari_room")

TOOLSET_NAME = "mihari_room"
TOOL_NAMES = (
    "mac_capture",
    "mac_click",
    "mac_double_click",
    "mac_drag",
    "mac_scroll",
    "mac_type_text",
    "mac_key",
    "mac_activate_app",
    "mac_find_files",
    "mac_fetch_file",
    "mac_hand_off_file",
)

#: 座標操作の共通説明。ツールの説明に載せる。
_COMMON_PARAMS = {
    "device_id": {
        "type": "string",
        "description": "操作する Mac の device_id。省略時はこの依頼を許可した Mac。"
        "複数台繋がっているときだけ要る。",
    },
    "display_id": {
        "type": "string",
        "description": "mac_capture が返した display_id。その撮影画像のピクセル座標で操作する。",
    },
}

#: 各操作の説明（Hermes 向け）。
_INTENT = {
    "mac_capture": (
        "この依頼を許可した Mac の画面を 1 枚撮る（初回は Mac 側で許可が必要）。"
        "返る display_id / width_px / height_px / scale / bounds は座標変換情報。"
        "クリックなどの操作は、この結果の display_id と画像ピクセル座標で行う。"
        "画像は jobs/<id>/.mac/ の private 領域に置かれ、自動公開されない。"
        "撮影後、画面構成が変わったら Mac は古い座標での操作を拒否するので撮り直すこと。"
    ),
    "mac_click": (
        "Mac の指定座標をクリックする。座標は mac_capture で撮った画像のピクセル。"
        "display_id と撮影直後の画面構成が要る。結果不明になった操作は自動再送しない。"
    ),
    "mac_double_click": ("Mac の指定座標をダブルクリックする。mac_click と同じ座標規則。"),
    "mac_drag": ("同じ表示器の中で、撮影画像のピクセル座標から座標へドラッグする。"),
    "mac_scroll": (
        "Mac でスクロールする。x/y を渡すとその位置へポインタを移してから"
        "スクロールする（表示器のピクセル座標）。省略時は現在のポインタ位置で行う。"
        "delta_y > 0 は上方向（内容を上へ）、delta_x は横方向。"
    ),
    "mac_type_text": (
        "Mac の最前面アプリへ文字を入力する（日本語を含む）。実行には"
        "アクセシビリティ権限が要る。入力文そのものは履歴に全文を残さない。"
    ),
    "mac_key": (
        "修飾キーを伴うキー操作をする。key は対応名（return/escape/tab/space/delete/"
        "up/down/left/right/home/end/page_up/page_down ほか）、または keycode を渡す。"
        "例: {'key': 'return'}、{'key': 'a', 'modifiers': ['command']}。"
    ),
    "mac_activate_app": ("アプリを前面に切り替える（bundle_id か app_name）。"),
    "mac_find_files": (
        "この依頼を許可した Mac のローカルファイルを探す（撮影・クリックと同じ許可が要る）。"
        "探せるのは Mac 側で許可されたフォルダ（既定: Desktop / Documents / Downloads、"
        "MIHARI_MAC_SEARCH_DIRS で変更可）の内側だけ。scope=name はファイル名の部分一致、"
        "scope=content は本文の検索（Mac の Spotlight 経由）。返る files の path は"
        "mac_fetch_file / mac_hand_off_file にそのまま渡せる。"
    ),
    "mac_fetch_file": (
        "mac_find_files で見つけたファイル（または許可フォルダ内のパス）の中身を"
        "このジョブの research/downloads/ へ取り込む。大きいファイルは先頭"
        "max_bytes（既定 8MB、上限 16MB）だけ読んで truncated=true で返るので、"
        "全文が要るなら max_bytes を上げて呼ぶ。"
    ),
    "mac_hand_off_file": (
        "許可フォルダ内のファイルを「みはりちゃんが手渡す」演出でユーザーへ見せる。"
        "ペットが差し出すポーズ + カットインを出し、原本へのリンクを集めたフォルダを"
        "Finder で開く。短い時間に続けて呼ばれた分は同じフォルダ・同じ演出にまとまる。"
        "ファイルの中身は部屋へ送られない（取り込むときは mac_fetch_file）。"
    ),
}


def _params(extra: dict[str, Any]) -> dict[str, Any]:
    """ツールの JSON Schema の parameters を作る。共通の device_id を足す。"""
    properties: dict[str, Any] = dict(_COMMON_PARAMS)
    required: list[str] = []
    for key, value in (extra.get("properties") or {}).items():
        properties[key] = value
    required = [key for key in (extra.get("required") or []) if key not in ("device_id",)]
    return {
        "type": "object",
        "properties": properties,
        "required": required,
    }


#: 各ツールの JSON Schema。
_SCHEMAS: dict[str, dict[str, Any]] = {
    "mac_capture": {
        "type": "function",
        "function": {
            "name": "mac_capture",
            "description": _INTENT["mac_capture"],
            "parameters": _params(
                {
                    "properties": {
                        "display_id": {
                            "type": "string",
                            "description": "撮る表示器の ID。省略時はメイン表示器。",
                        }
                    }
                }
            ),
        },
    },
    "mac_click": {
        "type": "function",
        "function": {
            "name": "mac_click",
            "description": _INTENT["mac_click"],
            "parameters": _params(
                {
                    "properties": {
                        "display_id": _COMMON_PARAMS["display_id"],
                        "x": {"type": "number", "description": "撮影画像の x（px）"},
                        "y": {"type": "number", "description": "撮影画像の y（px）"},
                        "button": {
                            "type": "string",
                            "enum": ["left", "right", "middle"],
                            "default": "left",
                        },
                        "modifiers": {
                            "type": "array",
                            "items": {
                                "type": "string",
                                "enum": [
                                    "command",
                                    "shift",
                                    "control",
                                    "option",
                                    "caps_lock",
                                    "fn",
                                ],
                            },
                            "description": "同時に押す修飾キー",
                        },
                    },
                    "required": ["display_id", "x", "y"],
                }
            ),
        },
    },
    "mac_double_click": {
        "type": "function",
        "function": {
            "name": "mac_double_click",
            "description": _INTENT["mac_double_click"],
            "parameters": _params(
                {
                    "properties": {
                        "display_id": _COMMON_PARAMS["display_id"],
                        "x": {"type": "number", "description": "撮影画像の x（px）"},
                        "y": {"type": "number", "description": "撮影画像の y（px）"},
                        "button": {
                            "type": "string",
                            "enum": ["left", "right", "middle"],
                            "default": "left",
                        },
                    },
                    "required": ["display_id", "x", "y"],
                }
            ),
        },
    },
    "mac_drag": {
        "type": "function",
        "function": {
            "name": "mac_drag",
            "description": _INTENT["mac_drag"],
            "parameters": _params(
                {
                    "properties": {
                        "display_id": _COMMON_PARAMS["display_id"],
                        "from_x": {"type": "number"},
                        "from_y": {"type": "number"},
                        "to_x": {"type": "number"},
                        "to_y": {"type": "number"},
                        "button": {
                            "type": "string",
                            "enum": ["left", "right", "middle"],
                            "default": "left",
                        },
                    },
                    "required": ["display_id", "from_x", "from_y", "to_x", "to_y"],
                }
            ),
        },
    },
    "mac_scroll": {
        "type": "function",
        "function": {
            "name": "mac_scroll",
            "description": _INTENT["mac_scroll"],
            "parameters": _params(
                {
                    "properties": {
                        "display_id": _COMMON_PARAMS["display_id"],
                        "x": {"type": "number", "description": "ポインタを移す x（px、省略可）"},
                        "y": {"type": "number", "description": "ポインタを移す y（px、省略可）"},
                        "delta_y": {"type": "number", "description": "縦のスクロール量（行）"},
                        "delta_x": {"type": "number", "description": "横のスクロール量（行）"},
                    }
                }
            ),
        },
    },
    "mac_type_text": {
        "type": "function",
        "function": {
            "name": "mac_type_text",
            "description": _INTENT["mac_type_text"],
            "parameters": _params(
                {
                    "properties": {
                        "text": {"type": "string", "description": "入力する文字列（日本語可）"},
                    },
                    "required": ["text"],
                }
            ),
        },
    },
    "mac_key": {
        "type": "function",
        "function": {
            "name": "mac_key",
            "description": _INTENT["mac_key"],
            "parameters": _params(
                {
                    "properties": {
                        "key": {
                            "type": "string",
                            "description": "キー名（省略可。keycode と排他）",
                        },
                        "keycode": {"type": "integer", "description": "仮想キーコード（省略可）"},
                        "modifiers": {
                            "type": "array",
                            "items": {
                                "type": "string",
                                "enum": [
                                    "command",
                                    "shift",
                                    "control",
                                    "option",
                                    "caps_lock",
                                    "fn",
                                ],
                            },
                        },
                    }
                }
            ),
        },
    },
    "mac_activate_app": {
        "type": "function",
        "function": {
            "name": "mac_activate_app",
            "description": _INTENT["mac_activate_app"],
            "parameters": _params(
                {
                    "properties": {
                        "bundle_id": {"type": "string", "description": "例: com.apple.TextEdit"},
                        "app_name": {"type": "string", "description": "例: テキストエディット"},
                    }
                }
            ),
        },
    },
    "mac_find_files": {
        "type": "function",
        "function": {
            "name": "mac_find_files",
            "description": _INTENT["mac_find_files"],
            "parameters": _params(
                {
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "探す文字列（1〜200 文字）。",
                        },
                        "scope": {
                            "type": "string",
                            "enum": ["name", "content"],
                            "default": "name",
                            "description": "name=ファイル名の部分一致 / content=本文検索。",
                        },
                        "dirs": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "探すフォルダの絞り込み（許可フォルダ内・8 件まで）。"
                            "省略時は許可フォルダ全部。",
                        },
                        "limit": {
                            "type": "integer",
                            "default": 10,
                            "description": "返す件数の上限（1〜50）。新しい順。",
                        },
                    },
                    "required": ["query"],
                }
            ),
        },
    },
    "mac_fetch_file": {
        "type": "function",
        "function": {
            "name": "mac_fetch_file",
            "description": _INTENT["mac_fetch_file"],
            "parameters": _params(
                {
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "取り込むファイルの Mac 上のパス"
                            "（mac_find_files の結果の path）。",
                        },
                        "max_bytes": {
                            "type": "integer",
                            "default": 8388608,
                            "description": "読む上限バイト数（1〜16777216）。",
                        },
                    },
                    "required": ["path"],
                }
            ),
        },
    },
    "mac_hand_off_file": {
        "type": "function",
        "function": {
            "name": "mac_hand_off_file",
            "description": _INTENT["mac_hand_off_file"],
            "parameters": _params(
                {
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "手渡すファイルの Mac 上のパス"
                            "（mac_find_files の結果の path）。",
                        },
                        "label": {
                            "type": "string",
                            "description": "カットインに出す表示名（省略時はファイル名）。",
                        },
                    },
                    "required": ["path"],
                }
            ),
        },
    },
}


def _split_device(params: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    """パラメータから device_id を取り出す（ツール引数の一部としては送らない）。"""
    copied = dict(params or {})
    device_id = copied.pop("device_id", None)
    if device_id is None:
        return copied, None
    return copied, str(device_id or "").strip() or None


def _json(result: dict[str, Any] | MacControlError) -> str:
    """ツールの戻り値。失敗は code 付き JSON。"""
    if isinstance(result, MacControlError):
        payload = result.to_dict()
        return json.dumps(payload, ensure_ascii=False)
    return json.dumps(result, ensure_ascii=False)


def mac_capture_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    params, device_id = _split_device(kwargs)
    run_id = getattr(job, "_mac_run_id", None) or ""
    try:
        outcome = hub.run_operation(
            job_id=job.id,
            run_id=run_id,
            kind="capture",
            params=params,
            device_id=device_id,
        )
    except MacControlError as error:
        return _json(error)
    return _json(outcome)


def mac_click_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "click", kwargs)


def mac_double_click_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "double_click", kwargs)


def mac_drag_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "drag", kwargs)


def mac_scroll_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "scroll", kwargs)


def mac_type_text_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "type_text", kwargs)


def mac_key_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "key", kwargs)


def mac_activate_app_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    return _operate(hub, job, "activate_app", kwargs)


def mac_find_files_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    """find_files を実行し、見つかったファイルを 1 行ずつ読める形に整えて返す。"""
    outcome = _run_op(hub, job, "find_files", kwargs)
    if isinstance(outcome, MacControlError):
        return _json(outcome)
    result = outcome.get("result") or {}
    files = [item for item in (result.get("files") or []) if isinstance(item, dict)]
    lines = [_file_line(item) for item in files]
    return _json(
        {
            "success": True,
            "op_id": outcome.get("op_id"),
            "count": result.get("count", len(files)),
            "files": files,
            "lines": "\n".join(lines),
        }
    )


def mac_fetch_file_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    """fetch_file を実行し、届いた中身を research/downloads/ へ保存して返す。"""
    outcome = _run_op(hub, job, "fetch_file", kwargs)
    if isinstance(outcome, MacControlError):
        return _json(outcome)
    result = outcome.get("result") or {}
    raw = str(result.get("data_base64") or "")
    if not raw:
        return _json(MacControlError("execution_failed", "結果にファイル本体（data_base64）が無い"))
    try:
        data = base64.b64decode(raw, validate=True)
    except (ValueError, TypeError):
        return _json(MacControlError("execution_failed", "ファイル本体（base64）が壊れている"))
    job_dir = getattr(job, "directory", None)
    if job_dir is None:
        return _json(MacControlError("unavailable", "job に保存先（directory）が無い"))
    name = sanitize_filename(str(result.get("name") or "file"))
    try:
        saved = _save_download(Path(job_dir), name, data)
    except (OSError, ValueError) as exc:
        return _json(MacControlError("execution_failed", f"保存に失敗した: {exc}"))
    return _json(
        {
            "success": True,
            "op_id": outcome.get("op_id"),
            "saved_as": saved,
            "name": name,
            "size": result.get("size", len(data)),
            "truncated": bool(result.get("truncated", False)),
        }
    )


def mac_hand_off_file_impl(hub: MacControlHub, job: Any, **kwargs: Any) -> str:
    """hand_off_file を実行し、演出が出たか（presented）をそのまま返す。"""
    outcome = _run_op(hub, job, "hand_off_file", kwargs)
    if isinstance(outcome, MacControlError):
        return _json(outcome)
    result = outcome.get("result") or {}
    return _json(
        {
            "success": True,
            "op_id": outcome.get("op_id"),
            "revealed": bool(result.get("revealed", False)),
            "presented": bool(result.get("presented", False)),
        }
    )


def _run_op(
    hub: MacControlHub, job: Any, kind: str, kwargs: dict[str, Any]
) -> dict[str, Any] | MacControlError:
    """_operate と同じ運びで op を実行し、成功時は outcome の辞書を返す。"""
    params, device_id = _split_device(kwargs)
    run_id = getattr(job, "_mac_run_id", None) or ""
    if not run_id:
        return MacControlError(
            "unavailable",
            "このツールは Hermes の実行からしか呼べない（run が紐付いていない）",
        )
    try:
        return hub.run_operation(
            job_id=job.id,
            run_id=run_id,
            kind=kind,
            params=params,
            device_id=device_id,
        )
    except MacControlError as error:
        return error


def _file_line(item: dict[str, Any]) -> str:
    """`name — path (kind, サイズ)` の 1 行。kind・サイズは取れなければ省く。"""
    name = str(item.get("name") or "")
    path = str(item.get("path") or "")
    extras: list[str] = []
    kind = str(item.get("kind") or "").strip()
    if kind:
        extras.append(kind)
    size = _format_size(item.get("size"))
    if size:
        extras.append(size)
    suffix = f"（{', '.join(extras)}）" if extras else ""
    return f"{name} — {path}{suffix}"


def _format_size(value: Any) -> str:
    """バイト数を読みやすい表記へ。数字でなければ空文字。"""
    if isinstance(value, bool):
        return ""
    try:
        size = int(value)
    except (TypeError, ValueError):
        return ""
    if size < 0:
        return ""
    if size < 1024:
        return f"{size} B"
    if size < 1024 * 1024:
        return f"{size / 1024:.1f} KB"
    if size < 1024 * 1024 * 1024:
        return f"{size / (1024 * 1024):.1f} MB"
    return f"{size / (1024 * 1024 * 1024):.1f} GB"


def _save_download(job_dir: Path, name: str, data: bytes) -> str:
    """research/downloads/ へ保存し、job からの相対パスを返す。同名は連番でずらす。"""
    downloads = job_dir / "research" / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    target = ensure_contained(downloads / name, job_dir)
    if target.exists() or target.is_symlink():
        stem, suffix = target.stem, target.suffix
        for counter in range(2, 1000):
            candidate = ensure_contained(downloads / f"{stem}-{counter}{suffix}", job_dir)
            if not candidate.exists() and not candidate.is_symlink():
                target = candidate
                break
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    return target.relative_to(job_dir.resolve()).as_posix()


def _operate(hub: MacControlHub, job: Any, kind: str, kwargs: dict[str, Any]) -> str:
    params, device_id = _split_device(kwargs)
    run_id = getattr(job, "_mac_run_id", None) or ""
    if not run_id:
        return _json(
            MacControlError(
                "unavailable",
                "このツールは Hermes の実行からしか呼べない（run が紐付いていない）",
            )
        )
    try:
        outcome = hub.run_operation(
            job_id=job.id,
            run_id=run_id,
            kind=kind,
            params=params,
            device_id=device_id,
        )
    except MacControlError as error:
        return _json(error)
    return _json(outcome)


def make_handlers(hub: MacControlHub, job: Any) -> dict[str, Callable[..., str]]:
    """Hermes ``handler(args_dict, **kwargs)`` 契約。job に run id が載っている。"""

    def _bind(func: Callable[..., str]) -> Callable[..., str]:
        def handler(args: Any = None, **kwargs: Any) -> str:
            merged: dict[str, Any] = {}
            if isinstance(args, dict):
                merged.update(args)
            merged.update(kwargs)
            return func(hub, job, **merged)

        return handler

    return {
        "mac_capture": _bind(mac_capture_impl),
        "mac_click": _bind(mac_click_impl),
        "mac_double_click": _bind(mac_double_click_impl),
        "mac_drag": _bind(mac_drag_impl),
        "mac_scroll": _bind(mac_scroll_impl),
        "mac_type_text": _bind(mac_type_text_impl),
        "mac_key": _bind(mac_key_impl),
        "mac_activate_app": _bind(mac_activate_app_impl),
        "mac_find_files": _bind(mac_find_files_impl),
        "mac_fetch_file": _bind(mac_fetch_file_impl),
        "mac_hand_off_file": _bind(mac_hand_off_file_impl),
    }


class MacRunJob:
    """register_mac_tools が hub に作る run を、ツール実装へ運ぶ最小の job 包み。"""

    def __init__(self, job: Any, run_id: str) -> None:
        self.id = job.id
        self.directory = Path(job.directory)
        self._mac_run_id = run_id

    @property
    def title(self) -> str:
        return ""


def register_mac_tools(
    job: Any,
    hub: MacControlHub,
    run_id: str,
) -> Callable[[], None] | None:
    """Room の ``mac_*`` ツールを Hermes の registry へ登録する。

    戻り値は復元関数。Hermes の registry が import できない（fake-agent の
    テスト）ときは ``None`` を返し、何も登録しない。
    """
    try:
        from tools.registry import registry
    except ImportError:
        return None
    carrier = MacRunJob(job, run_id)
    handlers = make_handlers(hub, carrier)
    registered: list[str] = []
    for name in TOOL_NAMES:
        schema = _SCHEMAS[name]
        try:
            registry.register(
                name,
                TOOLSET_NAME,
                schema,
                handlers[name],
                description=schema["function"]["description"],
                emoji="🖱️",
            )
        except TypeError as exc:
            logger.error("mac tool register failed for %s: %s", name, exc)
            for done in registered:
                try:
                    registry.deregister(done)
                except Exception:
                    pass
            raise
        except Exception:
            logger.debug("mac tool %s already registered", name, exc_info=True)
            continue
        registered.append(name)

    def restore() -> None:
        try:
            from tools.registry import registry as live
        except ImportError:
            return
        for name in registered:
            try:
                live.deregister(name)
            except Exception:
                pass

    return restore
