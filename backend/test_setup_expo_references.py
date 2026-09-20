import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from . import setup_expo_references as setup
from .basic_signs import PRESENTATION_LABELS, DEMO_LABELS, LIMITS, select


class ExpoReferenceSetupTests(unittest.TestCase):
    def test_license_required_before_any_work(self):
        with mock.patch("sys.argv", ["setup"]), mock.patch.object(setup.subprocess, "run") as run, \
             mock.patch.object(setup, "prepare") as prepare, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                setup.main()
        self.assertEqual(result.exception.code, 2)
        run.assert_not_called()
        prepare.assert_not_called()

    def test_plan_only_does_not_pack_or_provision(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(setup, "ROOT", Path(folder)), \
             mock.patch("sys.argv", ["setup", "--accept-research-license", "--plan-only", "--device", "phone"]), \
             mock.patch.object(setup.subprocess, "run") as run, mock.patch.object(setup, "prepare") as prepare:
            setup.main()
        self.assertEqual(run.call_count, 1)
        self.assertIn("plan", run.call_args.args[0])
        self.assertIn("presentation11", run.call_args.args[0])
        prepare.assert_not_called()

    def test_concurrent_setup_refuses_before_overwriting_output(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(setup, "ROOT", Path(folder)), \
             mock.patch("sys.argv", ["setup", "--accept-research-license"]), \
             mock.patch.object(setup.fcntl, "flock", side_effect=BlockingIOError), \
             mock.patch.object(setup, "run") as run, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                setup.main()
        self.assertEqual(result.exception.code, 2)
        run.assert_not_called()

    def test_paths_outside_ignored_runtime_rejected_before_export(self):
        with mock.patch.object(setup, "export") as export:
            with self.assertRaises(ValueError):
                setup.prepare(Path("/tmp/public-corpus"), Path("/tmp/.runtime/output"))
            with self.assertRaises(ValueError):
                setup.prepare(Path("/tmp/.runtime/corpus"), Path("/tmp/public-output"))
        export.assert_not_called()

    def test_existing_own_corpus_provisions_expo_not_standalone(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(setup, "ROOT", Path(folder)), \
             mock.patch("sys.argv", ["setup", "--accept-research-license", "--existing-corpus",
                                    "/tmp/.runtime/own", "--device", "phone"]), \
             mock.patch.object(setup.subprocess, "run") as run, mock.patch.object(setup, "prepare") as prepare:
            setup.main()
        prepare.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--bundle-id")+1], "com.signloop.mobile")
        self.assertNotIn("extract", command)

    def test_presentation_selection_matches_live_vocabulary_and_training(self):
        self.assertEqual(set(PRESENTATION_LABELS), {
            "HELLO", "MY", "NAME", "TODAY", "WE", "SHOW", "PHONE",
            "PLEASE", "SORRY", "THANKYOU", "ILOVEYOU"})
        splits = {
            split: [{"Participant ID": split + str(i), "Gloss": label,
                     "Video file": f"{split}-{label}-{i}.mp4"}
                    for label in DEMO_LABELS for i in range(count)]
            for split, count in LIMITS.items()
        }
        for split, rows in splits.items():
            rows.extend({"Participant ID": split + "0", "Gloss": "UNSUPPORTED" + str(i),
                         "Video file": f"{split}-unsupported-{i}.mp4"} for i in range(10))
        full, small = select(splits, DEMO_LABELS), select(splits, PRESENTATION_LABELS)
        expected = {r["id"] for r in full if r["split"] == "train" and r["label"] in PRESENTATION_LABELS}
        self.assertEqual(expected, {r["id"] for r in small if r["split"] == "train"})
        self.assertEqual(len(small), 141)
        self.assertEqual(set(setup.POLICY), {"windowMS", "ruleWeight", "queryFrames", "maxDistance", "minMargin"})


if __name__ == "__main__":
    unittest.main()
