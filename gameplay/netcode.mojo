"""Rollback netcode core and prediction-strategy seam (ROADMAP 17.16).

Platform direction C: the host owns transport and wire framing; this module
owns determinism-dependent logic and hands the host byte payloads.

- `NetSim`: what a networked simulation must offer -- step one tick from one
  input per player, save / load exact bytes, hash. `ArenaSim` is a concrete
  one (players as boxes in a `ContactScene6`, pushable crates).
- `PlayerInput`: 12-byte quantised input; messages carry every input the
  receiver has not acknowledged yet (redundancy, so loss and reordering need
  no retransmit protocol) plus the newest final-state hash for desync checks.
- Strategies, one per peer type (the seam is the parity law: every strategy
  ends at the same world as applying the inputs offline):
  * `LockstepPeer`: steps tick t only once every player's input for t has
    arrived; never mispredicts, latency = the slowest link.
  * `RollbackPeer` (GGPO): steps immediately with predicted remote inputs
    (the last confirmed one), keeps a ring of snapshots, and on a late input
    that differs from its prediction loads the snapshot of that tick and
    re-simulates to the present. Rolling back past the ring is counted
    (`too_deep`) and the peer stalls until it can confirm instead.
  * `SnapshotServer` / `SnapshotClient`: the server steps in lockstep on the
    clients' inputs and sends binary snapshots, delta-encoded (XOR + run
    length of zero bytes) against the last snapshot the client acknowledged;
    clients only display.
- Desync detection: every peer keeps the hash of each tick it stepped with
  confirmed inputs; messages carry the newest one; a peer that holds a
  different hash for that tick records `desync_tick`.
- `InputValidator` / `motion_plausible`: server-side rejection of inputs from
  the wrong player, too old, too far ahead, or contradicting an earlier
  input for the same tick; a speed check for host-trusted positions.
- Lag compensation: `PoseRing` keeps collider poses for the last K ticks;
  `rewind_ray_cast` casts against the world as it was at a past tick.
- `SimLink`: a deterministic in-process link (latency, jitter, loss) for
  tests and tools -- not a transport.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_bytes, scene_from_bytes
from collision.collider_set import Pose3
from collision.world_query import ray_cast, Hit, QueryFilter

comptime MSG_INPUTS: UInt8 = 1
comptime MSG_SNAPSHOT: UInt8 = 2

comptime INPUT_OK = 0
comptime INPUT_BAD_PLAYER = 1
comptime INPUT_TOO_OLD = 2
comptime INPUT_TOO_FAR_AHEAD = 3
comptime INPUT_CONFLICT = 4


# ------------------------------------------------------------------ bytes


def put_u64(mut out: List[UInt8], v: UInt64):
    for k in range(8):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def get_u64(data: List[UInt8], mut pos: Int) raises -> UInt64:
    if pos + 8 > len(data):
        raise Error("netcode: truncated message")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return u


def put_int(mut out: List[UInt8], v: Int):
    put_u64(out, UInt64(v))


def get_int(data: List[UInt8], mut pos: Int) raises -> Int:
    return Int(get_u64(data, pos))


def get_u8(data: List[UInt8], mut pos: Int) raises -> UInt8:
    if pos >= len(data):
        raise Error("netcode: truncated message")
    pos += 1
    return data[pos - 1]


# ------------------------------------------------------------------ input


@fieldwise_init
struct PlayerInput(Copyable, ImplicitlyCopyable, Movable, Equatable):
    var tick: Int
    var player: Int
    var mx: Int8  # move x, -127..127
    var mz: Int8
    var buttons: UInt8

    @staticmethod
    def neutral(tick: Int, player: Int) -> PlayerInput:
        return PlayerInput(tick, player, 0, 0, 0)

    def __eq__(self, o: Self) -> Bool:
        return self.tick == o.tick and self.player == o.player and self.mx == o.mx and self.mz == o.mz and self.buttons == o.buttons

    def __ne__(self, o: Self) -> Bool:
        return not self == o

    def same_action(self, o: PlayerInput) -> Bool:
        """Equal apart from the tick stamp (what prediction is judged by)."""
        return self.mx == o.mx and self.mz == o.mz and self.buttons == o.buttons

    def encode(self, mut out: List[UInt8]):
        put_int(out, self.tick)
        out.append(UInt8(self.player))
        out.append(UInt8(Int(self.mx) & 0xFF))
        out.append(UInt8(Int(self.mz) & 0xFF))
        out.append(self.buttons)

    @staticmethod
    def decode(data: List[UInt8], mut pos: Int) raises -> PlayerInput:
        var t = get_int(data, pos)
        var p = Int(get_u8(data, pos))
        var mx = Int(get_u8(data, pos))
        var mz = Int(get_u8(data, pos))
        var b = get_u8(data, pos)
        return PlayerInput(t, p, Int8(mx - 256 if mx > 127 else mx), Int8(mz - 256 if mz > 127 else mz), b)


struct InputLog(Movable):
    """Per player, per tick: the confirmed input, if any."""

    var players: Int
    var val: List[List[PlayerInput]]
    var have: List[List[Bool]]

    def __init__(out self, players: Int):
        self.players = players
        self.val = List[List[PlayerInput]]()
        self.have = List[List[Bool]]()
        for _ in range(players):
            self.val.append(List[PlayerInput]())
            self.have.append(List[Bool]())

    def _grow(mut self, p: Int, t: Int):
        while len(self.have[p]) <= t:
            self.have[p].append(False)
            self.val[p].append(PlayerInput.neutral(len(self.val[p]), p))

    def put(mut self, inp: PlayerInput) -> Bool:
        """Store a confirmed input; False if it was already known."""
        self._grow(inp.player, inp.tick)
        if self.have[inp.player][inp.tick]:
            return False
        self.have[inp.player][inp.tick] = True
        self.val[inp.player][inp.tick] = inp
        return True

    def has(self, p: Int, t: Int) -> Bool:
        return t >= 0 and t < len(self.have[p]) and self.have[p][t]

    def get(self, p: Int, t: Int) -> PlayerInput:
        return self.val[p][t]

    def contiguous(self, p: Int) -> Int:
        """Highest tick t such that every tick 0..t is confirmed (-1 if none)."""
        var t = 0
        while t < len(self.have[p]) and self.have[p][t]:
            t += 1
        return t - 1

    def predict(self, p: Int, t: Int) -> PlayerInput:
        """Confirmed input for t, else the newest confirmed one before t
        (repeat-last prediction), else neutral."""
        if self.has(p, t):
            return self.val[p][t]
        var k = min(t, len(self.have[p]) - 1)
        while k >= 0:
            if self.have[p][k]:
                var v = self.val[p][k]
                return PlayerInput(t, p, v.mx, v.mz, v.buttons)
            k -= 1
        return PlayerInput.neutral(t, p)

    def all_confirmed(self, t: Int) -> Bool:
        for p in range(self.players):
            if not self.has(p, t):
                return False
        return True


def encode_inputs(
    from_node: Int, log: InputLog, player: Int, first: Int, last: Int, ack: Int, hash_tick: Int, hash: UInt64
) -> List[UInt8]:
    """MSG_INPUTS: sender, ack (highest contiguous tick the sender holds of
    the receiver's inputs), newest final hash, and the sender's own inputs
    for ticks first..last that are confirmed."""
    var out = List[UInt8]()
    out.append(MSG_INPUTS)
    out.append(UInt8(from_node))
    put_int(out, ack)
    put_int(out, hash_tick)
    put_u64(out, hash)
    var n = 0
    for t in range(max(first, 0), last + 1):
        if log.has(player, t):
            n += 1
    put_int(out, n)
    for t in range(max(first, 0), last + 1):
        if log.has(player, t):
            log.get(player, t).encode(out)
    return out^


# ------------------------------------------------------------------ simulations


trait NetSim(Movable, Deinitable):
    def players(self) -> Int:
        ...

    def tick(self) -> Int:
        ...

    def step(mut self, inputs: List[PlayerInput]) raises:
        """Advance one tick; inputs[p] is player p's input for this tick."""
        ...

    def save(self) -> List[UInt8]:
        ...

    def load(mut self, data: List[UInt8]) raises:
        ...

    def hash(self) -> UInt64:
        ...


def fnv_bodies(sc: ContactScene6[QuatBody6], tick: Int) -> UInt64:
    """FNV-1a over every body's position and velocity bit patterns and the tick."""
    var h = UInt64(0xCBF29CE484222325)
    h = (h ^ UInt64(tick)) * 0x100000001B3
    for i in range(len(sc.bset.bodies)):
        var p = sc.bset.bodies[i].position()
        var v = sc.bset.bodies[i].linear_velocity()
        for k in range(3):
            h = (h ^ UInt64(p[k].to_bits())) * 0x100000001B3
            h = (h ^ UInt64(v[k].to_bits())) * 0x100000001B3
    return h


struct ArenaSim(NetSim):
    """Players are 0.8 m boxes driven by their input's move vector (5 m/s at
    full deflection) on a 20 x 20 m walled floor with pushable crates; button
    1 jumps when grounded."""

    var scene: ContactScene6[QuatBody6]
    var body_of: List[Int]
    var n: Int
    var t: Int
    var dt: Real

    def __init__(out self, players: Int, crates: Int, dt: Real = 1.0 / 60.0):
        self.scene = ContactScene6[QuatBody6]()
        self.n = players
        self.t = 0
        self.dt = dt
        self.body_of = List[Int]()
        _ = self.scene.add(QuatBody6.at_rest(Vec3(10, -0.5, 10, 0), Inertia3.box(1, 11, 0.5, 11)), Vec3(11, 0.5, 11, 0), True)
        for w in range(4):
            var c = Vec3(10, 1, -0.5, 0) if w == 0 else (Vec3(10, 1, 20.5, 0) if w == 1 else (Vec3(-0.5, 1, 10, 0) if w == 2 else Vec3(20.5, 1, 10, 0)))
            var hx = Real(11) if w < 2 else Real(0.5)
            var hz = Real(0.5) if w < 2 else Real(11)
            _ = self.scene.add(QuatBody6.at_rest(c, Inertia3.box(1, hx, 1, hz)), Vec3(hx, 1, hz, 0), True)
        for p in range(players):
            var a = Real(p) * 2.5 + 3
            var id = self.scene.add(QuatBody6.at_rest(Vec3(a, 0.4, 4, 0), Inertia3.box(2, 0.4, 0.4, 0.4)), Vec3(0.4, 0.4, 0.4, 0), False)
            self.body_of.append(id.index())
        for c in range(crates):
            _ = self.scene.add(
                QuatBody6.at_rest(Vec3(Real(c % 4) * 3 + 5, 0.3 + Real(c // 4) * 0.61, 10, 0), Inertia3.box(1, 0.3, 0.3, 0.3)),
                Vec3(0.3, 0.3, 0.3, 0), False,
            )

    def players(self) -> Int:
        return self.n

    def tick(self) -> Int:
        return self.t

    def step(mut self, inputs: List[PlayerInput]) raises:
        for p in range(self.n):
            var i = self.body_of[p]
            var inp = inputs[p]
            var v = self.scene.bset.bodies[i].linear_velocity()
            var tv = Vec3(Real(Int(inp.mx)) / 127 * 5, v[1], Real(Int(inp.mz)) / 127 * 5, 0)
            if inp.buttons & 1 != 0 and self.scene.bset.bodies[i].position()[1] < 0.45:
                tv[1] = 4
            var id = self.scene.bset.id_of(i)
            self.scene.wake(id)
            self.scene.set_velocity(id, tv, self.scene.bset.bodies[i].omega_world())
        self.scene.step_soft(self.dt, Vec3(0, -9.8, 0, 0))
        self.t += 1

    def save(self) -> List[UInt8]:
        var out = List[UInt8]()
        put_int(out, self.t)
        var b = scene_to_bytes(self.scene)
        for x in b:
            out.append(x)
        return out^

    def load(mut self, data: List[UInt8]) raises:
        var pos = 0
        var t = get_int(data, pos)
        var rest = List[UInt8](capacity=len(data) - 8)
        for k in range(8, len(data)):
            rest.append(data[k])
        self.scene = scene_from_bytes(rest^)
        self.t = t

    def hash(self) -> UInt64:
        return fnv_bodies(self.scene, self.t)


def run_offline[S: NetSim](mut sim: S, log: InputLog, until: Int) raises:
    """Reference: apply the confirmed inputs tick by tick (every input must
    be present)."""
    while sim.tick() < until:
        var ins = List[PlayerInput]()
        for p in range(sim.players()):
            ins.append(log.predict(p, sim.tick()))
        sim.step(ins)


# ------------------------------------------------------------------ peers


trait NetPeer(Movable, Deinitable):
    def submit(mut self, inp: PlayerInput):
        """The local player's input for some tick (the caller's clock)."""
        ...

    def outgoing(mut self, to_node: Int) -> List[UInt8]:
        ...

    def receive(mut self, from_node: Int, msg: List[UInt8]) raises:
        ...

    def update(mut self, target: Int) raises:
        """Advance toward tick `target` as far as the strategy allows."""
        ...

    def sim_tick(self) -> Int:
        ...

    def world_hash(self) -> UInt64:
        ...


struct _Hashes(Movable):
    """Final hash per tick (state after stepping that tick with confirmed
    inputs for every player)."""

    var h: List[UInt64]
    var known: List[Bool]
    var newest: Int

    def __init__(out self):
        self.h = List[UInt64]()
        self.known = List[Bool]()
        self.newest = -1

    def put(mut self, t: Int, v: UInt64):
        while len(self.h) <= t:
            self.h.append(0)
            self.known.append(False)
        self.h[t] = v
        self.known[t] = True
        self.newest = max(self.newest, t)

    def check(self, t: Int, v: UInt64) -> Bool:
        """False when this peer holds a different final hash for t."""
        if t < 0 or t >= len(self.h) or not self.known[t]:
            return True
        return self.h[t] == v


struct LockstepPeer[S: NetSim](NetPeer):
    var sim: Self.S
    var node: Int
    var log: InputLog
    var acks: List[Int]  # per node: highest contiguous tick of OUR inputs it holds
    var hashes: _Hashes
    var desync_tick: Int
    var stalls: Int

    def __init__(out self, var sim: Self.S, node: Int):
        self.node = node
        self.log = InputLog(sim.players())
        self.acks = List[Int](length=sim.players(), fill=-1)
        self.sim = sim^
        self.hashes = _Hashes()
        self.desync_tick = -1
        self.stalls = 0

    def submit(mut self, inp: PlayerInput):
        _ = self.log.put(inp)

    def outgoing(mut self, to_node: Int) -> List[UInt8]:
        var last = len(self.log.have[self.node]) - 1
        var ht = self.hashes.newest
        return encode_inputs(
            self.node, self.log, self.node, self.acks[to_node] + 1, last,
            self.log.contiguous(to_node), ht, self.hashes.h[ht] if ht >= 0 else UInt64(0),
        )

    def receive(mut self, from_node: Int, msg: List[UInt8]) raises:
        var r = decode_inputs(msg)
        self.acks[from_node] = max(self.acks[from_node], r.ack)
        for inp in r.inputs:
            if inp.player == from_node:
                _ = self.log.put(inp)
        if not self.hashes.check(r.hash_tick, r.hash) and self.desync_tick < 0:
            self.desync_tick = r.hash_tick

    def update(mut self, target: Int) raises:
        while self.sim.tick() < target:
            var t = self.sim.tick()
            if not self.log.all_confirmed(t):
                self.stalls += 1
                return
            var ins = List[PlayerInput]()
            for p in range(self.sim.players()):
                ins.append(self.log.get(p, t))
            self.sim.step(ins)
            self.hashes.put(t, self.sim.hash())

    def sim_tick(self) -> Int:
        return self.sim.tick()

    def world_hash(self) -> UInt64:
        return self.sim.hash()


struct RollbackPeer[S: NetSim](NetPeer):
    var sim: Self.S
    var node: Int
    var log: InputLog
    var acks: List[Int]
    var max_rollback: Int
    var ring: List[List[UInt8]]  # snapshot before stepping tick t at t % len
    var ring_tick: List[Int]
    var used: List[List[PlayerInput]]  # input used for tick t (ring) per player
    var step_hash: List[UInt64]  # hash after stepping tick t (ring)
    var final_upto: Int  # ticks <= this have their final hash recorded
    var pending: Int  # earliest tick whose prediction was wrong, -1 = none
    var hashes: _Hashes
    var desync_tick: Int
    var rollbacks: Int
    var resim_ticks: Int
    var too_deep: Int
    var mispredicted: Int

    def __init__(out self, var sim: Self.S, node: Int, max_rollback: Int = 8):
        self.node = node
        self.log = InputLog(sim.players())
        self.acks = List[Int](length=sim.players(), fill=-1)
        self.max_rollback = max_rollback
        var size = max_rollback + 2
        self.ring = List[List[UInt8]]()
        self.ring_tick = List[Int](length=size, fill=-1)
        self.step_hash = List[UInt64](length=size, fill=0)
        self.final_upto = -1
        self.used = List[List[PlayerInput]]()
        for _ in range(size):
            self.ring.append(List[UInt8]())
            self.used.append(List[PlayerInput]())
        self.sim = sim^
        self.pending = -1
        self.hashes = _Hashes()
        self.desync_tick = -1
        self.rollbacks = 0
        self.resim_ticks = 0
        self.too_deep = 0
        self.mispredicted = 0

    def confirmed(self) -> Int:
        var c = Int.MAX
        for p in range(self.sim.players()):
            c = min(c, self.log.contiguous(p))
        return c

    def submit(mut self, inp: PlayerInput):
        _ = self.log.put(inp)

    def outgoing(mut self, to_node: Int) -> List[UInt8]:
        var last = len(self.log.have[self.node]) - 1
        var ht = self.hashes.newest
        return encode_inputs(
            self.node, self.log, self.node, self.acks[to_node] + 1, last,
            self.log.contiguous(to_node), ht, self.hashes.h[ht] if ht >= 0 else UInt64(0),
        )

    def receive(mut self, from_node: Int, msg: List[UInt8]) raises:
        var r = decode_inputs(msg)
        self.acks[from_node] = max(self.acks[from_node], r.ack)
        var size = len(self.ring_tick)
        for inp in r.inputs:
            if inp.player != from_node or not self.log.put(inp):
                continue
            var t = inp.tick
            if t < self.sim.tick():
                var slot = t % size
                var ok = self.ring_tick[slot] == t and len(self.used[slot]) > inp.player
                if not ok or not self.used[slot][inp.player].same_action(inp):
                    self.mispredicted += 1
                    self.pending = t if self.pending < 0 else min(self.pending, t)
        if not self.hashes.check(r.hash_tick, r.hash) and self.desync_tick < 0:
            self.desync_tick = r.hash_tick

    def _step_once(mut self) raises:
        var t = self.sim.tick()
        var size = len(self.ring_tick)
        var slot = t % size
        self.ring[slot] = self.sim.save()
        self.ring_tick[slot] = t
        var ins = List[PlayerInput]()
        for p in range(self.sim.players()):
            ins.append(self.log.predict(p, t))
        self.used[slot] = ins.copy()
        self.sim.step(ins)
        self.step_hash[slot] = self.sim.hash()

    def update(mut self, target: Int) raises:
        var size = len(self.ring_tick)
        if self.pending >= 0:
            var t = self.pending
            var slot = t % size
            if self.ring_tick[slot] != t:
                # the snapshot is gone: we cannot correct; count it and keep
                # going -- the hash exchange will report the desync
                self.too_deep += 1
                self.pending = -1
            else:
                var now = self.sim.tick()
                self.sim.load(self.ring[slot])
                self.rollbacks += 1
                self.pending = -1
                while self.sim.tick() < now:
                    self._step_once()
                    self.resim_ticks += 1
        while self.sim.tick() < target:
            # never predict further than the ring can roll back
            if self.sim.tick() - (self.confirmed() + 1) >= self.max_rollback:
                break
            self._step_once()
        self._finalise()

    def _finalise(mut self):
        """A stepped tick whose inputs are now all confirmed, with no
        rollback pending at or before it, is final: record its hash."""
        var size = len(self.ring_tick)
        var upto = min(self.confirmed(), self.sim.tick() - 1)
        if self.pending >= 0:
            upto = min(upto, self.pending - 1)
        var t = self.final_upto + 1
        while t <= upto:
            var slot = t % size
            if self.ring_tick[slot] == t:
                self.hashes.put(t, self.step_hash[slot])
            t += 1
        self.final_upto = max(self.final_upto, upto)

    def sim_tick(self) -> Int:
        return self.sim.tick()

    def world_hash(self) -> UInt64:
        return self.sim.hash()


@fieldwise_init
struct _Decoded(Movable):
    var sender: Int
    var ack: Int
    var hash_tick: Int
    var hash: UInt64
    var inputs: List[PlayerInput]


def decode_inputs(msg: List[UInt8]) raises -> _Decoded:
    var pos = 0
    if get_u8(msg, pos) != MSG_INPUTS:
        raise Error("netcode: not an input message")
    var sender = Int(get_u8(msg, pos))
    var ack = get_int(msg, pos)
    var ht = get_int(msg, pos)
    var h = get_u64(msg, pos)
    var n = get_int(msg, pos)
    if n < 0 or n > 1 << 20:
        raise Error("netcode: bad input count")
    var ins = List[PlayerInput]()
    for _ in range(n):
        ins.append(PlayerInput.decode(msg, pos))
    return _Decoded(sender, ack, ht, h, ins^)


# ------------------------------------------------------------------ snapshots


def delta_encode(cur: List[UInt8], base: List[UInt8]) -> List[UInt8]:
    """XOR against `base` (shorter base = zero-extended), then run-length:
    a zero run is (0x00, run length as 1..255); any other byte is itself."""
    var out = List[UInt8]()
    put_int(out, len(cur))
    var i = 0
    while i < len(cur):
        var x = cur[i] ^ (base[i] if i < len(base) else UInt8(0))
        if x != 0:
            out.append(x)
            i += 1
            continue
        var run = 0
        while i < len(cur) and run < 255 and (cur[i] ^ (base[i] if i < len(base) else UInt8(0))) == 0:
            run += 1
            i += 1
        out.append(0)
        out.append(UInt8(run))
    return out^


def delta_decode(data: List[UInt8], mut pos: Int, base: List[UInt8]) raises -> List[UInt8]:
    var n = get_int(data, pos)
    if n < 0 or n > 1 << 30:
        raise Error("netcode: bad snapshot length")
    var out = List[UInt8](capacity=n)
    while len(out) < n:
        var x = get_u8(data, pos)
        if x != 0:
            var i = len(out)
            out.append(x ^ (base[i] if i < len(base) else UInt8(0)))
        else:
            var run = Int(get_u8(data, pos))
            if run == 0 or len(out) + run > n:
                raise Error("netcode: corrupt run")
            for _ in range(run):
                var i = len(out)
                out.append(base[i] if i < len(base) else UInt8(0))
    return out^


struct SnapshotServer[S: NetSim](NetPeer):
    """Authoritative: steps in lockstep on the clients' inputs (nodes
    0..players-1), takes a snapshot every `interval` ticks and sends each
    new one once per client, delta-encoded against the newest snapshot that
    client acknowledged; an unacknowledged snapshot is re-sent after
    `resend_after` ticks (loss). Every message also acknowledges inputs."""

    var sim: Self.S
    var log: InputLog
    var interval: Int
    var sent_ticks: List[Int]  # history of snapshot ticks (ring)
    var sent_bytes: List[List[UInt8]]
    var client_ack: List[Int]  # per client: newest snapshot tick acknowledged
    var sent_to: List[Int]  # per client: newest snapshot tick sent
    var sent_at: List[Int]  # per client: server tick of that send
    var resend_after: Int  # re-send an unacknowledged snapshot after this many update calls
    var clock: Int  # update calls so far (keeps running after the sim stops)
    var input_acks: List[Int]
    var newest_snapshot: Int
    var bytes_out: Int
    var rejected: Int
    var validator: InputValidator

    def __init__(out self, var sim: Self.S, interval: Int = 3, history: Int = 32):
        self.log = InputLog(sim.players())
        self.client_ack = List[Int](length=sim.players(), fill=-1)
        self.sent_to = List[Int](length=sim.players(), fill=-1)
        self.sent_at = List[Int](length=sim.players(), fill=-1)
        self.resend_after = 8
        self.clock = 0
        self.input_acks = List[Int](length=sim.players(), fill=-1)
        self.sim = sim^
        self.interval = interval
        self.sent_ticks = List[Int](length=history, fill=-1)
        self.sent_bytes = List[List[UInt8]]()
        for _ in range(history):
            self.sent_bytes.append(List[UInt8]())
        self.newest_snapshot = -1
        self.bytes_out = 0
        self.rejected = 0
        self.validator = InputValidator(self.sim.players(), 64, 128)

    def submit(mut self, inp: PlayerInput):
        pass  # the server has no player

    def _find(self, t: Int) -> Int:
        if t < 0:
            return -1
        var slot = (t // self.interval) % len(self.sent_ticks)
        return slot if self.sent_ticks[slot] == t else -1

    def outgoing(mut self, to_node: Int) -> List[UInt8]:
        var out = List[UInt8]()
        out.append(MSG_SNAPSHOT)
        put_int(out, self.log.contiguous(to_node))  # input ack
        var fresh = self.newest_snapshot > self.sent_to[to_node]
        var stale = self.newest_snapshot > self.client_ack[to_node] and self.clock - self.sent_at[to_node] >= self.resend_after
        if self.newest_snapshot < 0 or not (fresh or stale):
            put_int(out, -1)  # inputs ack only
            self.bytes_out += len(out)
            return out^
        self.sent_to[to_node] = self.newest_snapshot
        self.sent_at[to_node] = self.clock
        var cur_slot = self._find(self.newest_snapshot)
        var base_slot = self._find(self.client_ack[to_node])
        put_int(out, self.newest_snapshot)
        var base_tick = self.sent_ticks[base_slot] if base_slot >= 0 else -1
        put_int(out, base_tick)
        var d: List[UInt8]
        if base_slot >= 0:
            d = delta_encode(self.sent_bytes[cur_slot], self.sent_bytes[base_slot])
        else:
            d = delta_encode(self.sent_bytes[cur_slot], List[UInt8]())
        for x in d:
            out.append(x)
        self.bytes_out += len(out)
        return out^

    def receive(mut self, from_node: Int, msg: List[UInt8]) raises:
        var pos = 0
        if get_u8(msg, pos) != MSG_INPUTS:
            raise Error("netcode: server expects input messages")
        var r = decode_inputs(msg)
        # a client acknowledges snapshots by echoing the tick in hash_tick
        self.client_ack[from_node] = max(self.client_ack[from_node], r.hash_tick)
        for inp in r.inputs:
            var code = self.validator.check(inp, from_node, self.sim.tick(), self.log)
            if code != INPUT_OK:
                self.rejected += 1
                continue
            _ = self.log.put(inp)

    def update(mut self, target: Int) raises:
        self.clock += 1
        while self.sim.tick() < target and self.log.all_confirmed(self.sim.tick()):
            var t = self.sim.tick()
            var ins = List[PlayerInput]()
            for p in range(self.sim.players()):
                ins.append(self.log.get(p, t))
            self.sim.step(ins)
            if self.sim.tick() % self.interval == 0:
                var slot = (self.sim.tick() // self.interval) % len(self.sent_ticks)
                self.sent_ticks[slot] = self.sim.tick()
                self.sent_bytes[slot] = self.sim.save()
                self.newest_snapshot = self.sim.tick()

    def sim_tick(self) -> Int:
        return self.sim.tick()

    def world_hash(self) -> UInt64:
        return self.sim.hash()


struct SnapshotClient[S: NetSim](NetPeer):
    """Sends inputs, shows the newest snapshot. `newest` is the tick of the
    latest snapshot loaded into `sim`; `prev_tick` is the tick it replaced
    (recorded only, nothing interpolates between them). `have`/`bytes` keep
    a ring of received snapshot ticks and their full bytes, used as delta
    bases."""

    var sim: Self.S
    var node: Int
    var log: InputLog
    var input_ack: Int
    var have: List[Int]  # snapshot ticks held (ring)
    var bytes: List[List[UInt8]]
    var newest: Int
    var prev_tick: Int
    var bytes_in: Int

    def __init__(out self, var sim: Self.S, node: Int, history: Int = 32):
        self.node = node
        self.log = InputLog(sim.players())
        self.sim = sim^
        self.input_ack = -1
        self.have = List[Int](length=history, fill=-1)
        self.bytes = List[List[UInt8]]()
        for _ in range(history):
            self.bytes.append(List[UInt8]())
        self.newest = -1
        self.prev_tick = -1
        self.bytes_in = 0

    def submit(mut self, inp: PlayerInput):
        _ = self.log.put(inp)

    def outgoing(mut self, to_node: Int) -> List[UInt8]:
        var last = len(self.log.have[self.node]) - 1
        return encode_inputs(self.node, self.log, self.node, self.input_ack + 1, last, -1, self.newest, 0)

    def _slot_of(self, t: Int) -> Int:
        for k in range(len(self.have)):
            if self.have[k] == t:
                return k
        return -1

    def receive(mut self, from_node: Int, msg: List[UInt8]) raises:
        self.bytes_in += len(msg)
        var pos = 0
        if get_u8(msg, pos) != MSG_SNAPSHOT:
            raise Error("netcode: client expects snapshot messages")
        self.input_ack = max(self.input_ack, get_int(msg, pos))
        var t = get_int(msg, pos)
        if t < 0 or t <= self.newest:
            return  # nothing yet, or stale / reordered
        var base_tick = get_int(msg, pos)
        var empty = List[UInt8]()
        var bslot = self._slot_of(base_tick) if base_tick >= 0 else -1
        if base_tick >= 0 and bslot < 0:
            return  # base not held (lost); the server will rebase on our ack
        var full: List[UInt8]
        if bslot >= 0:
            full = delta_decode(msg, pos, self.bytes[bslot])
        else:
            full = delta_decode(msg, pos, empty)
        var slot = t % len(self.have)
        self.have[slot] = t
        self.bytes[slot] = full.copy()
        self.prev_tick = self.newest
        self.newest = t
        self.sim.load(full)

    def update(mut self, target: Int) raises:
        pass  # clients do not simulate

    def sim_tick(self) -> Int:
        return self.sim.tick()

    def world_hash(self) -> UInt64:
        return self.sim.hash()


# ------------------------------------------------------------------ validation


struct InputValidator(Copyable, Movable):
    var players: Int
    var max_age: Int  # reject inputs older than now - max_age
    var max_ahead: Int  # reject inputs further than now + max_ahead

    def __init__(out self, players: Int, max_age: Int, max_ahead: Int):
        self.players = players
        self.max_age = max_age
        self.max_ahead = max_ahead

    def check(self, inp: PlayerInput, sender: Int, now: Int, log: InputLog) -> Int:
        if inp.player < 0 or inp.player >= self.players or inp.player != sender:
            return INPUT_BAD_PLAYER
        if inp.tick < now - self.max_age or inp.tick < 0:
            return INPUT_TOO_OLD
        if inp.tick > now + self.max_ahead:
            return INPUT_TOO_FAR_AHEAD
        if log.has(inp.player, inp.tick) and not log.get(inp.player, inp.tick).same_action(inp):
            return INPUT_CONFLICT
        return INPUT_OK


def motion_plausible(p0: Vec3, p1: Vec3, ticks: Int, dt: Real, max_speed: Real, slack: Real = 1.2) -> Bool:
    """A host-trusted position report moved no faster than max_speed x slack."""
    var d = p1 - p0
    return sqrt(dot(d, d)) <= max_speed * slack * dt * Real(max(ticks, 1))


# ------------------------------------------------------------------ lag compensation


struct PoseRing(Movable):
    """Collider poses of the last `capacity` ticks."""

    var ticks: List[Int]
    var poses: List[List[Pose3]]

    def __init__(out self, capacity: Int):
        self.ticks = List[Int](length=capacity, fill=-1)
        self.poses = List[List[Pose3]]()
        for _ in range(capacity):
            self.poses.append(List[Pose3]())

    def record(mut self, tick: Int, var poses: List[Pose3]):
        var slot = tick % len(self.ticks)
        self.ticks[slot] = tick
        self.poses[slot] = poses^

    def has(self, tick: Int) -> Bool:
        return tick >= 0 and self.ticks[tick % len(self.ticks)] == tick


def rewind_ray_cast(
    sc: ContactScene6[QuatBody6], ring: PoseRing, tick: Int, origin: Vec3, dir: Vec3, max_t: Real, f: QueryFilter
) raises -> Hit:
    """Ray against the colliders posed as they were at `tick` (server-side
    hit registration for a shooter who saw that tick). Raises when the tick
    has left the ring."""
    if not ring.has(tick):
        raise Error("rewind_ray_cast: tick not in the pose history")
    return ray_cast(sc.colliders, ring.poses[tick % len(ring.ticks)], origin, dir, max_t, f)


# ------------------------------------------------------------------ test link


struct SimLink(Copyable, Movable):
    """Deterministic in-process link: each message arrives `latency` +
    uniform[0, jitter] ticks later, or is lost with probability `loss`.
    Arrival order is (time, send order), so jitter reorders."""

    var latency: Int
    var jitter: Int
    var loss: Real
    var state: UInt64
    var at: List[Int]
    var seq: List[Int]
    var data: List[List[UInt8]]
    var counter: Int
    var sent_bytes: Int
    var dropped: Int

    def __init__(out self, latency: Int, jitter: Int, loss: Real, seed: UInt64):
        self.latency = latency
        self.jitter = jitter
        self.loss = loss
        self.state = seed
        self.at = List[Int]()
        self.seq = List[Int]()
        self.data = List[List[UInt8]]()
        self.counter = 0
        self.sent_bytes = 0
        self.dropped = 0

    def _rand(mut self) -> Real:
        self.state += 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Real(Float64(z >> 11) * (1.0 / 9007199254740992.0))

    def send(mut self, now: Int, var msg: List[UInt8]):
        self.sent_bytes += len(msg)
        if self.loss > 0 and self._rand() < self.loss:
            self.dropped += 1
            return
        var j = Int(self._rand() * Real(self.jitter + 1)) if self.jitter > 0 else 0
        self.at.append(now + self.latency + j)
        self.seq.append(self.counter)
        self.counter += 1
        self.data.append(msg^)

    def deliver(mut self, now: Int) -> List[List[UInt8]]:
        var out = List[List[UInt8]]()
        while True:
            var best = -1
            for k in range(len(self.at)):
                if self.at[k] <= now and (best < 0 or self.at[k] < self.at[best] or (self.at[k] == self.at[best] and self.seq[k] < self.seq[best])):
                    best = k
            if best < 0:
                break
            out.append(self.data[best].copy())
            _ = self.at.pop(best)
            _ = self.seq.pop(best)
            _ = self.data.pop(best)
        return out^
