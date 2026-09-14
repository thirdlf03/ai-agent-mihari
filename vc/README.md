# vc/ — 声質変換アダプタ

room の `live_audio` モード(`MIHARI_VOICE_OUTPUT_MODE=live_audio`)で使う外部 VC
サービスの実装。`MIHARI_VC_URL` が指す HTTP 契約に従う
(`docs/voice-realtime-contract.md` の「VC サービス契約」参照)。

## meanvc2_server.py

[MeanVC2](https://github.com/ASLP-lab/MeanVC2)(ストリーミング VC)を
`VCRunner` 経由で包んだアダプタ。入力 24 kHz f32 → 内部 16 kHz → 出力を
24 kHz へ戻す。`/reset` で発話ごとに状態をリセット、`/flush` で末尾の
バッファを流し切る。

### セットアップ

1. MeanVC2 をチェックアウトし、公式手順で ckpt を配置する
   (`ckpts/`、`preprocess/ckpts/` が必要)
2. 依存を入れた venv を作る(torch / fastapi / uvicorn / scipy /
   numpy + MeanVC2 が import するもの)
3. fine-tune 済み checkpoint とターゲット話者の参照 wav を用意する

### 起動

```sh
python meanvc2_server.py \
    --meanvc2-root /path/to/MeanVC2 \
    --ckpt /path/to/himari_ft_3000.pt \
    --target /path/to/reference_himari.wav \
    --port 18995
```

room 側は次の env で繋ぐ:

```sh
MIHARI_VOICE_OUTPUT_MODE=live_audio
MIHARI_VC_URL=http://127.0.0.1:18995
MIHARI_LIVE_MODEL=gpt-live-1   # 既定
MIHARI_LIVE_VOICE=marin        # 既定。VC 前の素の声
```

`--model 40ms` / `--device` でレイテンシと推論デバイスを変えられる。
チェックポイントを外すと事前学習モデルのゼロショット変換になる
(参照 wav の話者に寄せる)。
