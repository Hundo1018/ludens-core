"""Light-cone partition of gameplay: projectiles, damage and death across regions
(ROADMAP 17.85 follow-up; design note docs/design/17.85-lightcone-gameplay.md).

A small 2-D model of the gameplay layer, written to check the design note's claims
with numbers. It is not the engine: no rigid bodies, no Mojo. It reuses the rule
that `gameplay/rules.mojo` `Rules.damage` implements (resistance, then shield,
then health; a dead actor takes nothing; a death is recorded once).

Four ways to step the same world:

  lockstep   reference: every tick, every entity; the hits of a tick are applied
             sorted by (target, projectile key).
  shooter    shooter-authoritative regions (one fixed spatial cell per worker):
             each region steps its own actors and projectiles for k ticks against a
             copy of the other regions frozen at the last sync, applies hits to its
             own copy of the target and reports the kills it saw. Merged every k ticks.
  owner      owner-authoritative regions: same cells, but a hit on another region's
             actor becomes a message that the owner applies at the next sync, in
             arrival order (region index, then tick).
  cone       light-cone regions: at each sync the entities are joined (union-find)
             whenever one can send a signal to the other within the next k ticks at
             the signal's maximum speed. Each component steps alone, on its own copy
             of the world with only its entities. After the window, the actual
             trajectories are checked for any cross-component interaction; on a miss
             the window is recomputed in lockstep (counted).

    pixi run lightcone-sim                 # all tables (about 2 minutes)
    pixi run lightcone-sim -- --scenario   # the three-shooter timeline only
    pixi run lightcone-sim -- --seeds 3    # fewer seeds for a quick run
    pixi run lightcone-sim -- --selftest   # rule order, timeline and cone == lockstep checks
"""

import argparse
import copy
import hashlib
import math
import struct
import sys
from dataclasses import dataclass, field, replace

DT = 1.0 / 60.0
FX = 1000  # resistance is per mille, as in `gameplay/rules.mojo`


@dataclass(frozen=True)
class Params:
    seed: int = 1
    clusters_x: int = 4
    clusters_y: int = 2
    per_cluster: int = 6
    spacing: float = 40.0  # metres between cluster centres
    cluster_radius: float = 8.0  # actors turn home beyond this
    v_max: float = 4.0  # actor walking speed bound, m/s
    c_proj: float = 30.0  # projectile speed, m/s
    r_body: float = 0.5
    r_fire: float = 25.0  # target selection range
    fire_period: int = 30
    proj_life: int = 60
    dmg: int = 35
    hp: int = 100
    shield: int = 20
    ticks: int = 600
    knockback: float = 0.0  # m/s added to the target per hit (breaks the v_max bound)
    lifesteal: int = 0  # health the killer gains on a kill
    lifesteal_delay: int = 0  # ticks from the kill until the heal lands (0 = same tick)


@dataclass
class Actor:
    id: int
    team: int
    hx: float
    hy: float
    x: float
    y: float
    hp: int
    shield: int
    resist: tuple
    kx: float = 0.0
    ky: float = 0.0
    dead: bool = False
    death_tick: int = -1
    killer: int = -1
    shots: int = 0
    fire_at: tuple = ()  # scripted shots: ((tick, target), ...); empty = periodic
    still: bool = False


@dataclass
class Proj:
    key: tuple  # (shooter id, shot number): the same name in every scheme
    team: int
    x: float
    y: float
    vx: float
    vy: float
    dtype: int
    dmg: int
    born: int


@dataclass
class World:
    p: Params
    tick: int = 0
    actors: dict = field(default_factory=dict)
    projs: dict = field(default_factory=dict)
    pending: list = field(default_factory=list)  # (deliver tick, target, proj key, heal)
    events: list = field(default_factory=list)  # (tick, target, proj key, lost, killed)
    fires: list = field(default_factory=list)  # (tick, shooter, target)
    credits: list = field(default_factory=list)  # (victim, killer, tick) as each scheme reports them
    trace: list = field(default_factory=list)  # per tick footprints for the cone check


