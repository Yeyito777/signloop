"""Small static-letter MLP trained on the pinned upstream coordinate dataset.

No videos, no providers, no pickle. The source has no signer/session IDs, so
sample-split results cannot establish generalization to a new signer.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import string
from .alphabet_export import LETTERS, REVISION, HASHES, features, predict

TRAIN_HASHES = {
    "X_train.npy": "764468119867c9af3d483c3f5c445e4c7f6b7aa8c1c08c338152847e49150bd2",
    "y_train.npy": "1c42e9f29003e8c8ad58f6ac1dca8b9529826e9fabfc482571238ab9d21dbf80",
}


def train(root, out, fixture):
    import numpy as np
    import torch
    from torch import nn
    torch.set_num_threads(4)
    torch.manual_seed(732)
    np.random.seed(732)
    folder = root/"data/processed_v2"
    for name, sha in TRAIN_HASHES.items():
        if hashlib.sha256((folder/name).read_bytes()).hexdigest() != sha:
            raise ValueError("Training data changed")
    for name in ("mean.npy", "std.npy", "X_test.npy", "y_test.npy"):
        if hashlib.sha256((folder/name).read_bytes()).hexdigest() != HASHES["data/processed_v2/"+name]:
            raise ValueError("Evaluation/normalization data changed")
    old_mean = np.load(folder/"mean.npy", allow_pickle=False)
    old_std = np.load(folder/"std.npy", allow_pickle=False)
    x = np.load(folder/"X_train.npy", allow_pickle=False)*old_std+old_mean
    y = np.load(folder/"y_train.npy", allow_pickle=False)
    keep = ~np.isin(y, [9, 25])
    x, y = x[keep], y[keep]
    y = np.asarray([LETTERS.index(string.ascii_uppercase[int(i)]) for i in y])
    # Deterministic class-balanced internal validation, exclusively source train.
    fit, val = [], []
    for label in range(24):
        indices = np.where(y == label)[0]
        indices = sorted(indices, key=lambda i: hashlib.sha256(str(int(i)).encode()).hexdigest())
        n = max(1,len(indices)//5)
        val.extend(indices[:n]); fit.extend(indices[n:])
    fit, val = np.asarray(fit), np.asarray(val)
    mean, std = x[fit].mean(0), x[fit].std(0)
    std[std < 1e-8] = 1
    normalized = ((x-mean)/std).astype(np.float32)
    xt, yt = torch.from_numpy(normalized), torch.from_numpy(y).long()
    sizes = [86, 256, 128, 64, 32, 24]
    modules = []
    for i in range(5):
        modules.append(nn.Linear(sizes[i], sizes[i+1]))
        if i < 4: modules.extend([nn.ReLU(), nn.Dropout(.15)])
    network = nn.Sequential(*modules)
    optimizer = torch.optim.AdamW(network.parameters(),lr=.001,weight_decay=.0001)
    best = None
    best_loss, stale, chosen_epoch = float("inf"), 0, 0
    for epoch in range(150):
        network.train()
        for batch in torch.randperm(len(fit)).split(128):
            indices = fit[batch.numpy()]
            optimizer.zero_grad()
            loss = nn.functional.cross_entropy(network(xt[indices]),yt[indices])
            loss.backward(); optimizer.step()
        network.eval()
        with torch.inference_mode():
            validation = float(nn.functional.cross_entropy(network(xt[val]),yt[val]))
        if validation < best_loss-1e-4:
            best_loss, stale, chosen_epoch = validation, 0, epoch+1
            best = copy.deepcopy(network.state_dict())
        else: stale += 1
        if stale >= 20: break
    network.load_state_dict(best)
    network.eval()
    model = dict(version=1, sourceRevision=REVISION, labels=LETTERS,
                 mean=mean.tolist(),std=std.tolist(),layers=[])
    for i, layer in enumerate(m for m in network if isinstance(m,nn.Linear)):
        w = layer.weight.detach().numpy().T
        b = layer.bias.detach().numpy()
        model["layers"].append(dict(input=w.shape[0],output=w.shape[1],weights=w.flatten().tolist(),
                                   bias=b.tolist(),relu=i<4,scale=np.ones(len(b)).tolist(),
                                   offset=np.zeros(len(b)).tolist()))
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(model,separators=(",",":"),allow_nan=False))
    # Read source test only after all fitting/checkpoint selection is finished.
    test = np.load(folder/"X_test.npy",allow_pickle=False)*old_std+old_mean
    target = np.load(folder/"y_test.npy",allow_pickle=False)
    mask = ~np.isin(target,[9,25])
    test, target = test[mask],target[mask]
    labels = [string.ascii_uppercase[int(i)] for i in target]
    normalized_test = ((test-mean)/std).astype(np.float32)
    scores = predict(model,normalized_test)
    with torch.inference_mode():
        reference = torch.softmax(network(torch.from_numpy(normalized_test)),dim=1).numpy()
    if not np.allclose(scores,reference,atol=1e-5):raise ValueError("Torch/native export math mismatch")
    rebuilt = np.asarray([features(r[:63]) for r in test])
    if not np.allclose(rebuilt,test,atol=1e-7):raise ValueError("Raw input reconstruction failed")
    with torch.inference_mode():
        val_correct = int((network(xt[val]).argmax(1)==yt[val]).sum())
    report = dict(source_train=len(x),fit=len(fit),validation=len(val),selected_epoch=chosen_epoch,
        validation_correct=val_correct,samples=len(test),
        correct=sum(LETTERS[int(i)]==l for i,l in zip(scores.argmax(1),labels)),
        scope="Source sample splits, no signer/session IDs. Previously inspected test; not blind/live accuracy.",
        per_letter={l:dict(total=labels.count(l),correct=sum(LETTERS[int(i)]==l
            for i,truth in zip(scores.argmax(1),labels) if truth==l)) for l in LETTERS})
    fixture.parent.mkdir(parents=True,exist_ok=True)
    fixture.write_text(json.dumps(dict(report=report,rows=[
        dict(label=l,raw=r[:63].tolist(),normalized=n.tolist(),scores=s.tolist())
        for l,r,n,s in zip(labels,test,normalized_test,scores)]),separators=(",",":")))
    print(json.dumps(report,indent=2))


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--upstream",type=Path,required=True)
    p.add_argument("--out",type=Path,required=True)
    p.add_argument("--fixture",type=Path,required=True)
    a=p.parse_args()
    if ".runtime" not in a.fixture.resolve().parts:p.error("Private fixture output required")
    train(a.upstream,a.out,a.fixture)
