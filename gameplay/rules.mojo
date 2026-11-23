"""Gameplay rules: attributes, tags, effects, damage (ROADMAP 17.70).

All state is plain values advanced by an integer tick, so it snapshots,
saves and replays with the rest of the simulation (`to_bytes` /
`from_bytes`); nothing reads a wall clock or keeps a pointer graph.

ATTRIBUTES. Values are fixed point, 1/1000 units in `Int` (`FX`): integer
addition commutes exactly, which is what lets the incremental evaluator
equal the full recompute after any sequence (floating-point sums would
drift with the order). A modifier is (attribute, op, value, source):
`OP_ADD` adds, `OP_MUL` adds a percentage (sum of percents, applied once:
base x (1000 + sum) / 1000), `OP_OVERRIDE` replaces (the highest priority
wins, ties by the newest). current = override if any else
(base + sum add) x (1000 + sum mul) / 1000, clamped to [min, max].

Three evaluators behind one observable (`value`): `EVAL_FULL` rescans the
modifier list, `EVAL_INCREMENTAL` keeps running sums updated on add /
remove, `EVAL_DIRTY` recomputes on first read after a change. They agree on
every value after any (seeded) sequence (`test_rules`).

TAGS. Hierarchical names (`State.Burning.Fire`) are interned to ids; a tag
set is a `UInt64` bitset (`Actor.tags`), and adding a tag also sets its parents, so
`has(State.Burning)` is true for a burning-by-fire entity.

EFFECTS. instant (applied once to the base), duration (modifiers until
expiry), infinite, periodic (an instant every `period` ticks while active).
Stacking: `STACK_REFRESH` (one instance, duration reset), `STACK_COUNT`
(up to `max_stacks` independent instances, the oldest replaced), per
source. Effects grant tags while active and are blocked by `immune` tags.

DAMAGE. `damage(target, amount, type)`: resistance per type (fixed point
percent, capped at 100 %), then shield, then health; returns the health
lost; a target at 0 health is reported once in `deaths`.
"""

comptime FX = 1000  # fixed point: 1.0 == 1000

comptime OP_ADD = 0
comptime OP_MUL = 1
comptime OP_OVERRIDE = 2

comptime EVAL_FULL = 0
comptime EVAL_INCREMENTAL = 1
comptime EVAL_DIRTY = 2

comptime KIND_INSTANT = 0
comptime KIND_DURATION = 1
comptime KIND_INFINITE = 2
comptime KIND_PERIODIC = 3

comptime STACK_REFRESH = 0
comptime STACK_COUNT = 1


@fieldwise_init
struct Modifier(Copyable, ImplicitlyCopyable, Movable):
    var attr: Int
    var op: Int
    var value: Int  # fixed point (add) or per-mille (mul) or fixed point (override)
    var source: Int  # handle returned by add_modifier
    var priority: Int


