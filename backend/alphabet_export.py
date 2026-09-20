"""Convert the pinned MIT static-letter MLP to data-only native inference.

Requires numpy/h5py, never imports upstream Python or deserializes pickle.
Upstream tests were used during its training: this is replication, not a
held-out-signer accuracy claim. J/Z are deliberately absent.
"""
import argparse
import hashlib
import json
from pathlib import Path
import pickletools
import string

LETTERS = [c for c in string.ascii_uppercase if c not in "JZ"]
REVISION = "74b976b536ab8318dab756a3071a681d5c75bcb0"
HASHES = {
    "models/asl_static_model.h5": "ef6d4a2763e798a14df8ae83ab58ab34123fbcf298154a830871d7cc9a9eae45",
    "data/processed_v2/mean.npy": "8393adc560d0be7b910b430614dfb13abf1fa32bb6603b1aa7aeb44e4f91ff46",
    "data/processed_v2/std.npy": "33f6302ee363d971085ca05d5aa41b163a00ad12c0b1e1dfe2fb511adeb0858f",
    "data/processed_v2/X_test.npy": "256a21dfc7935501a8042b19b5b708c41f14c6d5335b26efbdef23298fa6ca0b",
    "data/processed_v2/y_test.npy": "5a7c641d79f0cfe4f05152c6b3a2712decbe77ecc7750d9469e929589530cf00",
    "models/static_label_encoder.pkl": "54ff779aba1412c932a302fb05bb5751dae53608c263d558bdd0726ee91e5e81",
}


def features(raw):
    import numpy as np
    points = np.asarray(raw).reshape(21, 3)
    tips, mcps = [4, 8, 12, 16, 20], [2, 5, 9, 13, 17]
    distance = lambda a, b: float(np.linalg.norm(points[a]-points[b]))
    palm = points[9]-points[0]
    result = list(points.flatten())
    result += [distance(t, 0) for t in tips]
    result += [distance(a, b) for a, b in zip(tips[:-1], tips[1:])]
    result += [distance(t, m) for t, m in zip(tips, mcps)]
    result += list(palm)
    for t, m in zip(tips, mcps):
        v = points[t]-points[m]
        cosine = np.dot(v, palm)/(np.linalg.norm(v)*np.linalg.norm(palm)+1e-8)
        result.append(float(np.arccos(np.clip(cosine, -1, 1))*180/np.pi))
    result.append(max(distance(a, b) for i, a in enumerate(tips) for b in tips[i+1:]))
    return np.asarray(result)


def predict(model, normalized):
    import numpy as np
    x = np.asarray(normalized, dtype=np.float32)
    for layer in model["layers"]:
        w = np.asarray(layer["weights"], dtype=np.float32).reshape(layer["input"], layer["output"])
        x = x@w + np.asarray(layer["bias"], dtype=np.float32)
        if layer["relu"]:
            x = np.maximum(x, 0)
        x = x*np.asarray(layer["scale"], dtype=np.float32)+np.asarray(layer["offset"], dtype=np.float32)
    x = np.exp(x-np.max(x, axis=-1, keepdims=True))
    return x/np.sum(x, axis=-1, keepdims=True)


def export(root, out, fixture):
    import h5py
    import numpy as np
    for name, sha in HASHES.items():
        if hashlib.sha256((root/name).read_bytes()).hexdigest() != sha:
            raise ValueError("Pinned alphabet input changed: "+name)
    # Check label bytes without invoking any pickle constructors.
    literals = [arg for op, arg, _ in pickletools.genops((root/"models/static_label_encoder.pkl").read_bytes())
                if op.name in ("SHORT_BINBYTES", "BINBYTES") and isinstance(arg, bytes) and len(arg) == 96]
    if literals != ["".join(LETTERS).encode("utf-32-le")]:
        raise ValueError("Unexpected class order")
    model = dict(version=1, labels=LETTERS, sourceRevision=REVISION, layers=[])
    folder = root/"data/processed_v2"
    mean = np.load(folder/"mean.npy", allow_pickle=False)
    std = np.load(folder/"std.npy", allow_pickle=False)
    model.update(mean=mean.tolist(), std=std.tolist())
    with h5py.File(root/"models/asl_static_model.h5", "r") as f:
        config = json.loads(f.attrs["model_config"])["config"]["layers"]
        for layer in config:
            c = layer["config"]
            if layer["class_name"] == "Dense":
                group = f["model_weights"][c["name"]][c["name"]]
                w, b = group["kernel:0"][:], group["bias:0"][:]
                assert c["activation"] in ("relu", "softmax")
                model["layers"].append(dict(input=w.shape[0], output=w.shape[1],
                    weights=w.flatten().tolist(), bias=b.tolist(), relu=c["activation"] == "relu",
                    scale=np.ones(len(b)).tolist(), offset=np.zeros(len(b)).tolist()))
            elif layer["class_name"] == "BatchNormalization":
                group = f["model_weights"][c["name"]][c["name"]]
                scale = group["gamma:0"][:]/np.sqrt(group["moving_variance:0"][:]+c["epsilon"])
                offset = group["beta:0"][:]-group["moving_mean:0"][:]*scale
                model["layers"][-1].update(scale=scale.tolist(), offset=offset.tolist())
            elif layer["class_name"] not in ("InputLayer", "Dropout"):
                raise ValueError("Unsupported model operation")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(model, separators=(",", ":"), allow_nan=False))
    x = np.load(folder/"X_test.npy", allow_pickle=False)
    y = np.load(folder/"y_test.npy", allow_pickle=False)
    keep = ~np.isin(y, [9, 25])  # J and Z in full A-Z order.
    x, y = x[keep], y[keep]
    labels = [string.ascii_uppercase[int(i)] for i in y]
    scores = predict(model, x)
    # Recover real raw points from the upstream normalized feature matrix, and
    # independently reconstruct all engineered channels before the Swift port.
    raw = x[:, :63]*std[:63]+mean[:63]
    rebuilt = (np.array([features(r) for r in raw])-mean)/std
    error = float(np.max(np.abs(rebuilt-x)))
    if error > 1e-4:
        raise ValueError(f"Feature reconstruction mismatch: {error}")
    report = dict(samples=len(x), correct=sum(LETTERS[int(i)] == l for i, l in zip(scores.argmax(1), labels)),
                  feature_max_error=error, scope="Upstream reused test set, not fresh/live/signer-heldout",
                  per_letter={l: dict(total=labels.count(l),
                      correct=sum(LETTERS[int(i)] == l for i, truth in zip(scores.argmax(1), labels) if truth == l))
                      for l in LETTERS})
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(json.dumps(dict(report=report, rows=[
        dict(label=l, raw=r.tolist(), normalized=v.tolist(), scores=s.tolist())
        for l, r, v, s in zip(labels, raw, x, scores)]), separators=(",", ":")))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--upstream", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--fixture", type=Path, required=True)
    a = p.parse_args()
    if ".runtime" not in a.fixture.resolve().parts:
        p.error("Keep upstream sample fixtures in private .runtime")
    export(a.upstream, a.out, a.fixture)
