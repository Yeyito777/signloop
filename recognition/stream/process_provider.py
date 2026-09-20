"""Optional hard timeout boundary for native/model inference.

Pass a picklable factory (e.g. functools.partial(OpenHandsProvider, ...)). The
provider and its model are created in the child, never copied from a live GPU
context. warmup() before capture gives model loading a separate deadline.
Timed-out or crashed workers are killed; the next call creates a new worker.
"""
from __future__ import annotations

import math
import multiprocessing as mp
import threading
import time

from .provider import RecognitionProvider


def _serve(connection, factory):
    try:
        provider = factory()
        connection.send(("ready", None))
        while True:
            windows, vocab = connection.recv()
            connection.send(("ok", provider.probs(windows, vocab)))
    except (EOFError, BrokenPipeError):
        pass
    except BaseException as exc:
        try:
            connection.send(("error", type(exc).__name__))
        except (EOFError, BrokenPipeError, OSError):
            pass
    finally:
        connection.close()


class ProcessProvider(RecognitionProvider):
    def __init__(self, factory, name, labels, *, timeout=.75, startup_timeout=60):
        if any(not math.isfinite(t) or t <= 0 for t in (timeout, startup_timeout)):
            raise ValueError("process deadlines must be positive and finite")
        self.factory, self.name, self.labels = factory, name, list(labels)
        self.timeout, self.startup_timeout = timeout, startup_timeout
        self._lock, self._calls = threading.Lock(), threading.Lock()
        self._process = self._connection = None
        self._closed = False

    def _stop(self):
        with self._lock:
            process, connection = self._process, self._connection
            self._process = self._connection = None
            if connection is not None:
                connection.close()
            if process is not None:
                if process.is_alive():
                    process.terminate()
                process.join(.1)
                if process.is_alive():
                    process.kill()
                    process.join(.1)
                if not process.is_alive():
                    process.close()

    def _receive(self, connection, timeout, expected):
        deadline = time.monotonic() + timeout
        while True:
            if self._closed:
                raise RuntimeError("provider is closed")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("provider process exceeded its deadline")
            if connection.poll(min(remaining, .02)):
                break
        status, value = connection.recv()
        if status != expected:
            raise RuntimeError("provider process failed: " + str(value))
        return value

    def _start(self):
        with self._lock:
            if self._closed:
                raise RuntimeError("provider is closed")
            if self._process is not None:
                return self._connection
            ctx = mp.get_context("spawn")
            parent, child = ctx.Pipe()
            process = ctx.Process(target=_serve, args=(child, self.factory), daemon=True,
                                  name="recognizer-" + self.name)
            self._process, self._connection = process, parent
            try:
                process.start()
            except BaseException:
                self._process = self._connection = None
                parent.close()
                raise
            finally:
                child.close()
        self._receive(parent, self.startup_timeout, "ready")
        return parent

    def warmup(self):
        with self._calls:
            try:
                self._start()
            except BaseException:
                self._stop()
                raise

    def probs(self, windows, vocab):
        with self._calls:
            try:
                connection = self._start()
                connection.send((windows, vocab))
                return self._receive(connection, self.timeout, "ok")
            except BaseException:
                self._stop()
                raise

    def close(self):
        with self._lock:
            self._closed = True
        self._stop()

    def info(self):
        with self._lock:
            return {"provider": self.name, "isolation": "spawn",
                    "pid": self._process.pid if self._process is not None else None,
                    "timeout_s": self.timeout, "startup_timeout_s": self.startup_timeout}
