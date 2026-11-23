"""Console variables (ROADMAP 17.21): typed, range-checked settings that can be
changed while a world runs, from code, a console line or a config file.

A change never lands mid-tick: `bind_world` registers a PRE system that
applies queued changes at the start of the next tick, so a run that sets
`physics.iterations 4` at tick 60 is bit-identical to one that calls
`world.set_solver(4, ...)` before tick 60 (tested).
"""

from .world import PRE, ArgumentError

_TYPES = (bool, int, float, str)


class CVar:
    __slots__ = ("name", "type", "default", "min", "max", "help", "value", "_listeners")

    def __init__(self, name, default, min=None, max=None, help=""):
        if type(default) not in _TYPES:
            raise ArgumentError("cvar %s: default must be bool, int, float or str" % name)
        self.name = name
        self.type = type(default)
        self.default = default
        self.min = min
        self.max = max
        self.help = help
        self.value = default
        self._listeners = []

    def parse(self, raw):
        """Convert `raw` (a value or console text) to this cvar's type; raises ArgumentError."""
        try:
            if self.type is bool:
                if isinstance(raw, str):
                    low = raw.strip().lower()
                    if low in ("1", "true", "on", "yes"):
                        v = True
                    elif low in ("0", "false", "off", "no"):
                        v = False
                    else:
                        raise ValueError(raw)
                else:
                    v = bool(raw)
            elif self.type is int:
                if isinstance(raw, float) and not raw.is_integer():
                    raise ValueError(raw)
                v = int(raw)
            elif self.type is float:
                v = float(raw)
                if v != v or v in (float("inf"), float("-inf")):
                    raise ValueError(raw)
            else:
                v = str(raw)
        except (TypeError, ValueError):
            raise ArgumentError("cvar %s: %r is not a valid %s" % (self.name, raw, self.type.__name__)) from None
        if self.min is not None and v < self.min:
            raise ArgumentError("cvar %s: %r below minimum %r" % (self.name, v, self.min))
        if self.max is not None and v > self.max:
            raise ArgumentError("cvar %s: %r above maximum %r" % (self.name, v, self.max))
        return v

    def __repr__(self):
        return "CVar(%s=%r)" % (self.name, self.value)


class CVarRegistry:
    def __init__(self):
        self._vars = {}

    def define(self, name, default, min=None, max=None, help="", on_change=None):
        if not name or any(c.isspace() for c in name):
            raise ArgumentError("cvar name must be non-empty without whitespace: %r" % name)
        if name in self._vars:
            raise ArgumentError("cvar %s already defined" % name)
        cv = CVar(name, default, min, max, help)
        cv.parse(default)
        if on_change is not None:
            cv._listeners.append(on_change)
        self._vars[name] = cv
        return cv

    def __contains__(self, name):
        return name in self._vars

    def __getitem__(self, name):
        return self._cvar(name).value

    def _cvar(self, name):
        try:
            return self._vars[name]
        except KeyError:
            raise ArgumentError("unknown cvar %r" % name) from None

    def watch(self, name, fn):
        """Call fn(cvar, old, new) after every change of `name`."""
        self._cvar(name)._listeners.append(fn)

    def set(self, name, raw):
        cv = self._cvar(name)
        new = cv.parse(raw)
        old = cv.value
        if new == old and type(new) is type(old):
            return False
        cv.value = new
        for fn in list(cv._listeners):
            fn(cv, old, new)
        return True

    def reset(self, name):
        return self.set(name, self._cvar(name).default)

    def exec(self, line):
        """Console line: `name value` sets, `name` reads; returns the value as text."""
        parts = line.strip().split(None, 1)
        if not parts:
            raise ArgumentError("empty console line")
        if len(parts) == 2:
            self.set(parts[0], parts[1])
        return _fmt(self._cvar(parts[0]).value)

    def load(self, text):
        """Apply a config text: one `name value` per line, `#` starts a comment. All
        lines are validated before any is applied."""
        pending = []
        for n, raw in enumerate(text.splitlines(), 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise ArgumentError("config line %d: expected `name value`, got %r" % (n, raw))
            try:
                pending.append((parts[0], self._cvar(parts[0]).parse(parts[1])))
            except ArgumentError as e:
                raise ArgumentError("config line %d: %s" % (n, e)) from None
        for name, v in pending:
            self.set(name, v)
        return len(pending)

    def dump(self):
        """Config text of every cvar (round-trips through `load`)."""
        out = []
        for name in sorted(self._vars):
            cv = self._vars[name]
            line = "%s %s" % (name, _fmt(cv.value))
            if cv.help:
                line += "  # " + cv.help
            out.append(line)
        return "\n".join(out) + "\n"


def _fmt(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    return repr(v) if isinstance(v, float) else str(v)


def bind_world(world, registry=None, iterations=4, substeps=4, gravity=(0.0, -9.8, 0.0)):
    """Define `physics.iterations`, `physics.substeps`, `physics.gravity_{x,y,z}`
    on `registry` (new one if None) and apply changes to `world` at the next
    tick boundary. The cvar defaults (the engine's `SolverConfig` defaults,
    4 / 4) are written to the world immediately so world and registry agree
    from the start. Bind before registering other PRE systems so the change
    is in effect for every system of that tick."""
    if len(gravity) != 3:
        raise ValueError("gravity needs 3 components (x, y, z), got %d" % len(gravity))
    reg = registry if registry is not None else CVarRegistry()
    dirty = {"solver": False, "gravity": False}

    def mark(key):
        return lambda cv, old, new: dirty.__setitem__(key, True)

    reg.define("physics.iterations", int(iterations), min=1, max=256, help="solver iterations per substep", on_change=mark("solver"))
    reg.define("physics.substeps", int(substeps), min=1, max=64, help="substeps per tick", on_change=mark("solver"))
    for axis, g in zip("xyz", gravity):  # noqa: B905 -- length checked above; strict= needs Python 3.10, the wheel supports 3.8
        reg.define("physics.gravity_" + axis, float(g), help="gravity %s (m/s^2)" % axis, on_change=mark("gravity"))
    world.set_solver(reg["physics.iterations"], reg["physics.substeps"])
    world.set_gravity((reg["physics.gravity_x"], reg["physics.gravity_y"], reg["physics.gravity_z"]))

    def apply(w, dt, tick):
        if dirty["solver"]:
            w.set_solver(reg["physics.iterations"], reg["physics.substeps"])
            dirty["solver"] = False
        if dirty["gravity"]:
            w.set_gravity((reg["physics.gravity_x"], reg["physics.gravity_y"], reg["physics.gravity_z"]))
            dirty["gravity"] = False

    reg.system_id = world.add_system(apply, PRE)
    return reg
