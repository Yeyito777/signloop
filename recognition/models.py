"""Model zoo. Same input dict, same output dict, so every architecture is ablated under an
identical pipeline. All are small enough for a phone (see count_params).

Batch keys:  nodes (B,T,2,21,6)  glob (B,T,2,GW)  motion (B,T,M)  mask (B,T,3)  meta (B,K)
Output:      logits (B, n_out)   emb (B, E)   -- n_out = known classes + 1 (UNKNOWN/background)
"""
from __future__ import annotations

import numpy as np
import torch
from torch import nn
import torch.nn.functional as Fn

from .features import BONES, GLOBAL_WIDTH, N_GLOBAL, N_JOINTS, N_META, N_MOTION, NODE_C

ARCHS = ["single_frame", "mlp", "gru", "tcn", "transformer", "stgcn", "dual"]


def flat_input(b: dict) -> torch.Tensor:
    B, T = b["nodes"].shape[:2]
    return torch.cat([b["nodes"].reshape(B, T, -1), b["glob"].reshape(B, T, -1), b["motion"], b["mask"]], dim=-1)


def flat_dim() -> int:
    return 2 * N_JOINTS * NODE_C + 2 * GLOBAL_WIDTH + N_MOTION + 3


def presence(b: dict) -> torch.Tensor:
    """(B,T) weight: 1 where any hand is observed."""
    return (b["mask"][..., :2].amax(dim=-1) > 0).float()


def masked_mean(h: torch.Tensor, w: torch.Tensor) -> torch.Tensor:
    w = w.unsqueeze(-1)
    return (h * w).sum(1) / w.sum(1).clamp_min(1.0)


class Head(nn.Module):
    def __init__(self, d_in, n_out, hidden=128, drop=0.3):
        super().__init__()
        self.emb = nn.Sequential(nn.LayerNorm(d_in), nn.Linear(d_in, hidden), nn.GELU(), nn.Dropout(drop))
        self.out = nn.Linear(hidden, n_out)

    def forward(self, x):
        e = self.emb(x)
        return {"logits": self.out(e), "emb": e}


def count_params(m: nn.Module) -> int:
    return sum(p.numel() for p in m.parameters())


# ------------------------------------------------------------------ baselines
class SingleFrame(nn.Module):
    """No temporal modelling: per-frame shape MLP, logits averaged over observed frames.
    Uses shape values only (delta channels and motion stream are excluded)."""

    def __init__(self, n_out, h=128, drop=0.3):
        super().__init__()
        d = 2 * N_JOINTS * NODE_C + 2 * N_GLOBAL + 2
        self.f = nn.Sequential(nn.LayerNorm(d), nn.Linear(d, h), nn.GELU(), nn.Dropout(drop), nn.Linear(h, h), nn.GELU())
        self.out = nn.Linear(h, n_out)

    def forward(self, b):
        B, T = b["nodes"].shape[:2]
        x = torch.cat([b["nodes"].reshape(B, T, -1), b["glob"][..., :N_GLOBAL].reshape(B, T, -1), b["mask"][..., :2]], -1)
        e = masked_mean(self.f(x), presence(b))
        return {"logits": self.out(e), "emb": e}


class MLP(nn.Module):
    def __init__(self, n_out, h=192, drop=0.3):
        super().__init__()
        d = flat_dim()
        self.net = Head(4 * d + N_META, n_out, h, drop)

    def forward(self, b):
        x = flat_input(b)
        w = presence(b)
        mean = masked_mean(x, w)
        std = (masked_mean((x - mean[:, None]) ** 2, w)).sqrt()
        return self.net(torch.cat([mean, std, x[:, 0], x[:, -1], b["meta"]], -1))


class GRU(nn.Module):
    def __init__(self, n_out, h=96, drop=0.3):
        super().__init__()
        self.inp = nn.Sequential(nn.LayerNorm(flat_dim()), nn.Linear(flat_dim(), h), nn.GELU())
        self.rnn = nn.GRU(h, h, batch_first=True, bidirectional=True)
        self.head = Head(2 * h + N_META, n_out, 128, drop)

    def forward(self, b):
        o, _ = self.rnn(self.inp(flat_input(b)))
        return self.head(torch.cat([masked_mean(o, presence(b)), b["meta"]], -1))


