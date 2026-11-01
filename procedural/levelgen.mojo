"""Level structure generators (ROADMAP 17.69): maze, BSP rooms and
corridors, L-system, Wave Function Collapse.

Every random choice is the hash of (seed, a counter) (`noise._hash`, as
`scatter`), so a given (seed, parameters) gives the same output bit for
bit, with no RNG state to carry. Outputs are flat grids (`Grid`: 0 = wall,
1 = floor, row-major w x h) or segment lists, ready for a nav bake (17.14)
or a collision mesh built by the caller.

  * `maze(w, h, seed)`: a perfect maze (spanning tree, iterative
    randomized depth-first search) on the odd cells of a (2w+1) x (2h+1)
    grid: every floor cell reaches every other by exactly one path.
  * `bsp_rooms(w, h, min_leaf, seed)`: split the area recursively (longer
    side, cut position hashed within the middle half) down to leaves of
    at least `min_leaf`, carve one room per leaf, join sibling subtrees
    with L-shaped corridors: all rooms connected.
  * `lsystem(axiom, rules, iterations)` rewrites a string; `turtle(s,
    step, angle)` draws it ('F' forward with a segment, 'f' forward
    without, '+' / '-' turn, '[' / ']' push / pop).
  * `wfc(w, h, adj, n_tiles, seed, max_restarts)`: tile model -- `adj` is
    an n x n x 4 table (tile a may sit right / up / left / down of tile b);
    repeatedly collapse the lowest-entropy cell (ties by hash) to a hashed
    allowed tile and propagate the constraints; a contradiction restarts
    with the next seed (up to `max_restarts`; then raises).
"""

from geometry.vec import Real, Vec2
from .noise import _hash


def _h(seed: Int, a: Int, b: Int) -> Int:
    return Int(_hash(a, b, 0x1E5E1, seed))


struct Grid(Copyable, Movable):
    var w: Int
    var h: Int
    var c: List[Int]

    def __init__(out self, w: Int, h: Int, fill: Int = 0):
        self.w = w
        self.h = h
        self.c = List[Int](length=w * h, fill=fill)

    def at(self, x: Int, y: Int) -> Int:
        return self.c[y * self.w + x]

    def set(mut self, x: Int, y: Int, v: Int):
        self.c[y * self.w + x] = v

    def count(self, v: Int) -> Int:
        var n = 0
        for x in self.c:
            if x == v:
                n += 1
        return n

    def reachable(self, sx: Int, sy: Int) -> Int:
        """Floor cells (value != 0) reachable from (sx, sy), 4-connected."""
        if self.at(sx, sy) == 0:
            return 0
        var seen = List[Bool](length=self.w * self.h, fill=False)
        var stack: List[Int] = [sy * self.w + sx]
        seen[sy * self.w + sx] = True
        var n = 0
        while len(stack) > 0:
            var k = stack.pop()
            n += 1
            var x = k % self.w
            var y = k // self.w
            for d in range(4):
                var nx = x + (1 if d == 0 else (-1 if d == 2 else 0))
                var ny = y + (1 if d == 1 else (-1 if d == 3 else 0))
                if nx < 0 or ny < 0 or nx >= self.w or ny >= self.h:
                    continue
                var nk = ny * self.w + nx
                if not seen[nk] and self.c[nk] != 0:
                    seen[nk] = True
                    stack.append(nk)
        return n


