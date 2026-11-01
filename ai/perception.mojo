"""Perception: sight, hearing, memory (ROADMAP 17.15).

Sight is two-phase so the engine's own world queries (or any other occlusion
test) do the line-of-sight work in one batch, outside this module:

1. `sight_candidates(tick)` -- every (observer, target) pair of different
   teams within the observer's sight range and field of view; returns the
   rays (eye -> target) to test;
2. the host casts them (`collision.world_query.ray_cast_batch`, a navmesh
   raycast, ...);
3. `commit_sight(visible, tick)` -- a visible pair refreshes the observer's
   memory of that target (position, tick, `SENSE_SIGHT`).

Hearing needs no ray: `hear(pos, radius, team, tick)` records a `SENSE_HEARING`
memory, with the sound's position, in every observer of another team whose
hearing range reaches it (`hearing_scale` x the sound radius).

Memory: one record per (observer, target) in a per-observer list; entries
older than the observer's `memory_ticks` are dropped by `forget(tick)`.
`best_target` returns the most recently sensed target (sight beats hearing on
a tie, then the lower target id), so decisions over it are deterministic.
"""

from std.math import sqrt, pi
from geometry.trig import cos
from geometry.vec import Real, Vec3, dot
from ai.blackboard import Blackboard

comptime SENSE_SIGHT = 0
comptime SENSE_HEARING = 1


@fieldwise_init
struct SenseConfig(Copyable, ImplicitlyCopyable, Movable):
    var sight_range: Real
    var fov_deg: Real  # full cone angle
    var hearing_scale: Real  # hears a sound of radius r up to r * hearing_scale away
    var memory_ticks: Int
    var eye_height: Real

    @staticmethod
    def default() -> SenseConfig:
        return SenseConfig(20, 120, 1, 300, 1.6)


@fieldwise_init
struct Memory(Copyable, ImplicitlyCopyable, Movable):
    var target: Int
    var pos: Vec3
    var tick: Int
    var sense: Int