def rng(seed: int, *ints: int) -> float:
    """Counter-based draw in [0, 1): a function of its arguments, so the value does
    not depend on which worker draws it or in which order (design note §6)."""
    h = hashlib.blake2b(struct.pack(f"<{len(ints) + 1}q", seed, *ints), digest_size=8).digest()
    return int.from_bytes(h, "little") / 2.0**64


def damage(a: Actor, amount: int, dtype: int) -> tuple[int, bool]:
    """`Rules.damage`: resistance, then shield, then health. Returns (lost, killed)."""
    if a.dead or amount <= 0:
        return 0, False
    r = min(a.resist[dtype], FX)
    d = amount * (FX - r) // FX
    absorbed = min(d, a.shield)
    a.shield -= absorbed
    d -= absorbed
    lost = min(d, max(a.hp, 0))
    a.hp -= lost
    if a.hp <= 0:
        a.dead = True
        return lost, True
    return lost, False


def heal(a: Actor, amount: int, hp_max: int):
    if not a.dead:
        a.hp = min(a.hp + amount, hp_max)


def make_world(p: Params) -> World:
    w = World(p)
    i = 0
    for cy in range(p.clusters_y):
        for cx in range(p.clusters_x):
            hx, hy = cx * p.spacing, cy * p.spacing
            for _ in range(p.per_cluster):
                ang = 2 * math.pi * rng(p.seed, 1, i)
                rad = p.cluster_radius * rng(p.seed, 2, i)
                res = (int(500 * rng(p.seed, 3, i)), int(500 * rng(p.seed, 4, i)))
                w.actors[i] = Actor(i, i % 2, hx, hy, hx + rad * math.cos(ang), hy + rad * math.sin(ang), p.hp, p.shield, res)
                i += 1
    return w


def cell_centres(p: Params) -> list:
    return [(cx * p.spacing, cy * p.spacing) for cy in range(p.clusters_y) for cx in range(p.clusters_x)]


def seg_hit(px, py, vx, vy, cx, cy, r):
    """Smallest s in [0, 1] where the segment p + s v is within r of c, or None."""
    dx, dy = px - cx, py - cy
    a = vx * vx + vy * vy
    s = 0.0 if a == 0 else max(0.0, min(1.0, -(dx * vx + dy * vy) / a))
    ex, ey = dx + s * vx, dy + s * vy
    return s if ex * ex + ey * ey <= r * r else None


