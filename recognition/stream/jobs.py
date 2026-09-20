"""One physically outstanding call per dependency, even after logical timeout.

Daemon threads cannot kill a hung library call. They bound that failure to one job
per provider/resolver and cannot keep Python alive on exit. Use ProcessProvider
for native inference that requires termination and restart after a timeout.
"""
from concurrent.futures import Future
from dataclasses import dataclass
import threading
import time


@dataclass
class Job:
    future: Future
    finished_at: float | None = None


class SingleFlight:
    def __init__(self, name, wake):
        self.name, self.wake = name, wake
        self.job: Job | None = None

    @property
    def running(self):
        return self.job is not None and not self.job.future.done()

    def submit(self, fn, *args):
        if self.running:
            return None
        job = Job(Future())
        self.job = job

        def run():
            try:
                value = fn(*args)
            except BaseException as error:
                job.finished_at = time.monotonic()
                job.future.set_exception(error)
            else:
                job.finished_at = time.monotonic()
                job.future.set_result(value)
            finally:
                self.wake.set()

        threading.Thread(target=run, daemon=True, name=self.name).start()
        return job
