"""Golden vectors for Swift parity (features, segmenter, decision rule).

    python -m recognition.golden --out ios/Tests/Fixtures/sign_engine_golden.json
    python -m recognition.golden --coreml-dir .runtime/export/syn-dual --out .runtime/coreml_golden.json

The first file is committed and verifies that the Swift port produces the same tensors, the
same segmentation trace and the same decisions as this reference. The second is local-only: it
pins Core ML output for a specific exported model.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

import numpy as np

from . import synthetic as S
from .features import FeatureConfig, featurize_frames
from .openset import Policy, decide, scores
from .segmenter import Segmenter, SegmenterConfig


def rounded(frames, nd=5):
    out = copy.deepcopy(frames)
    for f in out:
        for h in f["hands"]:
            h["handednessScore"] = round(h["handednessScore"], nd)
            for j in h["joints"]:
                for k in "xyz":
                    j[k] = round(j[k], nd)
    return out


def feat_json(f):
    r = lambda a: np.round(a.astype(np.float64), 6).ravel().tolist()
    return {"nodes": r(f.nodes), "glob": r(f.glob), "motion": r(f.motion), "mask": r(f.mask), "meta": r(f.meta),
            "quality": round(float(f.tracking_quality), 6)}


def cfg_json(c):
    return dict(c.__dict__)


def feature_cases():
    rng = np.random.default_rng(7)
    sg = S.Signer.sample(rng, 7)
    sg.drop, sg.left_handed = 0.0, False
    cases = []
    base = rounded(S.make_sign("S_FLAT_WAVE", sg, rng))
    cases.append(("clean-one-hand", base, FeatureConfig(steps=16)))
    gappy = copy.deepcopy(base)
    for i in (5, 6):                       # short gap: bridged (mask 0.5)
        gappy[i]["hands"] = []
    for i in range(12, 19):                # long gap: masked, zero features
        if i < len(gappy):
            gappy[i]["hands"] = []
    cases.append(("gaps", gappy, FeatureConfig(steps=16)))
    un = copy.deepcopy(rounded(S.make_sign("S_POINT_CIRCLE", sg, rng)))
    for f in un:                           # unmirrored camera: reflection + handedness swap
        f["mirrored"] = False
        for h in f["hands"]:
            h["handedness"] = "Left"
            for j in h["joints"]:
                j["x"] = round(1 - j["x"], 5)
    cases.append(("unmirrored-left-label", un, FeatureConfig(steps=16)))
    two = copy.deepcopy(base)
    for f in two:                          # second hand offset to the left, other slot
        if f["hands"]:
            h2 = copy.deepcopy(f["hands"][0])
            h2["handedness"] = "Left"
            for j in h2["joints"]:
                j["x"] = round(j["x"] - 0.25, 5)
                j["y"] = round(j["y"] + 0.05, 5)
            f["hands"].append(h2)
    cases.append(("two-hands", two, FeatureConfig(steps=16)))
    cases.append(("no-derivatives-no-angles", base, FeatureConfig(steps=16, derivatives=False, angles=False)))
    return [{"name": n, "config": cfg_json(c), "frames": fr, "expected": feat_json(featurize_frames(fr, c))} for n, fr, c in cases]


def segmenter_case():
    rng = np.random.default_rng(11)
    sg = S.Signer.sample(rng, 11)
    sg.drop = 0.03
    sg.left_handed = False
    plan = [("idle", "-"), ("sign", "S_FLAT_WAVE"), ("idle", "-"), ("sign", "S_Y_STATIC"), ("idle", "-"),
            ("neg", "random_motion"), ("idle", "-"), ("sign", "S_FIST_BOB"), ("idle", "-"), ("sign", "S_OPEN_CLOSE"), ("idle", "-")]
    frames, intervals = S.make_stream(sg, plan, rng)
    frames = rounded(frames)
    cfg = SegmenterConfig()
    seg, states, segments = Segmenter(cfg), [], []
    for f in frames:
        s = seg.update(f)
        if s is not None:
            segments.append({"start_ms": s.start_ms, "end_ms": s.end_ms, "reason": s.reason, "n_frames": len(s.frames)})
            seg.finish(f["timestampMS"])
        states.append(seg.state.value)
    return {"config": cfg_json(cfg), "frames": frames, "intervals": intervals, "expected_states": states,
            "expected_segments": segments}


def decision_cases():
    known = ["A", "B", "C"]
    rng = np.random.default_rng(5)
    out = []
    for scorer in ("log_odds", "max_prob", "entropy", "margin", "energy"):
        pol = Policy(scorer, 0.7, tau_high=2.0 if scorer in ("log_odds", "energy") else 0.8, tau_low=0.5 if scorer in ("log_odds", "energy") else 0.4,
                     quality_min=0.5, known=known, target_far_high=0.05, target_far_low=0.2)
        for q in (0.9, 0.3):
            logits = np.round(rng.normal(0, 3, (6, 4)), 4)
            emb = np.zeros((6, 4))
            dec = decide(pol, logits, [q] * 6, emb, None)
            out.append({"policy": pol.to_json(), "logits": logits.tolist(), "quality": q,
                        "expected": [{"index": int(i), "tier": t, "score": round(float(s), 6)} for i, t, s in dec]})
    return out


def coreml_case(export_dir: str):
    import coremltools as ct
    d = Path(export_dir)
    policy = json.loads((d / "policy.json").read_text())
    fcfg = FeatureConfig(**policy["feature"])
    model = ct.models.MLModel(str(d / "SignEngine.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    rng = np.random.default_rng(3)
    sg = S.Signer.sample(rng, 3)
    sg.drop, sg.left_handed = 0.0, False
    cases = []
    for cls in S.CLASSES[:4]:
        fr = rounded(S.make_sign(cls, sg, rng))
        f = featurize_frames(fr, fcfg)
        pred = model.predict({"nodes": f.nodes[None], "glob": f.glob[None], "motion": f.motion[None],
                              "mask": f.mask[None], "meta": f.meta[None]})
        cases.append({"class": cls, "frames": fr, "logits": np.asarray(pred["logits"]).ravel().tolist(),
                      "features": feat_json(f)})
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--coreml-dir")
    a = ap.parse_args()
    if a.coreml_dir:
        doc = {"coreml": coreml_case(a.coreml_dir)}
    else:
        doc = {"feature_cases": feature_cases(), "segmenter": segmenter_case(), "decisions": decision_cases()}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(doc, separators=(",", ":")))
    print(a.out, Path(a.out).stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
