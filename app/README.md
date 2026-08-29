# app/（デスクトップペット）

デスクトップの最前面に浮かぶペット `MacApp`。スプライトのアニメーション・吹き出し・
ドラッグ・メニューを持つ。使い方と素材の作り方は[ルートの README](../README.md#ペット)にある。

もともとは `device-bridge` CLI を起動して iOS デバイス一覧を表示するだけのアプリだった。
その経路は `bridge/` の常駐デーモンに置き換わっているが、
`Bridge/DeviceBridge.swift` には Wi-Fi 経由で iPhone に繋ぐときの実装
（`uv` の探索、サブプロセスの stdout/stderr をデッドロックさせずに読む書き方）が残っており、
移植や不具合調査のときに読む価値がある。

## Mihari 本体との関係

**まだ繋がっていない。** サボり検知は `desktop/` の `Mihari` が担っていて、
そちらには差し替え用の暫定表示（画像 1 枚）と連携インターフェースだけが入っている。

繋ぐときは `desktop/Sources/MihariCore/Pet/PetPresenting.swift` の protocol に
このペットを適合させ、`RootView` で差し替える。渡ってくるイベントの型は
`PetEvent`（状態 / エスカレーション段階 / セリフ / Vision のラベル / はい・いいえの問いかけ）。

## 動かす

```sh
make app-build   # ビルド
make app-run     # 起動
```
