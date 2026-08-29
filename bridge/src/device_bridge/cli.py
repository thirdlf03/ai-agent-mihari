"""device-bridge の CLI エントリポイント。

``list`` / ``info`` は stdout に JSON を 1 つだけ出力して終了する。失敗時は stderr に
``{"error": "<message>"}`` を出力し、終了コード 1 で終了する。

``serve`` は常駐デーモンを起動する。stdout に ``{"port": ..., "pid": ...}`` を 1 行だけ出し、
以降は終了までブロックする。macOS アプリはこの 1 行を読んで接続先を知る。
"""

import argparse
import json
import sys
from typing import Any

from device_bridge.commands import devices
from device_bridge.daemon.config import DaemonConfig
from device_bridge.daemon.server import serve


def main() -> int:
    """CLI のエントリポイント。

    :returns: 終了コード。成功なら 0、失敗なら 1。
    """
    parser = _build_parser()
    args = parser.parse_args()

    if args.command == "serve":
        return _serve(args)

    try:
        result = _dispatch(args)
    except Exception as error:  # noqa: BLE001 - 例外は JSON エラーとして返す
        message = str(error) or type(error).__name__
        print(json.dumps({"error": message}, ensure_ascii=False), file=sys.stderr)
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="device-bridge", description="iOS デバイス情報を JSON で出力する"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="接続中のデバイスを一覧表示する")
    list_parser.add_argument(
        "--no-wifi", action="store_true", help="Wi-Fi 経由のデバイス探索を省略する"
    )

    info_parser = subparsers.add_parser("info", help="指定したデバイスの基本情報を表示する")
    info_parser.add_argument("--udid", required=True, help="対象デバイスの UDID")

    serve_parser = subparsers.add_parser("serve", help="常駐デーモンを起動する")
    serve_parser.add_argument("--token", required=True, help="macOS アプリと共有する認証トークン")
    serve_parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="待ち受けポート。0 なら OS に空きポートを選ばせる(既定)",
    )

    return parser


def _serve(args: argparse.Namespace) -> int:
    """デーモンを起動する。終了するまで戻らない。"""
    try:
        config = DaemonConfig(token=args.token, port=args.port)
    except ValueError as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1

    try:
        serve(config)
    except KeyboardInterrupt:
        return 0
    except Exception as error:  # noqa: BLE001 - 起動失敗は JSON エラーとして返す
        message = str(error) or type(error).__name__
        print(json.dumps({"error": message}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


def _dispatch(args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "list":
        return devices.list_devices(wifi=not args.no_wifi)
    if args.command == "info":
        return devices.device_info(args.udid)
    raise ValueError(f"unknown command: {args.command}")


if __name__ == "__main__":
    sys.exit(main())
