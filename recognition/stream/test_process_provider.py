from functools import partial
import multiprocessing as mp
from pathlib import Path
import tempfile
import threading
import time
import unittest

import numpy as np

from recognition.stream.process_provider import ProcessProvider
from recognition.stream.provider import Window
from recognition.stream.test_controller import CONFIDENT, wait_for
from recognition.stream.test_stream import GLOSSES, Stub


class HangOnce(Stub):
    def __init__(self, marker):
        super().__init__("isolated", CONFIDENT)
        self.marker = Path(marker)

    def probs(self, windows, vocab):
        if not self.marker.exists():
            self.marker.touch()
            time.sleep(30)
        return super().probs(windows, vocab)


def broken_factory():
    raise RuntimeError("model failed to load")


class ProcessProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.marker = str(Path(self.temp.name) / "attempted")
        self.window = Window(0, 1, np.zeros((10, 75, 3)))

    def provider(self, factory=None, **kwargs):
        p = ProcessProvider(factory or partial(HangOnce, self.marker), "isolated", GLOSSES,
                            startup_timeout=5, **kwargs)
        self.addCleanup(p.close)
        return p

    def test_hung_process_is_killed_and_next_call_restarts(self):
        p = self.provider(timeout=.05)
        p.warmup()
        first_pid = p.info()["pid"]
        with self.assertRaises(TimeoutError):
            p.infer(self.window, np.arange(4), 4)
        self.assertIsNone(p.info()["pid"])
        self.assertNotIn(first_pid, [child.pid for child in mp.active_children()])
        result = p.infer(self.window, np.arange(4), 4)
        self.assertEqual(result.predictions[0][0], "water")
        self.assertNotEqual(first_pid, p.info()["pid"])

    def test_crashed_worker_restarts(self):
        Path(self.marker).touch()
        p = self.provider()
        p.warmup()
        first_pid = p.info()["pid"]
        p._process.kill()
        p._process.join(1)
        with self.assertRaises((EOFError, BrokenPipeError, ConnectionResetError)):
            p.infer(self.window, np.arange(4), 4)
        self.assertEqual(p.infer(self.window, np.arange(4), 4).predictions[0][0], "water")
        self.assertNotEqual(first_pid, p.info()["pid"])

    def test_initialization_error_does_not_leak_worker(self):
        p = self.provider(broken_factory)
        with self.assertRaisesRegex(RuntimeError, "provider process failed"):
            p.warmup()
        self.assertIsNone(p.info()["pid"])

    def test_close_terminates_active_call_and_refuses_restart(self):
        p = self.provider(timeout=10)
        p.warmup()
        errors = []
        def infer():
            try:
                p.infer(self.window, np.arange(4))
            except Exception as exc:
                errors.append(exc)
        thread = threading.Thread(target=infer)
        thread.start()
        wait_for(lambda: Path(self.marker).exists())
        p.close()
        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertTrue(errors)
        with self.assertRaisesRegex(RuntimeError, "closed"):
            p.warmup()


if __name__ == "__main__":
    unittest.main()