def step(w: World, owned=None, remote="apply", msgs=None):
    """One tick. `owned`: actor ids this worker moves and fires for (None = all);
    projectiles in `w.projs` are all this worker's. `remote`: what a hit on a
    non-owned actor does: "apply" to the local copy, or "message" (appended to
    `msgs`, no local change). Order: heals due, move, fire, fly and hit, damage."""
    p, t = w.p, w.tick
    mine = (lambda i: True) if owned is None else (lambda i: i in owned)
    due = sorted(m for m in w.pending if m[0] == t)
    w.pending = [m for m in w.pending if m[0] != t]
    for _, tgt, _, amt in due:
        if tgt not in w.actors:
            w.trace.append(("missing", t, tgt))
            continue
        heal(w.actors[tgt], amt, p.hp)
    for a in w.actors.values():
        if a.dead or a.still or not mine(a.id):
            continue
        dx, dy = a.hx - a.x, a.hy - a.y
        dist = math.hypot(dx, dy)
        if dist > p.cluster_radius:
            ux, uy = dx / dist, dy / dist
        else:
            ang = 2 * math.pi * rng(p.seed, 5, a.id, t // 20)
            ux, uy = math.cos(ang), math.sin(ang)
        a.x += (p.v_max * ux + a.kx) * DT
        a.y += (p.v_max * uy + a.ky) * DT
        a.kx *= 0.9
        a.ky *= 0.9
    alive = sorted((a for a in w.actors.values() if not a.dead), key=lambda a: a.id)
    fired = []
    for a in alive:
        if not mine(a.id):
            continue
        tgt = None
        if a.fire_at:
            for ft, fid in a.fire_at:
                if ft == t:
                    fired.append((a.x, a.y, a.team))  # reads the target: a signal within r_fire
                    if fid in w.actors and not w.actors[fid].dead:
                        tgt = w.actors[fid]
        elif (t + a.id) % p.fire_period == 0:
            best = None
            for b in alive:
                if b.team == a.team:
                    continue
                d2 = (b.x - a.x) ** 2 + (b.y - a.y) ** 2
                if d2 <= p.r_fire**2 and (best is None or d2 < best[0]):
                    best = (d2, b)
            tgt = best[1] if best else None
            fired.append((a.x, a.y, a.team))
        if tgt is None:
            continue
        dx, dy = tgt.x - a.x, tgt.y - a.y
        n = math.hypot(dx, dy) or 1.0
        key = (a.id, a.shots)
        a.shots += 1
        w.projs[key] = Proj(key, a.team, a.x, a.y, p.c_proj * dx / n, p.c_proj * dy / n, a.id % 2, p.dmg, t)
        w.fires.append((t, a.id, tgt.id))
    hits, segs, hit_dir = [], [], {}
    for key in sorted(w.projs):
        q = w.projs[key]
        mx, my = q.vx * DT, q.vy * DT
        segs.append((q.x, q.y, mx, my, q.team))
        best = None
        for b in alive:
            if b.team == q.team:
                continue
            s = seg_hit(q.x, q.y, mx, my, b.x, b.y, p.r_body)
            if s is not None and (best is None or (s, b.id) < best):
                best = (s, b.id)
        q.x += mx
        q.y += my
        if best is not None:
            hits.append((best[1], key))
            hit_dir[key] = (q.vx / p.c_proj, q.vy / p.c_proj)
            del w.projs[key]
        elif t - q.born >= p.proj_life:
            del w.projs[key]
    for tgt, key in sorted(hits):
        q_dmg, q_dtype = p.dmg, key[0] % 2
        if not mine(tgt) and remote == "message":
            msgs.append((t, tgt, key, q_dmg, q_dtype))
            continue
        b = w.actors[tgt]
        lost, killed = damage(b, q_dmg, q_dtype)
        if p.knockback > 0 and lost > 0:  # along the projectile's flight, not toward its shooter
            b.kx += p.knockback * hit_dir[key][0]
            b.ky += p.knockback * hit_dir[key][1]
        w.events.append((t, tgt, key, lost, killed))
        if killed:
            b.death_tick, b.killer = t, key[0]
            w.credits.append((tgt, key[0], t))
            if p.lifesteal > 0:
                if p.lifesteal_delay == 0:
                    if key[0] in w.actors:
                        heal(w.actors[key[0]], p.lifesteal, p.hp)
                    else:
                        w.trace.append(("missing", t, key[0]))
                else:
                    w.pending.append((t + p.lifesteal_delay, key[0], key, p.lifesteal))
    w.trace.append(("tick", t, [(a.id, a.team, a.x, a.y) for a in alive], fired, segs))
    w.tick += 1


def clone(w: World, ids=None, keys=None, logs: bool = True) -> World:
    """Copy of the state (actors / projectiles are flat records, so a shallow copy
    of each is a full copy). `ids` / `keys` keep a subset; `logs` keeps the
    event / fire / credit history."""
    c = World(w.p, w.tick)
    c.actors = {i: copy.copy(a) for i, a in w.actors.items() if ids is None or i in ids}
    c.projs = {k: copy.copy(q) for k, q in w.projs.items() if keys is None or k in keys}
    c.pending = [m for m in w.pending if ids is None or m[1] in ids]
    if logs:
        c.events, c.fires, c.credits = list(w.events), list(w.fires), list(w.credits)
    return c


def state_hash(w: World) -> str:
    rows = [(a.id, a.x, a.y, a.kx, a.ky, a.hp, a.shield, a.dead, a.death_tick, a.killer, a.shots) for a in sorted(w.actors.values(), key=lambda a: a.id)]
    rows += [(q.key, q.x, q.y, q.vx, q.vy, q.born) for q in sorted(w.projs.values(), key=lambda q: q.key)]
    rows += sorted(w.pending)
    return hashlib.sha256(repr(rows).encode()).hexdigest()[:16]


# ---------------------------------------------------------------- lockstep


def run_lockstep(w: World, k: int) -> tuple[World, list]:
    hashes = []
    while w.tick < w.p.ticks:
        step(w)
        if w.tick % k == 0 or w.tick == w.p.ticks:
            hashes.append(state_hash(w))
    return w, hashes


# ---------------------------------------------------------------- fixed spatial cells


def run_cells(w: World, k: int, mode: str, centres=None) -> World:
    """Shooter- or owner-authoritative regions on fixed cells (nearest centre)."""
    p = w.p
    centres = centres or cell_centres(p)
    proj_region = {}
    while w.tick < p.ticks:
        kw = min(k, p.ticks - w.tick)
        region = {}
        for a in w.actors.values():
            region[a.id] = min(range(len(centres)), key=lambda c: ((a.x - centres[c][0]) ** 2 + (a.y - centres[c][1]) ** 2, c))
        for key in w.projs:
            proj_region.setdefault(key, region[key[0]])
        snap = clone(w)
        subs = []
        for r in range(len(centres)):
            owned = {i for i, rr in region.items() if rr == r}
            s = clone(snap, keys={key for key in snap.projs if proj_region[key] == r}, logs=False)
            msgs = []
            for _ in range(kw):
                step(s, owned, "apply" if mode == "shooter" else "message", msgs)
                for key in s.projs:
                    proj_region.setdefault(key, r)
            subs.append((owned, s, msgs))
        merged = clone(snap)
        merged.projs = {}
        for owned, s, _ in subs:
            for i in owned:
                merged.actors[i] = copy.copy(s.actors[i])
            merged.projs.update(s.projs)
            merged.events += s.events
            merged.fires += s.fires
        if mode == "shooter":
            for owned, s, _ in subs:
                for i, a in s.actors.items():
                    if i in owned:
                        continue
                    base, m = snap.actors[i], merged.actors[i]
                    m.hp -= base.hp - a.hp
                    m.shield -= base.shield - a.shield
                    if m.hp <= 0 and not m.dead:
                        m.dead, m.death_tick, m.killer = True, a.death_tick if a.dead else snap.tick + kw, a.killer
                for c in s.credits:
                    merged.credits.append(c)
        else:
            for _, s, msgs in subs:
                merged.credits += s.credits
                for _t, tgt, key, amt, dt in msgs:
                    m = merged.actors[tgt]
                    lost, killed = damage(m, amt, dt)
                    merged.events.append((snap.tick + kw, tgt, key, lost, killed))
                    if killed:
                        m.death_tick, m.killer = snap.tick + kw, key[0]
                        merged.credits.append((tgt, key[0], snap.tick + kw))
        merged.tick = snap.tick + kw
        w = merged
    return w


# ---------------------------------------------------------------- light cone


class _UF:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, i):
        while self.p[i] != i:
            self.p[i] = self.p[self.p[i]]
            i = self.p[i]
        return i

    def join(self, a, b):
        a, b = self.find(a), self.find(b)
        if a != b:
            self.p[max(a, b)] = min(a, b)


