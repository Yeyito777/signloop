"""Short-window geometric hand association, independent of sign labels.

Only reassigns observed hands; never invents/interpolates landmarks. Handedness
is a weak assignment cue, not a persistent ID. Occlusions remain missing data.
"""
import itertools
import math

from .service import validate_frames


def _shape(hand):
    wrist, scale = hand["xyz"][0], hand["scale"]
    return [(p[a]-wrist[a])/scale for p in hand["xyz"] for a in range(3)]


def _shape_distance(a, b):
    return math.sqrt(sum((x-y)**2 for x, y in zip(_shape(a), _shape(b))) / 63)


def stabilize(frames, diagnostics=None):
    validate_frames(frames)
    previous = {}
    output = []
    counters = {"duplicate_detections_removed": 0, "hand_labels_reassociated": 0,
                "ambiguous_assignment_frames": 0}
    for frame in frames:
        timestamp = frame["timestampMS"]
        aspect = frame.get("imageAspectRatio", 1.)
        mirrored = frame.get("mirrored", True)
        detections = []
        for raw in frame["hands"]:
            side = raw["handedness"]
            if not mirrored:
                side = {"Left": "Right", "Right": "Left"}.get(side, side)
            score = raw.get("handednessScore", .5)
            if type(score) not in (int, float) or not math.isfinite(score):
                score = .5
            score = max(0., min(1., score))
            xyz = [((p["x"] if mirrored else 1-p["x"])*aspect, p["y"], p["z"]*aspect)
                   for p in raw["joints"]]
            scale = math.dist(xyz[0][:2], xyz[9][:2])
            if scale >= .015:
                detections.append({"side": side, "score": score, "xyz": xyz, "scale": scale})
        # A duplicated detection of one physical hand is not a second hand.
        detections.sort(key=lambda h: (-h["score"], h["xyz"][0][0]))
        if len(detections) == 2:
            a, b = detections
            scale = (a["scale"] + b["scale"]) / 2
            wrist_distance = math.dist(a["xyz"][0][:2], b["xyz"][0][:2]) / scale
            if wrist_distance < .25 and _shape_distance(a, b) < .15:
                detections.pop()
                counters["duplicate_detections_removed"] += 1
        previous = {side: h for side, h in previous.items() if timestamp-h["timestamp"] <= 300}

        def cost(hand, side):
            # Wrist continuity dominates a single noisy handedness prediction.
            label_cost = 0 if side == hand["side"] else .35 * hand["score"]
            if side not in previous:
                return 2.5 + label_cost
            old = previous[side]
            scale = (old["scale"] + hand["scale"]) / 2
            motion = math.dist(old["xyz"][0][:2], hand["xyz"][0][:2]) / scale
            return min(motion, 6.) + .25 * _shape_distance(old, hand) + label_cost

        choices = [(sum(cost(hand, side) for hand, side in zip(detections, sides)), sides)
                   for sides in itertools.permutations(("Left", "Right"), len(detections))]
        choices.sort()
        assigned = []
        if detections:
            # Don't resolve an actual assignment tie by array order.
            if len(choices) > 1 and choices[1][0] - choices[0][0] < .025:
                counters["ambiguous_assignment_frames"] += 1
            else:
                for hand, side in zip(detections, choices[0][1]):
                    counters["hand_labels_reassociated"] += side != hand["side"]
                    previous[side] = {**hand, "timestamp": timestamp}
                    assigned.append({"handedness": side, "handednessScore": hand["score"],
                                     "joints": [dict(zip(("x", "y", "z"), p)) for p in hand["xyz"]]})
        output.append({"timestampMS": timestamp, "hands": assigned,
                       "imageAspectRatio": 1., "mirrored": True})
    if diagnostics is not None:
        diagnostics.update(counters)
    return output
