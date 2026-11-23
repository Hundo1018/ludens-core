"""Hot reload of Python systems (ROADMAP 17.21).

`HotSystem(world, path)` loads `path` as a module and registers its
`system(world, dt, tick, state)` function as a world system. Before a tick,
if the file's content changed, the module is re-executed and the new
`system` takes over from that tick on. The world keeps running: bodies,
tick count and the `state` dict persist, so a reload behaves exactly like
switching functions at that tick boundary (tested bit-for-bit).

A reload that fails (syntax error, exception at import, missing `system`)
keeps the previous function, records the error in `last_error` and counts
it in `failures`; the next good edit loads normally. If the new module
defines `migrate(state)`, it is called once after a successful reload.
"""

import hashlib
import importlib.util
import itertools
import traceback

from .world import PRE

_ids = itertools.count()


class HotSystem:
    def __init__(self, world, path, func="system", phase=PRE, poll_every=1):
        if poll_every < 1:
            raise ValueError("poll_every must be >= 1")
        self.world = world
        self.path = str(path)
        self.func = func
        self.poll_every = poll_every
        self.state = {}
        self.reloads = 0
        self.failures = 0
        self.last_error = None
        self._digest = None
        self._fn = None
        self._countdown = 0
        if not self._load():
            raise ImportError("HotSystem: initial load of %s failed:\n%s" % (self.path, self.last_error))
        self.reloads = 0
        self.system_id = world.add_system(self._run, phase)

    def _read(self):
        with open(self.path, "rb") as f:
            return f.read()

    def _load(self):
        try:
            src = self._read()
        except OSError as e:
            self.last_error = "%s: %s" % (type(e).__name__, e)
            self.failures += 1
            return False
        digest = hashlib.sha256(src).digest()
        if digest == self._digest:
            return False
        self._digest = digest
        name = "ludens_hot_%d" % next(_ids)
        try:
            spec = importlib.util.spec_from_loader(name, loader=None)
            mod = importlib.util.module_from_spec(spec)
            mod.__file__ = self.path
            exec(compile(src, self.path, "exec"), mod.__dict__)
            fn = getattr(mod, self.func, None)
            if not callable(fn):
                raise AttributeError("module defines no callable %r" % self.func)
            migrate = getattr(mod, "migrate", None)
            if self._fn is not None and callable(migrate):
                migrate(self.state)
        except Exception:  # noqa: BLE001 -- any error in the new module keeps the old version running
            self.last_error = traceback.format_exc(limit=1)
            self.failures += 1
            return False
        self._fn = fn
        self.last_error = None
        self.reloads += 1
        return True

    def poll(self):
        """Reload now if the file changed; True when a new version was loaded."""
        return self._load()

    def _run(self, world, dt, tick):
        self._countdown -= 1
        if self._countdown <= 0:
            self._countdown = self.poll_every
            self._load()
        return self._fn(world, dt, tick, self.state)

    def remove(self):
        self.world.remove_system(self.system_id)