def components(w: World, kw: int, v_bound: float) -> list:
    """Entities that can exchange a signal within kw ticks, joined. Signal speeds:
    actors walk at v_bound; a projectile flies at c_proj; target selection reads
    every enemy within r_fire; a same-tick or short-delay heal ties a projectile
    to its shooter. Same-team actors and projectile pairs do not interact."""
    p = w.p
    T = kw * DT
    ents = [("a", a.id) for a in sorted(w.actors.values(), key=lambda a: a.id)] + [("p", key) for key in sorted(w.projs)]
    idx = {e: i for i, e in enumerate(ents)}
    uf = _UF(len(ents))
    alive = [a for a in sorted(w.actors.values(), key=lambda a: a.id) if not a.dead]
    reach_aa = 2 * v_bound * T + max(p.r_fire, p.c_proj * T + p.r_body)
    for i, a in enumerate(alive):
        for b in alive[i + 1 :]:
            if a.team != b.team and math.hypot(a.x - b.x, a.y - b.y) <= reach_aa:
                uf.join(idx[("a", a.id)], idx[("a", b.id)])
    reach_pa = p.c_proj * T + v_bound * T + p.r_body
    couple_heal = p.lifesteal > 0 and p.lifesteal_delay < kw
    for key, q in w.projs.items():
        for b in alive:
            if b.team != q.team and math.hypot(q.x - b.x, q.y - b.y) <= reach_pa:
                uf.join(idx[("p", key)], idx[("a", b.id)])
        if couple_heal:
            uf.join(idx[("p", key)], idx[("a", key[0])])
    groups = {}
    for e, i in idx.items():
        groups.setdefault(uf.find(i), []).append(e)
    return [groups[g] for g in sorted(groups)]