class TCNBlock(nn.Module):
    def __init__(self, c, k=5, d=1, drop=0.1):
        super().__init__()
        self.conv = nn.Sequential(nn.Conv1d(c, c, k, padding=d * (k // 2), dilation=d, groups=1), nn.GroupNorm(4, c),
                                  nn.GELU(), nn.Dropout(drop), nn.Conv1d(c, c, 1))

    def forward(self, x):
        return x + self.conv(x)


class TemporalEncoder(nn.Module):
    """(B,T,d_in) -> (B,T,c). Dilated residual temporal convolutions."""

    def __init__(self, d_in, c=96, layers=3, drop=0.1):
        super().__init__()
        self.inp = nn.Sequential(nn.LayerNorm(d_in), nn.Linear(d_in, c))
        self.blocks = nn.ModuleList([TCNBlock(c, 5, 2 ** i, drop) for i in range(layers)])

    def forward(self, x):
        h = self.inp(x).transpose(1, 2)
        for blk in self.blocks:
            h = blk(h)
        return h.transpose(1, 2)


class TCN(nn.Module):
    def __init__(self, n_out, c=96, drop=0.3):
        super().__init__()
        self.enc = TemporalEncoder(flat_dim(), c)
        self.head = Head(2 * c + N_META, n_out, 128, drop)

    def forward(self, b):
        h = self.enc(flat_input(b))
        w = presence(b)
        return self.head(torch.cat([masked_mean(h, w), h.amax(1), b["meta"]], -1))


class TransformerEnc(nn.Module):
    def __init__(self, d_in, d=96, layers=2, heads=4, T=64, drop=0.1):
        super().__init__()
        self.inp = nn.Sequential(nn.LayerNorm(d_in), nn.Linear(d_in, d))
        self.pos = nn.Parameter(torch.zeros(1, T, d))
        nn.init.normal_(self.pos, std=0.02)
        layer = nn.TransformerEncoderLayer(d, heads, 2 * d, drop, batch_first=True, activation="gelu", norm_first=True)
        self.enc = nn.TransformerEncoder(layer, layers, enable_nested_tensor=False)

    def forward(self, x, pad=None):
        h = self.inp(x) + self.pos[:, :x.shape[1]]
        return self.enc(h, src_key_padding_mask=pad)


class Transformer(nn.Module):
    def __init__(self, n_out, d=96, drop=0.3):
        super().__init__()
        self.enc = TransformerEnc(flat_dim(), d)
        self.head = Head(2 * d + N_META, n_out, 128, drop)

    def forward(self, b):
        h = self.enc(flat_input(b))
        return self.head(torch.cat([masked_mean(h, presence(b)), h.amax(1), b["meta"]], -1))


# ------------------------------------------------------------------ graph encoder
def hand_adjacency() -> torch.Tensor:
    a = torch.eye(N_JOINTS)
    for p, c in BONES:
        a[p, c] = a[c, p] = 1
    for i, j in [(4, 8), (8, 12), (12, 16), (16, 20), (5, 9), (9, 13), (13, 17)]:  # tip / knuckle neighbours
        a[i, j] = a[j, i] = 0.5
    d = a.sum(1).pow(-0.5)
    return d[:, None] * a * d[None]


class GraphConv(nn.Module):
    """Fixed skeleton adjacency plus a learned residual adjacency (initialised at zero), so the
    hand topology is a prior the network can refine, not a constraint it cannot escape."""

    def __init__(self, c_in, c_out):
        super().__init__()
        self.register_buffer("A", hand_adjacency())
        self.delta = nn.Parameter(torch.zeros(N_JOINTS, N_JOINTS))
        self.lin = nn.Linear(c_in, c_out)
        self.norm = nn.LayerNorm(c_out)

    def forward(self, x):  # (N,21,C)
        a = self.A + self.delta
        return Fn.gelu(self.norm(torch.einsum("uv,nvc->nuc", a, self.lin(x))))


class HandGraphEncoder(nn.Module):
    """Per-frame skeleton encoder shared by both hands. Returns (B,T,d)."""

    def __init__(self, d=64, glob_dim=GLOBAL_WIDTH):
        super().__init__()
        self.g1, self.g2 = GraphConv(NODE_C, 32), GraphConv(32, 48)
        self.node_out = nn.Linear(2 * 48, d)
        self.glob = nn.Sequential(nn.LayerNorm(glob_dim), nn.Linear(glob_dim, d), nn.GELU())
        self.fuse = nn.Sequential(nn.Linear(2 * d, d), nn.GELU())

    def forward(self, nodes, glob, mask):  # nodes (B,T,21,C) glob (B,T,GW) mask (B,T)
        B, T = nodes.shape[:2]
        h = self.g2(self.g1(nodes.reshape(B * T, N_JOINTS, -1)))
        h = self.node_out(torch.cat([h.mean(1), h.amax(1)], -1)).reshape(B, T, -1)
        z = self.fuse(torch.cat([h, self.glob(glob)], -1))
        return z * mask.unsqueeze(-1)


class STGraph(nn.Module):
    """Spatial-temporal graph baseline: graph encoder per hand -> concat -> temporal conv."""

    def __init__(self, n_out, d=64, c=96, drop=0.3):
        super().__init__()
        self.enc = HandGraphEncoder(d)
        self.slot = nn.Parameter(torch.zeros(2, d))
        self.t = TemporalEncoder(2 * d, c)
        self.head = Head(2 * c + N_META, n_out, 128, drop)

    def forward(self, b):
        z = [self.enc(b["nodes"][:, :, s], b["glob"][:, :, s], b["mask"][..., s]) + self.slot[s] * b["mask"][..., s:s + 1]
             for s in range(2)]
        h = self.t(torch.cat(z, -1))
        return self.head(torch.cat([masked_mean(h, presence(b)), h.amax(1), b["meta"]], -1))


class DualStream(nn.Module):
    """A: skeleton graph encoder -> temporal transformer over hand-pose embeddings (morphology).
    B: trajectory TCN over motion channels (where/how it moves). Fusion after both have
    formed their own sequence-level representation."""

    def __init__(self, n_out, fusion="concat", d=64, c=96, drop=0.3, T=64):
        super().__init__()
        assert fusion in ("concat", "gated", "attention")
        self.fusion = fusion
        self.enc = HandGraphEncoder(d)
        self.slot = nn.Parameter(torch.zeros(2, d))
        self.a = TransformerEnc(2 * d, c, layers=2, heads=4, T=T)
        self.b = TemporalEncoder(N_MOTION + 3, c)
        self.pa = nn.Sequential(nn.LayerNorm(2 * c), nn.Linear(2 * c, c))
        self.pb = nn.Sequential(nn.LayerNorm(2 * c), nn.Linear(2 * c, c))
        if fusion == "gated":
            self.gate = nn.Linear(2 * c + N_META, c)
            d_out = c
        elif fusion == "attention":
            self.q = nn.Parameter(torch.randn(1, 1, c) * 0.02)
            self.attn = nn.MultiheadAttention(c, 4, batch_first=True)
            d_out = c
        else:
            d_out = 2 * c
        self.head = Head(d_out + N_META, n_out, 128, drop)

    def streams(self, b):
        w = presence(b)
        z = [self.enc(b["nodes"][:, :, s], b["glob"][:, :, s], b["mask"][..., s]) + self.slot[s] * b["mask"][..., s:s + 1]
             for s in range(2)]
        ha = self.a(torch.cat(z, -1))
        hb = self.b(torch.cat([b["motion"], b["mask"]], -1))
        pa = self.pa(torch.cat([masked_mean(ha, w), ha.amax(1)], -1))
        pb = self.pb(torch.cat([masked_mean(hb, w), hb.amax(1)], -1))
        return pa, pb

    def forward(self, b):
        pa, pb = self.streams(b)
        meta = b["meta"]
        if self.fusion == "gated":
            g = torch.sigmoid(self.gate(torch.cat([pa, pb, meta], -1)))
            f = g * pa + (1 - g) * pb
        elif self.fusion == "attention":
            kv = torch.stack([pa, pb], 1)
            f, _ = self.attn(self.q.expand(kv.shape[0], -1, -1), kv, kv)
            f = f[:, 0]
        else:
            f = torch.cat([pa, pb], -1)
        return self.head(torch.cat([f, meta], -1))


def build_model(name: str, n_out: int, **kw) -> nn.Module:
    if name == "single_frame":
        return SingleFrame(n_out)
    if name == "mlp":
        return MLP(n_out)
    if name == "gru":
        return GRU(n_out)
    if name == "tcn":
        return TCN(n_out)
    if name == "transformer":
        return Transformer(n_out)
    if name == "stgcn":
        return STGraph(n_out)
    if name.startswith("dual"):
        fusion = name.split(":")[1] if ":" in name else kw.get("fusion", "concat")
        return DualStream(n_out, fusion=fusion)
    raise KeyError(name)


def to_tensors(batch: dict, device) -> dict:
    return {k: torch.as_tensor(v, device=device) for k, v in batch.items()}
