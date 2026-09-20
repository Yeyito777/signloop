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
    t = s["temporal"]
    lines += ["", "TEMPORAL", f"  {(t['top'] or ['-'])[0].upper():<14s}{(t['confidence'] or 0) * 100:5.0f}%   state: {t['state']}"]
    c = s["context"]
    lines += ["", "JEV RESOLVER"]
    if c["pending"]:
        lines.append("  (call in flight)")
    elif c["resolved"]:
        lines.append(f"  {str(c['resolved']).upper():<14s}{(c['confidence'] or 0) * 100:5.0f}%   stable {'yes' if c['stable'] else 'no'}   "
                     f"commit {'yes' if c['commit'] else 'no'}   ({c['latency_ms']} ms{'' if c['ok'] else ', FAILED'})")
    else:
        lines.append("  not consulted (visual evidence unambiguous or not yet stable)")
    words = " ".join(w.upper() for w in s["committed"])
    tent = f" {s['tentative']}…" if s["tentative"] else ""
    lines += ["", "CAPTION", f'  "{words}{tent}"']
    return "\n".join(lines)