def cross_interactions(traces: list, p: Params) -> int:
    """Count actual cross-component interactions in a window: a remote enemy inside
    a firing shooter's r_fire, a projectile segment within r_body of a remote enemy,
    or a heal addressed to an actor the component does not hold."""
    n = 0
    by_tick = {}
    for c, tr in enumerate(traces):
        for row in tr:
            if row[0] == "missing":
                n += 1
                continue
            by_tick.setdefault(row[1], []).append((c, row))
    for rows in by_tick.values():
        for ci, ri in rows:
            for cj, rj in rows:
                if ci == cj:
                    continue
                for fx, fy, team in ri[3]:
                    for _, bt, bx, by in rj[2]:
                        if bt != team and (bx - fx) ** 2 + (by - fy) ** 2 <= p.r_fire**2:
                            n += 1
                for sx, sy, mx, my, team in ri[4]:
                    for _, bt, bx, by in rj[2]:
                        if bt != team and seg_hit(sx, sy, mx, my, bx, by, p.r_body) is not None:
                            n += 1
    return n


@dataclass
class ConeStats:
    windows: int = 0
    misses: int = 0
    comps: int = 0  # sum over windows of the number of components with work
    work: float = 0.0  # entity-ticks
    critical: float = 0.0  # sum over windows of the largest component's entity-ticks
    largest_frac: float = 0.0  # sum of (largest component / all entities)


def run_cone(w: World, k: int, v_bound: float, validate: bool = True) -> tuple[World, list, ConeStats]:
    p = w.p
    st = ConeStats()
    hashes = []
    while w.tick < p.ticks:
        kw = min(k, p.ticks - w.tick)
        comps = components(w, kw, v_bound)
        snap = clone(w)
        subs = []
        for comp in comps:
            ids = {e[1] for e in comp if e[0] == "a"}
            keys = {e[1] for e in comp if e[0] == "p"}
            s = clone(snap, ids, keys, logs=False)
            work = 0
            for _ in range(kw):
                work += sum(1 for a in s.actors.values() if not a.dead) + len(s.projs)
                step(s)
            subs.append((s, work))
        miss = cross_interactions([s.trace for s, _ in subs], p) if validate else 0
        st.windows += 1
        works = [wk for _, wk in subs if wk > 0]
        if miss:
            st.misses += 1
            w = snap
            for _ in range(kw):
                step(w)
            w.trace = []
            st.work += sum(works)
            st.critical += sum(works)
            st.comps += 1
            st.largest_frac += 1.0
        else:
            merged = clone(snap)
            merged.actors, merged.projs, merged.pending = {}, {}, []
            for s, _ in subs:
                merged.actors.update(s.actors)
                merged.projs.update(s.projs)
                merged.pending += s.pending
                merged.events += s.events
                merged.fires += s.fires
                merged.credits += s.credits
            merged.events.sort()
            merged.fires.sort()
            merged.credits.sort(key=lambda c: (c[2], c[0]))
            merged.tick = snap.tick + kw
            merged.trace = []
            w = merged
            st.work += sum(works)
            st.critical += max(works, default=0)
            st.comps += len(works)
            st.largest_frac += max(works, default=0) / max(sum(works), 1)
        hashes.append(state_hash(w))
    return w, hashes, st