def maze(w: Int, h: Int, seed: Int) raises -> Grid:
    if w < 1 or h < 1:
        raise Error("maze: w, h >= 1")
    var g = Grid(2 * w + 1, 2 * h + 1)
    var seen = List[Bool](length=w * h, fill=False)
    var stack: List[Int] = [0]
    seen[0] = True
    g.set(1, 1, 1)
    var step = 0
    while len(stack) > 0:
        var k = stack[len(stack) - 1]
        var x = k % w
        var y = k // w
        var opts = List[Int]()
        for d in range(4):
            var nx = x + (1 if d == 0 else (-1 if d == 2 else 0))
            var ny = y + (1 if d == 1 else (-1 if d == 3 else 0))
            if nx >= 0 and ny >= 0 and nx < w and ny < h and not seen[ny * w + nx]:
                opts.append(d)
        if len(opts) == 0:
            _ = stack.pop()
            continue
        var d = opts[_h(seed, step, 7) % len(opts)]
        step += 1
        var nx = x + (1 if d == 0 else (-1 if d == 2 else 0))
        var ny = y + (1 if d == 1 else (-1 if d == 3 else 0))
        seen[ny * w + nx] = True
        g.set(2 * x + 1 + (nx - x), 2 * y + 1 + (ny - y), 1)
        g.set(2 * nx + 1, 2 * ny + 1, 1)
        stack.append(ny * w + nx)
    return g^


@fieldwise_init
struct Room(Copyable, ImplicitlyCopyable, Movable):
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    def cx(self) -> Int:
        return self.x + self.w // 2

    def cy(self) -> Int:
        return self.y + self.h // 2


def _carve_line(mut g: Grid, x0: Int, y0: Int, x1: Int, y1: Int):
    """L-shaped corridor: horizontal at y0, then vertical at x1."""
    var a = min(x0, x1)
    var b = max(x0, x1)
    for x in range(a, b + 1):
        g.set(x, y0, 1)
    a = min(y0, y1)
    b = max(y0, y1)
    for y in range(a, b + 1):
        g.set(x1, y, 1)


