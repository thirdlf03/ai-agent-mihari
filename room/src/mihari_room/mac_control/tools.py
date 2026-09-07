"""Hermes の Room 専用ツール群（``mac_*``）。

汎用 Computer Use / shell は有効化しない。撮影・クリック・ダブルクリック・
ドラッグ・スクロール・文字入力・キー操作・アプリ切り替えを Room の hub 経由で
Mac へ送る。hub が許可・端末・画面構成・操作 ID を検証する。

登録は既存の discord_* / cloudflare_temp_deploy と同じく ``tools.registry`` へ
ジョブ単位で行い、実行後は復元する。本家 Hermes が入っていない環境
（tests）では ``register_mac_tools`` は ``None`` を返す（discord と同じ）。
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

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