# ---------------------------------------------------------------- comparison


def anomalies(ref: World, got: World) -> dict:
    ref_kill = {v: k for v, k, _ in ref.credits}
    got_kill = {}
    for v, k, _ in got.credits:
        got_kill.setdefault(v, []).append(k)
    double = sum(1 for ks in got_kill.values() if len(ks) > 1)
    wrong = sum(1 for v, ks in got_kill.items() if v in ref_kill and ref_kill[v] not in ks)
    extra = sum(1 for v in got_kill if v not in ref_kill)
    missing = sum(1 for v in ref_kill if v not in got_kill)
    dt = [abs(got.actors[v].death_tick - ref.actors[v].death_tick) for v in ref_kill if got.actors[v].dead]
    post_hits = sum(1 for t, tgt, _, _, _ in got.events if ref.actors[tgt].dead and t > ref.actors[tgt].death_tick)
    post_fire = sum(1 for t, _, tgt in got.fires if ref.actors[tgt].dead and t > ref.actors[tgt].death_tick)
    hp_diff = sum(1 for i in ref.actors if ref.actors[i].hp != got.actors[i].hp)
    return {
        "double": double,
        "wrong": wrong,
        "extra": extra,
        "missing": missing,
        "dtick": (sum(dt) / len(dt)) if dt else 0.0,
        "post_hits": post_hits,
        "post_fire": post_fire,
        "hp_diff": hp_diff,
        "kills": len(ref_kill),
        "equal": state_hash(ref) == state_hash(got) and sorted(ref.events) == sorted(got.events),
    }


def scenario(dmg: int) -> tuple[Params, World]:
    """Three shooters in three regions, one target in a fourth (design note §1).
    Nobody moves; every shot is scripted. The shots reach T at ticks 38, 44, 46."""
    p = Params(ticks=120, clusters_x=1, clusters_y=1, per_cluster=0, dmg=dmg, hp=100, shield=0, r_fire=40.0)
    w = World(p)
    w.actors[0] = Actor(0, 1, 0, 0, 0.0, 0.0, 100, 0, (0, 0), still=True)
    w.actors[1] = Actor(1, 0, -20, 0, -20.0, 0.0, 100, 0, (0, 0), still=True, fire_at=((0, 0),))
    w.actors[2] = Actor(2, 0, 22, 0, 22.0, 0.0, 100, 0, (0, 0), still=True, fire_at=((2, 0),))
    w.actors[3] = Actor(3, 0, 0, 21, 0.0, 21.0, 100, 0, (0, 0), still=True, fire_at=((5, 0),))
    return p, w


def run_scenario(k: int, dmg: int, out=print) -> dict:
    p, w0 = scenario(dmg)
    cells = [(a.x, a.y) for a in sorted(w0.actors.values(), key=lambda a: a.id)]  # one cell per actor
    ref, _ = run_lockstep(clone(w0), k)
    res = {"lockstep": ref}
    for mode in ("shooter", "owner"):
        res[mode] = run_cells(clone(w0), k, mode, cells)
    res["cone"], _, res["cone_stats"] = run_cone(clone(w0), k, 0.0)
    out(f"\n### Timeline: T (hp 100) at the origin; A at 20 m fires at tick 0, B at 22 m at tick 2, C at 21 m at tick 5; {dmg} damage per hit, 0.5 m/tick; sync every {k} ticks\n")
    out("| scheme | hits on T: (tick applied, shooter, health lost) | T dies at tick | kill credited to |")
    out("|---|---|---|---|")
    names = {1: "A", 2: "B", 3: "C"}
    for name in ("lockstep", "shooter", "owner", "cone"):
        r = res[name]
        hits = ", ".join(f"({t}, {names[key[0]]}, {lost})" for t, tgt, key, lost, _ in sorted(r.events) if tgt == 0)
        cred = ", ".join(names[kk] for v, kk, _ in r.credits if v == 0) or "none"
        out(f"| {name} | {hits} | {r.actors[0].death_tick} | {cred} |")
    return res


