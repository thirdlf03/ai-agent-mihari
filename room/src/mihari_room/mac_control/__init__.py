"""依頼単位の Mac 操作（Issue #23）。

Hermes の Room 専用ツール（``mac_*``）と、Mac アプリが張る認証付き WebSocket
（``/ws/mac-control``）を繋ぐ。ジョブ・端末・許可セッション・操作 ID を紐付け、
一度に 1 操作だけを Mac へ送る。既存の汎用 Computer Use / shell は有効化しない。
"""
