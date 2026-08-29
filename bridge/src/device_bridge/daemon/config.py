"""デーモンの起動設定。"""

from __future__ import annotations

from dataclasses import dataclass

#: 待ち受けるホスト。ローカル以外からは絶対に触らせないため固定する。
LOOPBACK_HOST = "127.0.0.1"

#: 認証トークンを載せるヘッダ名。
TOKEN_HEADER = "X-Mihari-Token"


@dataclass(frozen=True, slots=True)
class DaemonConfig:
    """デーモン 1 プロセス分の設定。

    :param token: macOS アプリと共有する認証トークン。起動のたびにアプリ側が生成する。
    :param port: 待ち受けポート。0 なら OS に空きポートを選ばせる。
    :param host: 待ち受けホスト。既定はループバックのみ。
    """

    token: str
    port: int = 0
    host: str = LOOPBACK_HOST

    def __post_init__(self) -> None:
        if not self.token:
            raise ValueError("token は空にできない")
        if not 0 <= self.port <= 65535:
            raise ValueError(f"port が範囲外: {self.port}")
        if self.host != LOOPBACK_HOST:
            # 監視対象の画面やカメラ画像を扱うため、外部からの接続経路は作らない。
            raise ValueError(f"host はループバックのみ許可する: {self.host}")