struct Perception(Movable):
    var cfg: List[SenseConfig]
    var obs_pos: List[Vec3]
    var obs_fwd: List[Vec3]
    var obs_team: List[Int]
    var tgt_pos: List[Vec3]
    var tgt_team: List[Int]
    var tgt_alive: List[Bool]
    var memory: List[List[Memory]]
    # pending sight rays from the last `sight_candidates`
    var ray_obs: List[Int]
    var ray_tgt: List[Int]
    var ray_from: List[Vec3]
    var ray_to: List[Vec3]

    def __init__(out self):
        self.cfg = List[SenseConfig]()
        self.obs_pos = List[Vec3]()
        self.obs_fwd = List[Vec3]()
        self.obs_team = List[Int]()
        self.tgt_pos = List[Vec3]()
        self.tgt_team = List[Int]()
        self.tgt_alive = List[Bool]()
        self.memory = List[List[Memory]]()
        self.ray_obs = List[Int]()
        self.ray_tgt = List[Int]()
        self.ray_from = List[Vec3]()
        self.ray_to = List[Vec3]()

    def add_observer(mut self, pos: Vec3, fwd: Vec3, team: Int, cfg: SenseConfig) raises -> Int:
        if cfg.sight_range < 0 or cfg.fov_deg < 0 or cfg.fov_deg > 360 or cfg.memory_ticks < 0:
            raise Error("Perception.add_observer: invalid SenseConfig")
        self.cfg.append(cfg)
        self.obs_pos.append(pos)
        self.obs_fwd.append(fwd)
        self.obs_team.append(team)
        self.memory.append(List[Memory]())
        return len(self.obs_pos) - 1

    def add_target(mut self, pos: Vec3, team: Int) -> Int:
        self.tgt_pos.append(pos)
        self.tgt_team.append(team)
        self.tgt_alive.append(True)
        return len(self.tgt_pos) - 1

    def remove_target(mut self, t: Int):
        """The target despawned: no new sightings; memories of it are dropped."""
        self.tgt_alive[t] = False
        for o in range(len(self.memory)):
            var keep = List[Memory]()
            for m in self.memory[o]:
                if m.target != t:
                    keep.append(m)
            self.memory[o] = keep^

    def set_observer(mut self, o: Int, pos: Vec3, fwd: Vec3):
        self.obs_pos[o] = pos
        self.obs_fwd[o] = fwd

    def set_target(mut self, t: Int, pos: Vec3):
        self.tgt_pos[t] = pos

    def eye(self, o: Int) -> Vec3:
        return self.obs_pos[o] + Vec3(0, self.cfg[o].eye_height, 0, 0)

    def sight_candidates(mut self) -> Int:
        """Fill the ray lists with every in-range, in-cone pair; returns the
        count. Cone test in XZ against the observer's forward direction."""
        self.ray_obs.clear()
        self.ray_tgt.clear()
        self.ray_from.clear()
        self.ray_to.clear()
        for o in range(len(self.obs_pos)):
            var c = self.cfg[o]
            var half = Real(c.fov_deg) * Real(pi) / 360
            var cos_half = cos(half)
            var f = self.obs_fwd[o]
            f[1] = 0
            var fl = sqrt(dot(f, f))
            for t in range(len(self.tgt_pos)):
                if not self.tgt_alive[t] or self.tgt_team[t] == self.obs_team[o]:
                    continue
                var d = self.tgt_pos[t] - self.obs_pos[o]
                var d2 = dot(d, d)
                if d2 > c.sight_range * c.sight_range:
                    continue
                if c.fov_deg < 360 and d2 > 0 and fl > 0:
                    var dx = d
                    dx[1] = 0
                    var dl = sqrt(dot(dx, dx))
                    if dl > 0 and dot(dx, f) / (dl * fl) < cos_half:
                        continue
                self.ray_obs.append(o)
                self.ray_tgt.append(t)
                self.ray_from.append(self.eye(o))
                self.ray_to.append(self.tgt_pos[t] + Vec3(0, c.eye_height, 0, 0))
        return len(self.ray_obs)

    def _remember(mut self, o: Int, t: Int, pos: Vec3, tick: Int, sense: Int):
        for i in range(len(self.memory[o])):
            if self.memory[o][i].target == t:
                var m = self.memory[o][i]
                # sight overrides an equal-tick hearing record, never the reverse
                if tick > m.tick or (tick == m.tick and sense <= m.sense):
                    self.memory[o][i] = Memory(t, pos, tick, sense)
                return
        self.memory[o].append(Memory(t, pos, tick, sense))

    def commit_sight(mut self, visible: List[Bool], tick: Int) raises:
        """`visible[i]` answers ray i of the last `sight_candidates`."""
        if len(visible) != len(self.ray_obs):
            raise Error("Perception.commit_sight: one answer per candidate ray")
        for i in range(len(visible)):
            if visible[i]:
                var t = self.ray_tgt[i]
                self._remember(self.ray_obs[i], t, self.tgt_pos[t], tick, SENSE_SIGHT)

    def hear(mut self, pos: Vec3, radius: Real, team: Int, source: Int, tick: Int) -> Int:
        """A sound of `radius` at pos made by target `source` (team `team`);
        returns how many observers heard it."""
        var n = 0
        for o in range(len(self.obs_pos)):
            if self.obs_team[o] == team:
                continue
            var r = radius * self.cfg[o].hearing_scale
            var d = pos - self.obs_pos[o]
            if dot(d, d) <= r * r:
                self._remember(o, source, pos, tick, SENSE_HEARING)
                n += 1
        return n

    def forget(mut self, tick: Int):
        for o in range(len(self.memory)):
            var keep = List[Memory]()
            for m in self.memory[o]:
                if tick - m.tick <= self.cfg[o].memory_ticks:
                    keep.append(m)
            self.memory[o] = keep^

    def best_target(self, o: Int) -> Int:
        """Index into memory[o] of the freshest record, -1 if none."""
        var best = -1
        for i in range(len(self.memory[o])):
            if best < 0:
                best = i
                continue
            var m = self.memory[o][i]
            var b = self.memory[o][best]
            if m.tick > b.tick or (m.tick == b.tick and (m.sense < b.sense or (m.sense == b.sense and m.target < b.target))):
                best = i
        return best

    def to_blackboard(self, o: Int, tick: Int, mut bb: Blackboard, k_visible: Int, k_pos: Int, k_dist: Int, k_age: Int):
        """Write the freshest memory into a blackboard: visible flag (seen this
        tick), last known position, distance, age in ticks; clears them when
        the observer remembers nothing."""
        var i = self.best_target(o)
        if i < 0:
            bb.set_flag(k_visible, False)
            bb.clear(k_pos)
            bb.clear(k_dist)
            bb.clear(k_age)
            return
        var m = self.memory[o][i]
        bb.set_flag(k_visible, m.tick == tick and m.sense == SENSE_SIGHT)
        bb.set_vec(k_pos, m.pos)
        var d = m.pos - self.obs_pos[o]
        bb.set(k_dist, sqrt(dot(d, d)))
        bb.set(k_age, Real(tick - m.tick))
