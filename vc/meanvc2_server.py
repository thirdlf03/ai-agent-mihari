"""MeanVC2 ストリーミング VC アダプタ(room の live_audio モード用バックエンド)。

room の ``MIHARI_VC_URL`` が指す外部 VC サービス契約を実装する。
契約は ``docs/voice-realtime-contract.md`` の「VC サービス契約」参照:

    POST {base}/convert
        request  body: float32 mono 24000 Hz raw bytes (application/octet-stream)
        response body: float32 mono 24000 Hz raw bytes (application/octet-stream)
    POST {base}/reset   -- 発話/セッション開始時に内部状態をリセット
    POST {base}/flush   -- 発話終端。バッファに残る変換済み音声を全て返す
    GET  {base}/health

内部では 24 kHz 入力を 16 kHz へ落として MeanVC2 の ``VCRunner``(Fast-U2++
BN -> DiT FRC -> Vocos、160ms ホップ)へ流し、出力 16 kHz を 24 kHz へ戻す。

必要なもの(リポジトリ外):

- MeanVC2 チェックアウト(ASLP-lab/MeanVC2)+ ckpts/ と preprocess/ckpts/
- fine-tune 済み checkpoint(例: himari_ft_3000.pt)
- ターゲット話者の参照 wav(数秒、16 kHz 以上推奨)

Run:
    python meanvc2_server.py \
        --meanvc2-root /path/to/MeanVC2 \
        --ckpt /path/to/himari_ft_3000.pt \
        --target /path/to/reference_himari.wav \
        --port 18995
"""

import argparse
import logging
import os
import sys
import threading
import time
from pathlib import Path

import numpy as np
import torch
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from scipy.signal import resample_poly

log = logging.getLogger("meanvc2_adapter")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

SR_IO = 24000
SR_INTERNAL = 16000


class MeanVC2Streamer:
    """VCRunner を HTTP 契約に合わせて包む。process_chunk は 160ms 単位で進む。"""

    #: VCRunner.process_chunk の内部ブロック長(160ms @ 16kHz)。
    HOP = 2560

    def __init__(self, meanvc2_root: str, ckpt: str, target_wav: str,
                 model: str = "120ms", device: str = "cpu"):
        root = Path(meanvc2_root).resolve()
        if not (root / "runtime/run_rt.py").exists():
            raise FileNotFoundError(
                f"MeanVC2 の runtime/run_rt.py が見つかりません: {root}"
            )
        target_wav = str(Path(target_wav).resolve())
        ckpt = str(Path(ckpt).resolve()) if ckpt else ""
        cwd = os.getcwd()
        os.chdir(root)
        sys.path.insert(0, str(root / "runtime"))
        try:
            import run_rt
            self.runner = run_rt.VCRunner(target_wav, device=device, model=model)
            if ckpt:
                cfg = root / f"src/config/config_{model}_40ms.json"
                self.runner.vc = run_rt._load_vc_model(str(cfg), ckpt, device)
                with torch.no_grad():
                    self.runner.vc_gtm_kv = self.runner.vc.gtm(self.runner.vc_spk_emb)
        finally:
            os.chdir(cwd)
        self.n_calls = 0
        self.t_total = 0.0
        self._pending = np.zeros(0, dtype=np.float32)
        log.info("model ready: %s", ckpt or "pretrained")

    def reset(self):
        self.runner._init_cache()
        self._pending = np.zeros(0, dtype=np.float32)

    def process(self, pcm24: np.ndarray) -> np.ndarray:
        """24k 入力を受け、現時点で生成できる変換済み音声を返す(0 〜複数ホップ分)。"""
        a16 = resample_poly(pcm24, 2, 3).astype(np.float32)
        self._pending = np.concatenate([self._pending, a16])
        outs = []
        while self._pending.size >= self.HOP:
            take = self._pending[: self.HOP]
            self._pending = self._pending[self.HOP:]
            t0 = time.time()
            out = self.runner.process_chunk(take)
            self.t_total += time.time() - t0
            self.n_calls += 1
            if out is not None and out.size:
                outs.append(out)
        if not outs:
            return np.zeros(0, dtype=np.float32)
        return resample_poly(np.concatenate(outs), 3, 2).astype(np.float32)

    def flush(self) -> np.ndarray:
        """発話終端。残入力と BN バッファを edge-replicate で流し切る。"""
        r = self.runner
        outs = []
        if self._pending.size:
            t0 = time.time()
            out = r.process_chunk(self._pending)
            self.t_total += time.time() - t0
            self.n_calls += 1
            self._pending = np.zeros(0, dtype=np.float32)
            if out is not None and out.size:
                outs.append(out)
        # run_rt.process_file と同じ drain: BN バッファの残りを edge-replicate で流す
        while r.bn_buffer is not None and r.bn_buffer.shape[1] >= r.chunk_size:
            pad_cur = r.bn_buffer[:, : r.chunk_size, :]
            if r.bn_buffer.shape[1] > r.chunk_size:
                pad_fut = r.bn_buffer[:, r.chunk_size : r._min_bn_len, :]
            else:
                pad_fut = r.bn_buffer[:, -1:, :].repeat(1, r.block_size, 1)
            cond = torch.cat([pad_cur, pad_fut], dim=1)
            r.bn_buffer = r.bn_buffer[:, r.chunk_size:, :]
            if r.bn_buffer.shape[1] == 0:
                r.bn_buffer = None
            mel = r._vc_step(cond)
            outs.append(r._decode_mel(mel))
        if r.bn_buffer is not None and r.bn_buffer.shape[1] > 0:
            n_rem = r.bn_buffer.shape[1]
            last_frame = r.bn_buffer[:, -1:, :]
            pad_cur = last_frame.repeat(1, r.chunk_size, 1)
            pad_cur[:, :n_rem, :] = r.bn_buffer
            pad_fut = last_frame.repeat(1, r.block_size, 1)
            cond = torch.cat([pad_cur, pad_fut], dim=1)
            r.bn_buffer = None
            mel = r._vc_step(cond)
            outs.append(r._decode_mel(mel))
        # vocoder が保持する overlap 末尾を吐き出す
        if r.last_wav is not None:
            outs.append(r.last_wav)
            r.last_wav = None
        outs = [o for o in outs if o is not None and o.size]
        if not outs:
            return np.zeros(0, dtype=np.float32)
        return resample_poly(np.concatenate(outs), 3, 2).astype(np.float32)