def ensemble(seeds: int, ks: list, out=print, base: Params | None = None):
    base = base or Params()
    out(f"\n### Ensemble: {base.clusters_x * base.clusters_y} cells x {base.per_cluster} actors, {base.ticks} ticks, {seeds} seeds, cell spacing {base.spacing:g} m\n")
    out("Counts are totals over all seeds; `dtick` is the mean |death tick - reference| over victims that died in both.\n")
    out("| scheme | k | kills (ref) | double credit | wrong killer | extra kill | missing kill | dtick | hits after ref death | shots at ref-dead | hp differs | runs == lockstep |")
    out("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    cone_rows = []
    for k in ks:
        tot = {m: {} for m in ("shooter", "owner", "cone")}
        eq = {m: 0 for m in tot}
        st_sum = ConeStats()
        for s in range(seeds):
            p = replace(base, seed=s + 1)
            ref, _ = run_lockstep(make_world(p), k)
            for m in tot:
                if m == "cone":
                    got, _, st = run_cone(make_world(p), k, p.v_max)
                    for f in ("windows", "misses", "comps", "work", "critical", "largest_frac"):
                        setattr(st_sum, f, getattr(st_sum, f) + getattr(st, f))
                else:
                    got = run_cells(make_world(p), k, m)
                an = anomalies(ref, got)
                eq[m] += an.pop("equal")
                for key, v in an.items():
                    tot[m][key] = tot[m].get(key, 0) + v
        for m in tot:
            t = tot[m]
            out(f"| {m} | {k} | {t['kills']} | {t['double']} | {t['wrong']} | {t['extra']} | {t['missing']} | {t['dtick'] / seeds:.1f} | {t['post_hits']} | {t['post_fire']} | {t['hp_diff']} | {eq[m]}/{seeds} |")
        cone_rows.append((k, st_sum))
    out("\n### Light-cone windows (same runs)\n")
    out("| k | windows | cone misses | mean components with work | largest component share | parallel bound (work / critical path) |")
    out("|---:|---:|---:|---:|---:|---:|")
    for k, st in cone_rows:
        out(f"| {k} | {st.windows} | {st.misses} | {st.comps / st.windows:.1f} | {st.largest_frac / st.windows:.2f} | {st.work / max(st.critical, 1):.2f} |")


def variant_table(seeds: int, k: int, out=print):
    """Rule signals and broken speed bounds: how they change the components and
    whether the result stays equal to lockstep."""
    rows = [
        ("baseline", Params()),
        ("projectile 120 m/s", Params(c_proj=120.0, proj_life=15)),
        ("cell spacing 25 m", Params(spacing=25.0)),
        ("target selection range 10 m", Params(r_fire=10.0)),
        ("lifesteal, same tick", Params(lifesteal=20, lifesteal_delay=0)),
        (f"lifesteal, {k}-tick delay", Params(lifesteal=20, lifesteal_delay=k)),
        ("knockback 30 m/s, no check", Params(knockback=30.0)),
        ("knockback 30 m/s, checked", Params(knockback=30.0)),
    ]
    out(f"\n### Signal speeds and rule delays (k = {k}, {seeds} seeds)\n")
    out("| case | cone misses / windows | mean components | parallel bound | runs == lockstep |")
    out("|---|---:|---:|---:|---:|")
    for name, base in rows:
        validate = not name.endswith("no check")
        st_sum, eq, win = ConeStats(), 0, 0
        for s in range(seeds):
            p = replace(base, seed=s + 1)
            ref, _ = run_lockstep(make_world(p), k)
            got, _, st = run_cone(make_world(p), k, p.v_max, validate)
            eq += anomalies(ref, got)["equal"]
            for f in ("windows", "misses", "comps", "work", "critical"):
                setattr(st_sum, f, getattr(st_sum, f) + getattr(st, f))
            win += st.windows
        out(f"| {name} | {st_sum.misses} / {win} | {st_sum.comps / win:.1f} | {st_sum.work / max(st_sum.critical, 1):.2f} | {eq}/{seeds} |")


def selftest() -> int:
    fails = 0

    def check(cond, label):
        nonlocal fails
        print(("ok   " if cond else "FAIL ") + label)
        fails += 0 if cond else 1

    # order dependence of Rules.damage: shield 30, hp 25; A physical 40, B fire 40 (50 % resist)
    def pair(first, second):
        t = Actor(0, 1, 0, 0, 0, 0, 25, 30, (0, 500))
        out = []
        for name, amt, dt in (first, second):
            lost, killed = damage(t, amt, dt)
            out.append((name, lost, killed))
        return out

    ab = pair(("A", 40, 0), ("B", 40, 1))
    ba = pair(("B", 40, 1), ("A", 40, 0))
    check(ab == [("A", 10, False), ("B", 15, True)], f"A then B: {ab}")
    check(ba == [("B", 0, False), ("A", 25, True)], f"B then A: {ba}")
    res = run_scenario(16, 60, out=lambda *_: None)
    ref = res["lockstep"]
    check(ref.actors[0].death_tick == 44 and ref.actors[0].killer == 2, f"scenario 60: lockstep T dies tick {ref.actors[0].death_tick} by {ref.actors[0].killer}")
    check(state_hash(res["cone"]) == state_hash(ref), "scenario 60: cone == lockstep")
    check(not [c for c in res["shooter"].credits if c[0] == 0] and res["shooter"].actors[0].dead, "scenario 60: shooter-authoritative: T dead, nobody credited")
    check(res["owner"].actors[0].death_tick == 48, "scenario 60: owner-authoritative: death moves to the sync point 48")
    res = run_scenario(16, 100, out=lambda *_: None)
    check(len([c for c in res["shooter"].credits if c[0] == 0]) == 3, "scenario 100: shooter-authoritative: three kill credits")
    check(state_hash(res["cone"]) == state_hash(res["lockstep"]), "scenario 100: cone == lockstep")
    p = replace(Params(), ticks=120)
    ref, rh = run_lockstep(make_world(p), 8)
    got, gh, st = run_cone(make_world(p), 8, p.v_max)
    check(rh == gh, f"ensemble seed 1, 120 ticks: every sync hash equal ({len(rh)} syncs)")
    check(st.misses == 0, "no cone misses with the walking-speed bound held")
    pk = replace(Params(), knockback=30.0)
    ref, rh = run_lockstep(make_world(pk), 8)
    got, gh, st = run_cone(make_world(pk), 8, pk.v_max)
    check(st.misses > 0 and rh == gh, f"knockback 30 m/s: {st.misses} cone misses caught, result equals lockstep")
    got, gh, st = run_cone(make_world(pk), 8, pk.v_max, validate=False)
    check(rh != gh, "knockback 30 m/s without the check: result differs from lockstep")
    print(f"{fails} failed")
    return 1 if fails else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--scenario", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    for dmg in (60, 100):
        for k in (1, 16):
            run_scenario(k, dmg)
    if a.scenario:
        return 0
    for spacing in (40.0, 25.0):
        ensemble(a.seeds, [1, 4, 16], base=Params(spacing=spacing))
    variant_table(a.seeds, 8)
    return 0


if __name__ == "__main__":
    sys.exit(main())
