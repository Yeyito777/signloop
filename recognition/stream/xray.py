"""X-Ray: render the REAL live session state as text. Every number comes from StreamingSession.snapshot();
nothing here computes or overrides a prediction."""
from __future__ import annotations


def render(s: dict) -> str:
    lines = [f"CAMERA       {s['camera_fps']:.0f} FPS",
             f"WINDOWS      {s['windows_queued']} queued, {s['windows_done']} done, {s['dropped']} dropped", ""]
    for name, preds in s["providers"].items():
        lines.append(f"{name.replace('openhands-wlasl2000-', '').upper():<10s}  ({s['provider_latency_ms'][name]:.0f} ms)")
        for lab, p in preds:
            lines.append(f"  {lab.upper():<14s}{p * 100:5.0f}%")
    for name, health in s["provider_health"].items():
        if health["status"] not in ("idle", "ok"):
            lines.append(f"  {name}: {health['status']} (still running: {health['running']})")
    t = s["temporal"]
    lines += ["", "TEMPORAL", f"  {(t['top'] or ['-'])[0].upper():<14s}{(t['confidence'] or 0) * 100:5.0f}%   state: {t['state']}"]
    c = s["context"]
    lines += ["", "JEV RESOLVER"]
    lines.append(f"  {c['status']} (pending: {c['pending']}, call running: {c['running']})")
    if c["resolved"]:
        lines.append(f"  {c['resolved'].upper()}  {(c['confidence'] or 0) * 100:.0f}%")
    a = s["attempt"]
    lines += ["", f"ATTEMPT {a['attempt_id']} / revision {a['revision']}: {a['state']}"]
    if a["ready"]:
        lines.append(f"  {a['ready'].upper()} — awaiting confirmation")
    if a["reason"]:
        lines.append(f"  {a['reason']}")
    words = " ".join(w.upper() for w in s["committed"])
    tent = f" {s['tentative']}…" if s["tentative"] else ""
    lines += ["", "CAPTION", f'  "{words}{tent}"']
    return "\n".join(lines)