app = FastAPI(title="vc-adapter-meanvc2")
streamer: MeanVC2Streamer = None
lock = threading.Lock()


@app.post("/convert")
async def convert(request: Request):
    body = await request.body()
    if len(body) % 4 != 0:
        return JSONResponse(
            {"error": "body length must be a multiple of 4 bytes"}, status_code=400
        )
    pcm = np.frombuffer(body, dtype=np.float32)
    if pcm.size == 0:
        return Response(content=b"", media_type="application/octet-stream")
    with lock:
        out = streamer.process(pcm)
    return Response(content=out.tobytes(), media_type="application/octet-stream")


@app.post("/flush")
async def flush():
    with lock:
        out = streamer.flush()
    return Response(content=out.tobytes(), media_type="application/octet-stream")


@app.post("/reset")
async def reset():
    with lock:
        streamer.reset()
    return {"status": "ok"}


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "calls": streamer.n_calls if streamer else 0,
        "avg_infer_s": round(streamer.t_total / streamer.n_calls, 4)
        if streamer and streamer.n_calls
        else None,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18995)
    parser.add_argument("--host", type=str, default="127.0.0.1")
    parser.add_argument(
        "--meanvc2-root",
        type=str,
        default=os.environ.get("MEANVC2_ROOT", ""),
        help="MeanVC2 チェックアウトのパス(env: MEANVC2_ROOT)",
    )
    parser.add_argument("--ckpt", type=str, default="")
    parser.add_argument("--target", type=str, required=True)
    parser.add_argument("--model", type=str, default="120ms", choices=["120ms", "40ms"])
    parser.add_argument("--device", type=str, default="cpu")
    args = parser.parse_args()

    if not args.meanvc2_root:
        parser.error("--meanvc2-root か MEANVC2_ROOT が必要です")

    streamer = MeanVC2Streamer(
        args.meanvc2_root, args.ckpt, args.target, args.model, args.device
    )
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