def _bsp(mut g: Grid, mut rooms: List[Room], x: Int, y: Int, w: Int, h: Int, min_leaf: Int, seed: Int, mut counter: Int) -> Room:
    """Split, carve, connect; returns one room of this subtree (to link)."""
    var can_v = w >= 2 * min_leaf
    var can_h = h >= 2 * min_leaf
    if not can_v and not can_h:
        # leaf: a room inside with a 1-cell margin, size hashed
        counter += 1
        var rw = max(2, w - 2 - _h(seed, counter, 1) % max(1, w // 3))
        var rh = max(2, h - 2 - _h(seed, counter, 2) % max(1, h // 3))
        rw = min(rw, w - 2)
        rh = min(rh, h - 2)
        var rx = x + 1 + _h(seed, counter, 3) % max(1, w - 2 - rw + 1)
        var ry = y + 1 + _h(seed, counter, 4) % max(1, h - 2 - rh + 1)
        for yy in range(ry, ry + rh):
            for xx in range(rx, rx + rw):
                g.set(xx, yy, 1)
        var r = Room(rx, ry, rw, rh)
        rooms.append(r)
        return r
    counter += 1
    var vertical = can_v and (not can_h or w >= h)
    var a: Room
    var b: Room
    if vertical:
        var lo = max(min_leaf, w // 4)
        var hi = min(w - min_leaf, w - w // 4)
        var cut = lo + _h(seed, counter, 5) % max(1, hi - lo + 1)
        a = _bsp(g, rooms, x, y, cut, h, min_leaf, seed, counter)
        b = _bsp(g, rooms, x + cut, y, w - cut, h, min_leaf, seed, counter)
    else:
        var lo = max(min_leaf, h // 4)
        var hi = min(h - min_leaf, h - h // 4)
        var cut = lo + _h(seed, counter, 6) % max(1, hi - lo + 1)
        a = _bsp(g, rooms, x, y, w, cut, min_leaf, seed, counter)
        b = _bsp(g, rooms, x, y + cut, w, h - cut, min_leaf, seed, counter)
    _carve_line(g, a.cx(), a.cy(), b.cx(), b.cy())
    return a


def bsp_rooms(w: Int, h: Int, min_leaf: Int, seed: Int) raises -> Tuple[Grid, List[Room]]:
    if min_leaf < 5 or w < min_leaf or h < min_leaf:
        raise Error("bsp_rooms: min_leaf >= 5 and the area at least one leaf")
    var g = Grid(w, h)
    var rooms = List[Room]()
    var counter = 0
    _ = _bsp(g, rooms, 0, 0, w, h, min_leaf, seed, counter)
    return (g^, rooms^)


def lsystem(axiom: String, rules: Dict[String, String], iterations: Int) raises -> String:
    var s = axiom
    for _ in range(iterations):
        var out = String()
        for ch in s.codepoint_slices():
            var c = String(ch)
            if c in rules:
                out += rules[c]
            else:
                out += c
        s = out^
    return s


def turtle(s: String, step: Real, angle: Real) -> List[Vec2]:
    """Segments as point pairs (a0, b0, a1, b1, ...)."""
    from geometry.trig import sin, cos
    var x = Real(0)
    var y = Real(0)
    var heading = Real(1.5707963267948966)  # +y
    var stack = List[Real]()
    var segs = List[Vec2]()
    for ch in s.codepoint_slices():
        var c = String(ch)
        if c == "F" or c == "f":
            var nx = x + step * cos(heading)
            var ny = y + step * sin(heading)
            if c == "F":
                segs.append(Vec2(x, y))
                segs.append(Vec2(nx, ny))
            x = nx
            y = ny
        elif c == "+":
            heading += angle
        elif c == "-":
            heading -= angle
        elif c == "[":
            stack.append(x)
            stack.append(y)
            stack.append(heading)
        elif c == "]" and len(stack) >= 3:
            heading = stack.pop()
            y = stack.pop()
            x = stack.pop()
    return segs^


def wfc(w: Int, h: Int, adj: List[Bool], n: Int, seed: Int, max_restarts: Int = 20) raises -> Grid:
    """`adj[(a * n + b) * 4 + d]`: tile a may sit in direction d of tile b
    (d: 0 right, 1 up, 2 left, 3 down). Returns tile ids (module note)."""
    if n < 1 or len(adj) != n * n * 4 or w < 1 or h < 1:
        raise Error("wfc: adj must hold n * n * 4 entries")
    for attempt in range(max_restarts + 1):
        var s = seed + attempt * 7919
        var poss = List[Bool](length=w * h * n, fill=True)
        var ok = True
        var step = 0
        while ok:
            # lowest-entropy undecided cell
            var best = -1
            var best_n = n + 1
            var best_tie = 0
            for k in range(w * h):
                var cnt = 0
                for t in range(n):
                    if poss[k * n + t]:
                        cnt += 1
                if cnt == 0:
                    ok = False
                    break
                if cnt > 1:
                    var tie = _h(s, k, step + 99)
                    if cnt < best_n or (cnt == best_n and tie < best_tie):
                        best = k
                        best_n = cnt
                        best_tie = tie
            if not ok or best < 0:
                break
            # collapse
            var allowed = List[Int]()
            for t in range(n):
                if poss[best * n + t]:
                    allowed.append(t)
            var pick = allowed[_h(s, best, step) % len(allowed)]
            step += 1
            for t in range(n):
                poss[best * n + t] = t == pick
            # propagate
            var queue: List[Int] = [best]
            while len(queue) > 0 and ok:
                var k = queue.pop()
                var x = k % w
                var y = k // w
                for d in range(4):
                    var nx = x + (1 if d == 0 else (-1 if d == 2 else 0))
                    var ny = y + (1 if d == 1 else (-1 if d == 3 else 0))
                    if nx < 0 or ny < 0 or nx >= w or ny >= h:
                        continue
                    var nk = ny * w + nx
                    var changed = False
                    var left = 0
                    for a in range(n):
                        if not poss[nk * n + a]:
                            continue
                        var sup = False
                        for b in range(n):
                            if poss[k * n + b] and adj[(a * n + b) * 4 + d]:
                                sup = True
                                break
                        if not sup:
                            poss[nk * n + a] = False
                            changed = True
                        else:
                            left += 1
                    if left == 0:
                        ok = False
                        break
                    if changed:
                        queue.append(nk)
        if ok:
            var g = Grid(w, h)
            for k in range(w * h):
                for t in range(n):
                    if poss[k * n + t]:
                        g.c[k] = t
            return g^
    raise Error("wfc: no solution within max_restarts")
