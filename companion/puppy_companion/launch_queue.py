"""Launches run one after another on a worker thread, with a pause between them."""
import collections
import threading
from dataclasses import dataclass

from . import launch
from .redact import redact
from .roblox import RobloxError, RobloxSession


@dataclass
class LaunchJob:
    user_id: int
    label: str
    place_id: int = 0
    job_id: str = ""
    follow_user_id: int = 0


class LaunchQueue:
    def __init__(self, store, delay, log, opener=None, open_uri=None):
        """delay(): seconds between launches; log(text) is called from the worker thread."""
        self.store = store
        self.delay = delay
        self.log = log
        self.opener = opener
        self.open_uri = open_uri or launch.open_uri
        self._jobs = collections.deque()
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._cancel = threading.Event()
        self.busy = False
        threading.Thread(target=self._run, name="launch-queue", daemon=True).start()

    def add(self, jobs):
        with self._lock:
            self._jobs.extend(jobs)
        self._wake.set()

    def cancel(self):
        with self._lock:
            n = len(self._jobs)
            self._jobs.clear()
        self._cancel.set()
        return n

    def pending(self):
        with self._lock:
            return len(self._jobs) + (1 if self.busy else 0)

    def _run(self):
        while True:
            self._wake.wait()
            self._wake.clear()
            while True:
                with self._lock:
                    if not self._jobs:
                        break
                    job = self._jobs.popleft()
                    self.busy = True
                self._cancel.clear()
                self.launch_one(job)
                with self._lock:
                    self.busy = False
                    more = bool(self._jobs)
                if more:
                    self._cancel.wait(max(0.05, float(self.delay())))

    def launch_one(self, job):
        try:
            session = RobloxSession(self.store.cookie(job.user_id), opener=self.opener)
            ticket = session.auth_ticket()
            tracker = launch.new_tracker_id()
            url = launch.place_launcher_url(tracker, job.place_id, job.job_id or None, job.follow_user_id or None)
            self.open_uri(launch.launch_uri(ticket, url, tracker))
            where = ("server " + job.job_id[:8]) if job.job_id else ("place %d" % job.place_id if job.place_id else "")
            self.log("Launched %s%s" % (job.label, (" into " + where) if where else ""))
            return True
        except RobloxError as e:
            self.log("%s: %s" % (job.label, e))
        except Exception as e:  # never let one account stop the queue
            self.log(redact("%s: %s: %s" % (job.label, type(e).__name__, e)))
        return False
