"""device-bridge の CLI エントリポイント。

stdout には常に JSON を 1 つだけ出力する。失敗時は stderr に
``{"error": "<message>"}`` を出力し、終了コード 1 で終了する。
"""

import argparse
import json
import sys
from typing import Any

from device_bridge.commands import devices


def main() -> int:
    """CLI のエントリポイント。

    :returns: 終了コード。成功なら 0、失敗なら 1。
    """
    parser = _build_parser()
    args = parser.parse_args()

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

    return parser


def _dispatch(args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "list":
        return devices.list_devices(wifi=not args.no_wifi)
    if args.command == "info":
        return devices.device_info(args.udid)
    raise ValueError(f"unknown command: {args.command}")


if __name__ == "__main__":
    sys.exit(main())
