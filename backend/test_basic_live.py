import json
import hashlib
from pathlib import Path
import tempfile
import unittest
from .basic_live import accepted_events, calibrate, metrics, validate_deployment
from .basic_signs import LABELS


class BasicLiveTests(unittest.TestCase):
    def test_stability_and_unknown(self):
        def event(label, d=.04, m=.3):
            return dict(label=label, distance=d, margin=m)
        self.assertEqual(accepted_events(dict(events=[event("HELLO")]), .08, .15), set())
        self.assertEqual(accepted_events(dict(events=[event("HELLO")]*2), .08, .15), {"HELLO"})
        self.assertEqual(accepted_events(dict(events=[event("HELLO"), event(None), event("HELLO")]), .08, .15), set())
        self.assertEqual(accepted_events(dict(events=[event("HELLO", .2)]*2), .08, .15), set())
        self.assertEqual(accepted_events(dict(events=[event("HELLO", m=.01)]*2), .08, .15), set())

    def test_counts_keep_missing_and_wrong(self):
        events = [dict(label="NO", distance=.01, margin=.8)]*2
        m = metrics([dict(label="HELLO", events=events), dict(label="UNKNOWN", events=events),
                     dict(label="HELLO", events=[])], .08, .15)
        self.assertEqual((m["supported"], m["correct"], m["wrong"], m["false_display"]), (2, 0, 1, 1))

    def test_calibration_refuses_test_split_without_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw, bank = Path(tmp)/"raw.json", Path(tmp)/"bank.json"
            raw.write_text(json.dumps([dict(split="test")]))
            bank.write_text("UNCHANGED")
            with self.assertRaises(ValueError):
                calibrate(raw, bank)
            self.assertEqual(bank.read_text(), "UNCHANGED")

    def test_provisioning_rejects_heldout_or_raw_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            row = dict(id="train", label="HELLO", signer="s1", split="train")
            plan = folder/"plan.json"
            plan.write_text(json.dumps(dict(samples=[row])))
            (folder/"report.json").write_text(json.dumps(dict(complete=True,
                plan_sha256=hashlib.sha256(plan.read_bytes()).hexdigest())))
            asset = dict(version=2, labels=list(LABELS), maxDistance=.08, minMargin=.15,
                         references=[dict(row, frames=[], features=[{}]*16)])
            bank = folder/"bank.json"
            bank.write_text(json.dumps(asset))
            self.assertEqual(len(validate_deployment(bank, folder)["references"]), 1)
            asset["references"][0]["split"] = "test"
            bank.write_text(json.dumps(asset))
            with self.assertRaises(ValueError):
                validate_deployment(bank, folder)
            asset["references"][0]["split"] = "train"
            asset["references"][0]["frames"] = [dict()]
            bank.write_text(json.dumps(asset))
            with self.assertRaises(ValueError):
                validate_deployment(bank, folder)


if __name__ == "__main__":
    unittest.main()