struct TagRegistry(Movable):
    var names: List[String]
    var parent: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.parent = List[Int]()

    def intern(mut self, name: String) raises -> Int:
        """Id of `name`, registering it (and its parents) if new; at most
        64 tags (a tag set is one `UInt64`)."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        var par = -1
        var cut = -1
        var b = name.as_bytes()
        for i in range(len(b)):
            if b[i] == UInt8(46):  # "."
                cut = i
        if cut > 0:
            par = self.intern(String(name[byte=0:cut]))
        if len(self.names) >= 64:
            raise Error("TagRegistry: more than 64 tags")
        self.names.append(name)
        self.parent.append(par)
        return len(self.names) - 1

    def with_parents(self, id: Int) -> UInt64:
        var bits = UInt64(0)
        var t = id
        while t >= 0:
            bits |= UInt64(1) << UInt64(t)
            t = self.parent[t]
        return bits


@fieldwise_init
struct EffectDef(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var duration: Int  # ticks (duration / periodic)
    var period: Int  # ticks (periodic)
    var attr: Int
    var op: Int
    var value: Int
    var grants: UInt64  # tag bits while active
    var immune_if: UInt64  # blocked when the target has any of these
    var stacking: Int
    var max_stacks: Int


@fieldwise_init
struct EffectInst(Copyable, ImplicitlyCopyable, Movable):
    var def_id: Int
    var source: Int  # who applied it (stacking per source)
    var expires: Int  # tick; -1 = never
    var next_period: Int
    var handle: Int  # modifier handle (duration / infinite), -1 otherwise
    var started: Int


struct Attributes(Copyable, Movable):
    var base: List[Int]
    var lo: List[Int]
    var hi: List[Int]
    var mods: List[Modifier]
    var mode: Int
    var add_sum: List[Int]
    var mul_sum: List[Int]
    var cache: List[Int]
    var dirty: List[Bool]
    var next_handle: Int
    var ov_count: List[Int]  # override modifiers per attribute (17.70 index)
    # handle -> index in `mods` (17.70): removal finds its modifier without a
    # scan and leaves a tombstone (attr -1) so the order -- the override tie
    # rule -- is kept; tombstones are compacted away once they are half
    var slot: Dict[Int, Int]
    var dead: Int

    def __init__(out self, n: Int, mode: Int = EVAL_INCREMENTAL):
        self.base = List[Int](length=n, fill=0)
        self.lo = List[Int](length=n, fill=-(1 << 60))
        self.hi = List[Int](length=n, fill=1 << 60)
        self.mods = List[Modifier]()
        self.mode = mode
        self.add_sum = List[Int](length=n, fill=0)
        self.mul_sum = List[Int](length=n, fill=0)
        self.cache = List[Int](length=n, fill=0)
        self.dirty = List[Bool](length=n, fill=True)
        self.next_handle = 1
        self.ov_count = List[Int](length=n, fill=0)
        self.slot = Dict[Int, Int]()
        self.dead = 0

    def modifier_count(self) -> Int:
        return len(self.mods) - self.dead

    def _reindex(mut self):
        """Drop tombstones (order kept) and rebuild the handle index."""
        var live = List[Modifier](capacity=len(self.mods) - self.dead)
        self.slot = Dict[Int, Int]()
        for m in self.mods:
            if m.attr >= 0:
                self.slot[m.source] = len(live)
                live.append(m)
        self.mods = live^
        self.dead = 0

    def set_base(mut self, a: Int, v: Int):
        self.base[a] = v
        self.dirty[a] = True

    def set_range(mut self, a: Int, lo: Int, hi: Int):
        self.lo[a] = lo
        self.hi[a] = hi
        self.dirty[a] = True

    def add_modifier(mut self, attr: Int, op: Int, value: Int, priority: Int = 0) -> Int:
        var h = self.next_handle
        self.next_handle += 1
        self.slot[h] = len(self.mods)
        self.mods.append(Modifier(attr, op, value, h, priority))
        match op:
            case == OP_ADD:
                self.add_sum[attr] += value
            case == OP_MUL:
                self.mul_sum[attr] += value
            case _:
                self.ov_count[attr] += 1
        self.dirty[attr] = True
        return h

    def remove_modifier(mut self, handle: Int) -> Bool:
        """False if no modifier has this handle (removing twice is harmless)."""
        var i = self.slot.get(handle, -1)
        if i < 0:
            return False
        _ = self.slot.pop(handle, -1)
        var m = self.mods[i]
        match m.op:
            case == OP_ADD:
                self.add_sum[m.attr] -= m.value
            case == OP_MUL:
                self.mul_sum[m.attr] -= m.value
            case _:
                self.ov_count[m.attr] -= 1
        self.dirty[m.attr] = True
        self.mods[i].attr = -1  # tombstone: matches no attribute
        self.dead += 1
        if self.dead * 2 > len(self.mods):
            self._reindex()
        return True

    def _override(self, a: Int) -> Tuple[Bool, Int]:
        # index: most attributes carry no override, skip the scan (the
        # scan, when it runs, keeps the priority / tie order)
        if self.ov_count[a] == 0:
            return (False, 0)
        var found = False
        var best_p = 0
        var v = 0
        for m in self.mods:
            if m.attr == a and m.op == OP_OVERRIDE and (not found or m.priority >= best_p):
                found = True
                best_p = m.priority
                v = m.value
        return (found, v)

    def _combine(self, a: Int, add: Int, mul: Int) -> Int:
        var ov = self._override(a)
        var v = ov[1] if ov[0] else (self.base[a] + add) * (FX + mul) // FX
        return min(max(v, self.lo[a]), self.hi[a])

    def value(mut self, a: Int) -> Int:
        if self.mode == EVAL_FULL:
            var add = 0
            var mul = 0
            for m in self.mods:
                if m.attr == a:
                    if m.op == OP_ADD:
                        add += m.value
                    elif m.op == OP_MUL:
                        mul += m.value
            return self._combine(a, add, mul)
        if self.mode == EVAL_INCREMENTAL:
            return self._combine(a, self.add_sum[a], self.mul_sum[a])
        if self.dirty[a]:
            self.cache[a] = self._combine(a, self.add_sum[a], self.mul_sum[a])
            self.dirty[a] = False
        return self.cache[a]


struct Actor(Copyable, Movable):
    """One entity's rules state."""

    var attrs: Attributes
    var tags: UInt64  # explicit tags (with parents)
    var effects: List[EffectInst]
    var shield: Int
    var resist: List[Int]  # per damage type, per mille
    var dead: Bool

    def __init__(out self, n_attrs: Int, n_types: Int, mode: Int = EVAL_INCREMENTAL):
        self.attrs = Attributes(n_attrs, mode)
        self.tags = 0
        self.effects = List[EffectInst]()
        self.shield = 0
        self.resist = List[Int](length=n_types, fill=0)
        self.dead = False

    def all_tags(self, defs: List[EffectDef]) -> UInt64:
        var t = self.tags
        for e in self.effects:
            t |= defs[e.def_id].grants
        return t


