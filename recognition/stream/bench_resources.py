"""Startup time, memory, per-window latency and throughput for each provider, plus Core ML conversion
feasibility. Each provider is measured in a fresh subprocess so RSS numbers are not polluted. HOST
numbers (this Mac); no iPhone has been used.

    python -m recognition.stream.bench_resources --out .runtime/stream/resources.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

CHILD = r'''
import json, sys, time, os
import numpy as np, psutil, torch
t0 = time.perf_counter()
from recognition.stream.poseio import WLASLPoses
from recognition.stream.openhands_provider import OpenHandsProvider, ROOT
arch, device = sys.argv[1], sys.argv[2]
P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
proc = psutil.Process(os.getpid()); rss0 = proc.memory_info().rss
t1 = time.perf_counter()
prov = OpenHandsProvider(arch, P.glosses, device=device)
load = time.perf_counter() - t1
rss1 = proc.memory_info().rss
vals = [it for it in P.split("val") if len(P.clip(it[0])[0]) >= 50][:64]
wins = [P.window(v, 0.0, 2.0) for v, _, _ in vals]        # 2.0 s windows (the setting the streaming study selected)
def sync():
    if device == "mps": torch.mps.synchronize()
prov.logits(wins[:4]); sync()
lat = []
for w in wins[:48]:
    t = time.perf_counter(); prov.logits([w]); sync(); lat.append((time.perf_counter() - t) * 1000)
t = time.perf_counter(); prov.logits(wins); sync(); thr = len(wins) / (time.perf_counter() - t)
print(json.dumps({"arch": arch, "device": device, "import_s": round(t1 - t0, 2), "model_load_s": round(load, 2),
      "rss_mb_after_load": round(rss1 / 1e6), "rss_delta_model_mb": round((rss1 - rss0) / 1e6),
      "latency_ms_p50": round(float(np.percentile(lat, 50)), 2), "latency_ms_p95": round(float(np.percentile(lat, 95)), 2),
      "throughput_windows_per_s_batch64": round(thr, 1), "params": prov.params}))
'''

COREML = r'''
import json, sys, os, tempfile
import numpy as np, torch
sys.path.insert(0, ".")
from recognition.stream.poseio import WLASLPoses
from recognition.stream.openhands_provider import OpenHandsProvider, ROOT
import coremltools as ct
arch = sys.argv[1]
prec = sys.argv[2] if len(sys.argv) > 2 else "fp16"
P = WLASLPoses(ROOT / "WLASL_pose.zip", ROOT / "wlasl_metadata/splits/asl2000.json")
prov = OpenHandsProvider(arch, P.glosses); prov.model.eval()
vals = [it for it in P.split("val") if len(P.clip(it[0])[0]) >= 50][:40]
real = [prov._prep(P.window(v, 0.0, 2.0)).contiguous() for v, _, _ in vals]       # real 2.0 s windows, exactly 50 frames (bert: 120 after its own subsampling)
T = real[0].shape[1]
res = {"arch": arch, "precision": prec, "fixed_frames": T, "input": "real 2.0 s val windows"}
try:
    ep = torch.export.export(prov.model, (real[0][None],)).run_decompositions({})
    ml = ct.convert(ep, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
    with tempfile.TemporaryDirectory() as d:
        ml.save(d + "/m.mlpackage")
        size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(d) for f in fs)
        loaded = ct.models.MLModel(d + "/m.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
        name = ml.get_spec().description.input[0].name
        diffs, agree, top5 = [], [], []
        for x in real:
            with torch.no_grad(): ref = prov.model(x[None]).numpy()[0]
            got = np.asarray(list(loaded.predict({name: x[None].numpy()}).values())[0]).reshape(-1)
            diffs.append(float(np.abs(ref - got).max())); agree.append(int(ref.argmax() == got.argmax()))
            top5.append(len(set(np.argsort(-ref)[:5]) & set(np.argsort(-got)[:5])) / 5)
        res |= {"converted": True, "package_mb": round(size / 1e6, 1), "max_abs_logit_diff": max(diffs), "median_abs_logit_diff": float(np.median(diffs)),
                "top1_agreement": float(np.mean(agree)), "top5_overlap": float(np.mean(top5)), "windows": len(real)}
except Exception as e:
    res |= {"converted": False, "error": (type(e).__name__ + ": " + str(e))[:220]}
print(json.dumps(res))
'''


def sh(code, *args):
    out = subprocess.run([sys.executable, "-c", code, *args], capture_output=True, text=True, cwd=Path(__file__).resolve().parents[2])
    lines = [l for l in out.stdout.splitlines() if l.startswith("{")]
    return json.loads(lines[-1]) if lines else {"error": out.stderr[-300:]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--coreml", action="store_true")
    a = ap.parse_args()
    res = {"host": "Apple M4 Mac (NOT an iPhone)", "runtime": []}
    for arch in ("lstm", "bert", "stgcn", "slgcn"):
        for device in ("cpu", "mps"):
            r = sh(CHILD, arch, device)
            res["runtime"].append(r)
            print(r, flush=True)
    if a.coreml:
        res["coreml"] = []
        for arch, prec in (("lstm", "fp16"), ("bert", "fp16"), ("bert", "fp32"), ("stgcn", "fp16"), ("slgcn", "fp16")):
            r = sh(COREML, arch, prec)
            res["coreml"].append(r)
            print(r, flush=True)
    Path(a.out).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
