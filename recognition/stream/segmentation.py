"""Bridge unmirrored Holistic frames to the existing hand segmenter.

Coordinates stay untouched for recognition. Only the segmenter's copy is converted
to the app hand schema, which handles aspect ratio and camera mirroring itself.
"""
import math

import numpy as np

from recognition.segmenter import PALM_CORE


def holistic_frame(t, keypoints, confidences=None, *, aspect_ratio=1.0, mirrored=False, min_confidence=.5):
    if not math.isfinite(t) or not math.isfinite(aspect_ratio) or aspect_ratio <= 0:
        raise ValueError("frame time and positive aspect ratio must be finite")
    kp = np.array(keypoints, dtype=np.float32, copy=True)
    cf = None if confidences is None else np.array(confidences, dtype=np.float32, copy=True)
    if kp.shape != (75, 3) or not np.isfinite(kp).all():
        raise ValueError("expected finite Holistic keypoints (75, 3)")
    if cf is not None and (cf.shape != (75,) or not np.isfinite(cf).all() or (cf < 0).any() or (cf > 1).any()):
        raise ValueError("expected confidences (75,) in [0, 1]")
    # No confidence channel means the producer uses all-zero blocks for missing
    # hands. With confidence, every palm-core point must be observed.
    hands = []
    for side, start in (("Left", 33), ("Right", 54)):
        points = kp[start:start + 21]
        present = bool(np.any(points)) if cf is None else bool(np.all(cf[start + np.array(PALM_CORE)] >= min_confidence))
        if present:
            hands.append({"handedness": side, "joints": [dict(zip(("x", "y", "z"), map(float, p))) for p in points]})
    kp.flags.writeable = False
    if cf is not None:
        cf.flags.writeable = False
    return {"timestampMS": round(t * 1000), "hands": hands, "imageAspectRatio": aspect_ratio,
            "mirrored": mirrored, "keypoints": kp, "confidences": cf, "time": t}