struct Rules(Movable):
    """Effect definitions plus the per-tick driver for a set of actors."""

    var defs: List[EffectDef]
    var health_attr: Int
    var deaths: List[Int]  # actors that reached 0 health this tick
    var tick: Int

    def __init__(out self, health_attr: Int):
        self.defs = List[EffectDef]()
        self.health_attr = health_attr
        self.deaths = List[Int]()
        self.tick = 0

    def define(mut self, d: EffectDef) -> Int:
        self.defs.append(d)
        return len(self.defs) - 1

    def apply(mut self, mut a: Actor, def_id: Int, source: Int) -> Bool:
        """Apply effect `def_id` from `source`; False if blocked by immunity
        or the target is dead."""
        var d = self.defs[def_id]
        if a.dead or (a.all_tags(self.defs) & d.immune_if) != 0:
            return False
        if d.kind == KIND_INSTANT:
            a.attrs.set_base(d.attr, a.attrs.base[d.attr] + d.value)
            return True
        var expires = -1 if d.kind == KIND_INFINITE else self.tick + d.duration
        # stacking
        var same = List[Int]()
        for i in range(len(a.effects)):
            if a.effects[i].def_id == def_id and a.effects[i].source == source:
                same.append(i)
        if d.stacking == STACK_REFRESH and len(same) > 0:
            a.effects[same[0]].expires = expires
            return True
        if d.stacking == STACK_COUNT and len(same) >= d.max_stacks:
            var oldest = same[0]
            for i in same:
                if a.effects[i].started < a.effects[oldest].started:
                    oldest = i
            self._end(a, oldest)
        var h = -1
        if d.kind != KIND_PERIODIC:
            h = a.attrs.add_modifier(d.attr, d.op, d.value)
        a.effects.append(EffectInst(def_id, source, expires, self.tick + d.period, h, self.tick))
        return True

    def _end(mut self, mut a: Actor, i: Int):
        if a.effects[i].handle >= 0:
            _ = a.attrs.remove_modifier(a.effects[i].handle)
        _ = a.effects.pop(i)

    def stacks(self, a: Actor, def_id: Int) -> Int:
        var n = 0
        for e in a.effects:
            if e.def_id == def_id:
                n += 1
        return n

    def damage(mut self, mut a: Actor, idx: Int, amount: Int, dtype: Int) -> Int:
        """Resistance, then shield, then health (all fixed point). Returns the
        health lost; records a death once."""
        if a.dead or amount <= 0:
            return 0
        var r = min(a.resist[dtype], FX)
        var d = amount * (FX - r) // FX
        var absorbed = min(d, a.shield)
        a.shield -= absorbed
        d -= absorbed
        var hp = a.attrs.base[self.health_attr]
        var lost = min(d, max(hp, 0))
        a.attrs.set_base(self.health_attr, hp - lost)
        if hp - lost <= 0:
            a.dead = True
            self.deaths.append(idx)
        return lost

    def step(mut self, mut actors: List[Actor]):
        """Advance one tick: periodic effects fire, expired effects end."""
        self.tick += 1
        self.deaths = List[Int]()
        for k in range(len(actors)):
            var i = 0
            while i < len(actors[k].effects):
                var e = actors[k].effects[i]
                var d = self.defs[e.def_id]
                if d.kind == KIND_PERIODIC and self.tick >= e.next_period and (e.expires < 0 or self.tick <= e.expires):
                    if d.attr == self.health_attr and d.value < 0:
                        _ = self.damage(actors[k], k, -d.value, 0)
                    else:
                        actors[k].attrs.set_base(d.attr, actors[k].attrs.base[d.attr] + d.value)
                    actors[k].effects[i].next_period = self.tick + d.period
                if e.expires >= 0 and self.tick >= e.expires:
                    self._end(actors[k], i)
                    continue
                i += 1


