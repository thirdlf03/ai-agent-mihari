# app/（参照用・凍結）

**このディレクトリは開発対象ではありません。** アプリ本体は [`desktop/`](../desktop/) にあります。

初期の macOS アプリ（`MacApp`）で、Python の `device-bridge` CLI をサブプロセス起動して
iOS デバイス一覧を表示するだけのものでした。現在この経路は `bridge/` の常駐デーモンに置き換わっています。

## なぜ残しているか

`Bridge/DeviceBridge.swift` に、**Wi-Fi 経由で iPhone に繋ぐときの実装**（`uv` の探索、
サブプロセスの stdout/stderr をデッドロックさせずに読む書き方）が入っており、
移植や不具合調査のときに読む価値があるためです。

参照が不要になったら削除して構いません。

## 動かす場合

```sh
make app-build   # ビルド
make app-run     # 起動
```