def _put(mut b: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        b.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _get(b: List[UInt8], mut at: Int) raises -> Int:
    if at + 8 > len(b):
        raise Error("rules: truncated state")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(b[at + k]) << UInt64(8 * k)
    at += 8
    return Int(u)


def actor_to_bytes(a: Actor) -> List[UInt8]:
    var b = List[UInt8]()
    var n = len(a.attrs.base)
    _put(b, n)
    for i in range(n):
        _put(b, a.attrs.base[i])
        _put(b, a.attrs.lo[i])
        _put(b, a.attrs.hi[i])
    _put(b, a.attrs.modifier_count())
    for m in a.attrs.mods:
        if m.attr < 0:
            continue
        _put(b, m.attr)
        _put(b, m.op)
        _put(b, m.value)
        _put(b, m.source)
        _put(b, m.priority)
    _put(b, a.attrs.next_handle)
    _put(b, a.attrs.mode)
    _put(b, Int(a.tags))
    _put(b, len(a.effects))
    for e in a.effects:
        _put(b, e.def_id)
        _put(b, e.source)
        _put(b, e.expires)
        _put(b, e.next_period)
        _put(b, e.handle)
        _put(b, e.started)
    _put(b, a.shield)
    _put(b, len(a.resist))
    for r in a.resist:
        _put(b, r)
    _put(b, 1 if a.dead else 0)
    return b^


def actor_from_bytes(b: List[UInt8]) raises -> Actor:
    var at = 0
    var n = _get(b, at)
    if n < 0 or n > 4096:
        raise Error("rules: corrupt attribute count")
    var base = List[Int]()
    var lo = List[Int]()
    var hi = List[Int]()
    for _ in range(n):
        base.append(_get(b, at))
        lo.append(_get(b, at))
        hi.append(_get(b, at))
    var nm = _get(b, at)
    var mods = List[Modifier]()
    for _ in range(nm):
        var attr = _get(b, at)
        var op = _get(b, at)
        var value = _get(b, at)
        var src = _get(b, at)
        var pri = _get(b, at)
        if attr < 0 or attr >= n:
            raise Error("rules: modifier on a missing attribute")
        mods.append(Modifier(attr, op, value, src, pri))
    var nh = _get(b, at)
    var mode = _get(b, at)
    var a = Actor(n, 0, mode)
    a.attrs.base = base^
    a.attrs.lo = lo^
    a.attrs.hi = hi^
    for m in mods:
        match m.op:
            case == OP_ADD:
                a.attrs.add_sum[m.attr] += m.value
            case == OP_MUL:
                a.attrs.mul_sum[m.attr] += m.value
            case _:
                a.attrs.ov_count[m.attr] += 1
    a.attrs.mods = mods^
    a.attrs._reindex()
    a.attrs.next_handle = nh
    a.tags = UInt64(_get(b, at))
    var ne = _get(b, at)
    for _ in range(ne):
        var d = _get(b, at)
        var s = _get(b, at)
        var ex = _get(b, at)
        var np = _get(b, at)
        var h = _get(b, at)
        var st = _get(b, at)
        a.effects.append(EffectInst(d, s, ex, np, h, st))
    a.shield = _get(b, at)
    var nr = _get(b, at)
    for _ in range(nr):
        a.resist.append(_get(b, at))
    a.dead = _get(b, at) == 1
    return a^
