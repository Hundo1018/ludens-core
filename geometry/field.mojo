"""Coefficient fields for the generic multivector (`geometry.gmv`).

`Field` is the arithmetic a `GMV` coefficient must provide. Mojo conformance is
nominal, so stdlib `SIMD` scalars cannot adopt it retroactively — `RealF` wraps
the engine scalar for that role, and `DualReal` (promoted from
`experiments/exp_autodiff.mojo`) is the forward-mode AD coefficient: compute in
`GMV[..., DualReal]` and every result carries d/dθ in its ε-lane.

`RevReal` + `Tape` are the REVERSE-mode members (ROADMAP 4.2): every operation
touching a seeded value records (operand indices, partial derivatives) on the
tape; one backward sweep (`Tape.grad`) then yields the gradient w.r.t. ALL
seeded inputs at once — the direction count is no longer capped by SIMD lanes
(`DualBatch`'s 4). The Field trait's static constructors (`const`/`zero`) have
no tape to talk to, so constants live OFF the tape (idx = -1, null pointer):
constant⊕constant stays off-tape, and any mixed operation borrows the tape
pointer from its taped operand. Adjoints of constants are discarded — correct,
since nothing differentiates w.r.t. a constant.
"""

from std.math import sqrt, exp
from .trig import cos, sin
from std.memory import alloc, Layout
from .vec import WorldType, Real


trait Field(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    def __add__(self, o: Self) -> Self: ...
    def __sub__(self, o: Self) -> Self: ...
    def __mul__(self, o: Self) -> Self: ...

    @staticmethod
    def zero() -> Self: ...

    @staticmethod
    def const(v: Real) -> Self: ...

    def value(self) -> Real: ...


trait SolverField(Field):
    """The extra arithmetic a rigid contact solver needs on top of `Field`
    (ROADMAP 17.20 / 17.18): a reciprocal, a square root, and `positive`,
    the indicator 1 where the value is > 0 and 0 elsewhere.

    `positive` is how a solver written against this trait avoids branching
    on a coefficient: `max(x, 0)` is `x * x.positive()`, and "use `a` where
    `c` holds, else `b`" is `b + (a - b) * c`. Its derivative is zero by
    definition -- the subgradient convention for a contact switch, stated
    once here rather than at every call site. Written that way the same
    code runs on one world (`RealF`), carries a derivative (`DualReal`,
    `DualBatch`, `RevReal`), or steps one world per SIMD lane
    (`BatchReal[W]`), where different lanes take different branches."""

    def recip(self) -> Self: ...

    def root(self) -> Self: ...

    def positive(self) -> Self: ...

    def smooth_positive(self, k: Real) -> Self:
        """The logistic 1 / (1 + exp(-k x)) in place of `positive`, with its
        true derivative (ROADMAP 17.84): a contact switch that passes a
        gradient through the switching point. k -> inf recovers `positive`
        away from 0; `test_smooth_positive` measures the gradient bias."""
        ...

    def exp(self) -> Self:
        """Exp: e^x with its derivative e^x (ROADMAP 17.57: the Hill muscle
        curves are exponentials)."""
        ...


def _sigmoid(x: Real) -> Real:
    return 1 / (1 + exp(-x))


@fieldwise_init
struct RealF(SolverField):
    """The engine scalar as a `Field` (thin wrapper; nominal conformance)."""

    var v: Real

    def __add__(self, o: Self) -> Self:
        return Self(self.v + o.v)

    def __sub__(self, o: Self) -> Self:
        return Self(self.v - o.v)

    def __mul__(self, o: Self) -> Self:
        return Self(self.v * o.v)

    @staticmethod
    def zero() -> Self:
        return Self(0)

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v)

    def value(self) -> Real:
        return self.v

    def recip(self) -> Self:
        return Self(1 / self.v)

    def root(self) -> Self:
        return Self(sqrt(self.v))

    def positive(self) -> Self:
        return Self(1) if self.v > 0 else Self(0)

    def smooth_positive(self, k: Real) -> Self:
        return Self(_sigmoid(k * self.v))

    def exp(self) -> Self:
        return Self(exp(self.v))


@fieldwise_init
struct DualReal(SolverField):
    """Dual number a + b·ε (ε² = 0) — forward-mode AD scalar."""

    var a: Real  # value
    var b: Real  # derivative w.r.t. the seeded parameter

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v, 0)

    @staticmethod
    def seed(v: Real) -> Self:
        """The differentiation variable: d/dθ θ = 1."""
        return Self(v, 1)

    def __add__(self, o: Self) -> Self:
        return Self(self.a + o.a, self.b + o.b)

    def __sub__(self, o: Self) -> Self:
        return Self(self.a - o.a, self.b - o.b)

    def __mul__(self, o: Self) -> Self:
        return Self(self.a * o.a, self.a * o.b + self.b * o.a)

    @staticmethod
    def zero() -> Self:
        return Self(0, 0)

    def value(self) -> Real:
        return self.a

    def recip(self) -> Self:
        var inv = 1 / self.a
        return Self(inv, -self.b * inv * inv)

    def root(self) -> Self:
        var s = sqrt(self.a)
        return Self(s, self.b * (0.5 / s) if s > 0 else Real(0))

    def positive(self) -> Self:
        return Self(1, 0) if self.a > 0 else Self(0, 0)

    def smooth_positive(self, k: Real) -> Self:
        var s = _sigmoid(k * self.a)
        return Self(s, self.b * (k * s * (1 - s)))

    def exp(self) -> Self:
        var e = exp(self.a)
        return Self(e, self.b * e)


@fieldwise_init
struct DualBatch(SolverField):
    """Forward-mode AD with FOUR derivative directions in SIMD lanes — one
    rollout yields the gradient w.r.t. four parameters at once (the
    "SIMD lane = derivative direction" batch scheme from ROADMAP 3.1)."""

    var a: Real  # value
    var b: SIMD[WorldType, 4]  # derivative lanes

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v, SIMD[WorldType, 4](0))

    @staticmethod
    def seed(v: Real, lane: Int) -> Self:
        """The differentiation variable for direction `lane`."""
        var b = SIMD[WorldType, 4](0)
        b[lane] = 1
        return Self(v, b)

    def __add__(self, o: Self) -> Self:
        return Self(self.a + o.a, self.b + o.b)

    def __sub__(self, o: Self) -> Self:
        return Self(self.a - o.a, self.b - o.b)

    def __mul__(self, o: Self) -> Self:
        return Self(self.a * o.a, self.b * o.a + o.b * self.a)

    @staticmethod
    def zero() -> Self:
        return Self(0, SIMD[WorldType, 4](0))

    def value(self) -> Real:
        return self.a

    def recip(self) -> Self:
        var inv = 1 / self.a
        return Self(inv, -self.b * (inv * inv))

    def root(self) -> Self:
        var s = sqrt(self.a)
        if s > 0:
            return Self(s, self.b * (0.5 / s))
        return Self(s, SIMD[WorldType, 4](0))

    def positive(self) -> Self:
        return Self(Real(1) if self.a > 0 else Real(0), SIMD[WorldType, 4](0))

    def smooth_positive(self, k: Real) -> Self:
        var s = _sigmoid(k * self.a)
        return Self(s, self.b * (k * s * (1 - s)))

    def exp(self) -> Self:
        var e = exp(self.a)
        return Self(e, self.b * e)


@fieldwise_init
struct BatchReal[W: Int](SolverField):
    """`W` independent worlds' values of one scalar, one per SIMD lane
    (ROADMAP 17.18: the env dimension innermost). Every operation is
    lane-wise IEEE arithmetic, so lane `k` of a batched computation is
    bit-identical to the same computation on `RealF` with lane `k`'s inputs
    -- the batch is a layout, not a different computation. `value()` is lane
    0 (the `Field` contract wants one number); read `v[k]` for the rest."""

    var v: SIMD[WorldType, Self.W]

    @staticmethod
    def const(v: Real) -> Self:
        return Self(SIMD[WorldType, Self.W](v))

    @staticmethod
    def zero() -> Self:
        return Self(SIMD[WorldType, Self.W](0))

    def __add__(self, o: Self) -> Self:
        return Self(self.v + o.v)

    def __sub__(self, o: Self) -> Self:
        return Self(self.v - o.v)

    def __mul__(self, o: Self) -> Self:
        return Self(self.v * o.v)

    def value(self) -> Real:
        return self.v[0]

    def recip(self) -> Self:
        return Self(1 / self.v)

    def root(self) -> Self:
        return Self(sqrt(self.v))

    def positive(self) -> Self:
        return Self(
            self.v.gt(0).select(
                SIMD[WorldType, Self.W](1), SIMD[WorldType, Self.W](0)
            )
        )

    def smooth_positive(self, k: Real) -> Self:
        return Self(1 / (1 + exp(-(self.v * k))))

    def exp(self) -> Self:
        return Self(exp(self.v))


def dcos(x: DualReal) -> DualReal:
    return DualReal(cos(x.a), -sin(x.a) * x.b)


def dsin(x: DualReal) -> DualReal:
    return DualReal(sin(x.a), cos(x.a) * x.b)


@fieldwise_init
struct TapeNode(Copyable, ImplicitlyCopyable, Movable):
    """One recorded operation: operand node indices (-1 = off-tape constant)
    and the partial derivative of this node w.r.t. each operand."""

    var l: Int
    var r: Int
    var dl: Real
    var dr: Real


struct Tape(Movable, Deinitable):
    """Append-only operation record for reverse-mode AD. Declare one on the
    stack, hand `Pointer(to=tape)` to `RevReal.seed`, run the
    computation, then `grad(output.idx)` sweeps backwards once and returns
    the adjoint of every node — read the inputs' entries for the gradient."""

    var nodes: List[TapeNode]

    def __init__(out self):
        self.nodes = List[TapeNode]()

    def push(mut self, l: Int, r: Int, dl: Real, dr: Real) -> Int:
        self.nodes.append(TapeNode(l, r, dl, dr))
        return len(self.nodes) - 1

    def input(mut self) -> Int:
        return self.push(-1, -1, 0, 0)

    def grad(self, out_idx: Int) -> List[Real]:
        """Adjoint of every node w.r.t. node `out_idx` (one backward sweep)."""
        var adj = List[Real]()
        for _ in range(len(self.nodes)):
            adj.append(0)
        if out_idx >= 0 and out_idx < len(self.nodes):
            adj[out_idx] = 1
        var k = len(self.nodes) - 1
        while k >= 0:
            var a = adj[k]
            if a != 0:
                var nd = self.nodes[k]
                if nd.l >= 0:
                    adj[nd.l] += nd.dl * a
                if nd.r >= 0:
                    adj[nd.r] += nd.dr * a
            k -= 1
        return adj^


# Pointer is non-nullable in this nightly, and a stack address carries
# its own origin — the alloc-derived alias (the ecs backends' Slot idiom) plus
# Optional models "constant, no tape".
comptime TapePtr = type_of(alloc[Tape](Layout[Tape](count=1)).unsafe_leak())


@fieldwise_init
struct RevReal(SolverField):
    """Reverse-mode AD scalar: primal value + tape node index. See the module
    docstring for the off-tape constant scheme."""

    var v: Real
    var idx: Int
    var tape: Optional[TapePtr]

    @staticmethod
    def seed(t: TapePtr, v: Real) -> Self:
        """A differentiation input: registers a tape node whose adjoint is
        this input's gradient entry after `Tape.grad`."""
        return Self(v, t[].input(), t)

    def _t(self, o: Self) -> TapePtr:
        return self.tape.value() if self.idx >= 0 else o.tape.value()

    def __add__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v + o.v, -1, None)
        var t = self._t(o)
        return Self(self.v + o.v, t[].push(self.idx, o.idx, 1, 1), t)

    def __sub__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v - o.v, -1, None)
        var t = self._t(o)
        return Self(self.v - o.v, t[].push(self.idx, o.idx, 1, -1), t)

    def __mul__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v * o.v, -1, None)
        var t = self._t(o)
        return Self(
            self.v * o.v, t[].push(self.idx, o.idx, o.v, self.v), t
        )

    @staticmethod
    def zero() -> Self:
        return Self(0, -1, None)

    @staticmethod
    def const(v: Real) -> Self:
        return Self(v, -1, None)

    def value(self) -> Real:
        return self.v

    def recip(self) -> Self:
        var inv = 1 / self.v
        if self.idx < 0:
            return Self(inv, -1, None)
        var t = self.tape.value()
        return Self(inv, t[].push(self.idx, -1, -inv * inv, 0), t)

    def root(self) -> Self:
        var s = sqrt(self.v)
        if self.idx < 0:
            return Self(s, -1, None)
        var t = self.tape.value()
        var d = Real(0.5) / s if s > 0 else Real(0)
        return Self(s, t[].push(self.idx, -1, d, 0), t)

    def positive(self) -> Self:
        # zero derivative by definition (SolverField): an off-tape constant
        return Self(Real(1) if self.v > 0 else Real(0), -1, None)

    def smooth_positive(self, k: Real) -> Self:
        var s = _sigmoid(k * self.v)
        if self.idx < 0:
            return Self(s, -1, None)
        var t = self.tape.value()
        return Self(s, t[].push(self.idx, -1, k * s * (1 - s), 0), t)

    def exp(self) -> Self:
        var e = exp(self.v)
        if self.idx < 0:
            return Self(e, -1, None)
        var t = self.tape.value()
        return Self(e, t[].push(self.idx, -1, e, 0), t)


def rev_seed(mut t: Tape, v: Real) -> RevReal:
    """Seed a differentiation input on a stack-declared tape (wraps the
    address-roundtrip conversion to the alloc-typed pointer)."""
    return RevReal.seed(
        TapePtr(unsafe_from_address=Int(Pointer(to=t))), v
    )


# ---- second order: forward-over-reverse (ROADMAP 17.84) -------------------
#
# A Hessian-vector product H v of a scalar f written against `SolverField`,
# in one forward pass and one backward sweep. `RevDual` is `RevReal` whose
# primal values and recorded partials are `DualReal`s: the inputs are seeded
# with value x_i and ε-part v_i, so every value is f's intermediate at x + εv
# to first order in ε, and every partial carries its own directional
# derivative. The backward sweep runs in dual arithmetic; the adjoint of
# input i comes out as (∂f/∂x_i, (H v)_i) -- the gradient and the
# Hessian-vector product together. Cost measured on a 30-frame two-sphere
# collision: 14.1 ms against 11.5 ms for one `RevReal` gradient (1.22x;
# `bench_numerics_deep`), where a central difference of gradients needs 2.
# `positive` keeps its zero derivative, so H is the Hessian of the piecewise
# smooth branch the primal took (`test_hvp`).


struct DualTapeNode(Copyable, ImplicitlyCopyable, Movable):
    var l: Int
    var r: Int
    var dl: DualReal
    var dr: DualReal

    def __init__(out self, l: Int, r: Int, dl: DualReal, dr: DualReal):
        self.l = l
        self.r = r
        self.dl = dl
        self.dr = dr


struct DualTape(Movable, Deinitable):
    """`Tape` with dual-number partials; `grad` returns dual adjoints:
    `.a` the gradient entry, `.b` the Hessian-vector product entry."""

    var nodes: List[DualTapeNode]

    def __init__(out self):
        self.nodes = List[DualTapeNode]()

    def push(mut self, l: Int, r: Int, dl: DualReal, dr: DualReal) -> Int:
        self.nodes.append(DualTapeNode(l, r, dl, dr))
        return len(self.nodes) - 1

    def input(mut self) -> Int:
        return self.push(-1, -1, DualReal.zero(), DualReal.zero())

    def grad(self, out_idx: Int) -> List[DualReal]:
        var adj = List[DualReal](length=len(self.nodes), fill=DualReal.zero())
        if out_idx >= 0 and out_idx < len(self.nodes):
            adj[out_idx] = DualReal.const(1)
        var k = len(self.nodes) - 1
        while k >= 0:
            var a = adj[k]
            if a.a != 0 or a.b != 0:
                var nd = self.nodes[k]
                if nd.l >= 0:
                    adj[nd.l] = adj[nd.l] + nd.dl * a
                if nd.r >= 0:
                    adj[nd.r] = adj[nd.r] + nd.dr * a
            k -= 1
        return adj^


comptime DualTapePtr = type_of(alloc[DualTape](Layout[DualTape](count=1)).unsafe_leak())


@fieldwise_init
struct RevDual(SolverField):
    """Forward-over-reverse AD scalar for Hessian-vector products (see the
    section comment above)."""

    var v: DualReal
    var idx: Int
    var tape: Optional[DualTapePtr]

    def _t(self, o: Self) -> DualTapePtr:
        return self.tape.value() if self.idx >= 0 else o.tape.value()

    def __add__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v + o.v, -1, None)
        var t = self._t(o)
        return Self(self.v + o.v, t[].push(self.idx, o.idx, DualReal.const(1), DualReal.const(1)), t)

    def __sub__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v - o.v, -1, None)
        var t = self._t(o)
        return Self(self.v - o.v, t[].push(self.idx, o.idx, DualReal.const(1), DualReal.const(-1)), t)

    def __mul__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v * o.v, -1, None)
        var t = self._t(o)
        return Self(self.v * o.v, t[].push(self.idx, o.idx, o.v, self.v), t)

    @staticmethod
    def zero() -> Self:
        return Self(DualReal.zero(), -1, None)

    @staticmethod
    def const(v: Real) -> Self:
        return Self(DualReal.const(v), -1, None)

    def value(self) -> Real:
        return self.v.a

    def recip(self) -> Self:
        var inv = self.v.recip()
        if self.idx < 0:
            return Self(inv, -1, None)
        var t = self.tape.value()
        return Self(inv, t[].push(self.idx, -1, DualReal.const(-1) * inv * inv, DualReal.zero()), t)

    def root(self) -> Self:
        var s = self.v.root()
        if self.idx < 0:
            return Self(s, -1, None)
        var t = self.tape.value()
        # 0.5 / s with its ε-part -0.5 s' / s^2; the value is RevReal's
        # 0.5 / s exactly, so the gradient lane matches RevReal bit for bit
        var d = DualReal(Real(0.5) / s.a, Real(-0.5) * s.b / (s.a * s.a)) if s.a > 0 else DualReal.zero()
        return Self(s, t[].push(self.idx, -1, d, DualReal.zero()), t)

    def positive(self) -> Self:
        return Self(self.v.positive(), -1, None)

    def smooth_positive(self, k: Real) -> Self:
        var s = self.v.smooth_positive(k)
        if self.idx < 0:
            return Self(s, -1, None)
        var t = self.tape.value()
        var d = DualReal.const(k) * s * (DualReal.const(1) - s)
        return Self(s, t[].push(self.idx, -1, d, DualReal.zero()), t)

    def exp(self) -> Self:
        var e = self.v.exp()
        if self.idx < 0:
            return Self(e, -1, None)
        var t = self.tape.value()
        return Self(e, t[].push(self.idx, -1, e, DualReal.zero()), t)


def hvp_seed(mut t: DualTape, x: Real, direction: Real) -> RevDual:
    """Seed input x with its component of the direction v of H v."""
    var p = DualTapePtr(unsafe_from_address=Int(Pointer(to=t)))
    return RevDual(DualReal(x, direction), p[].input(), p)


# ---- batch x reverse (ROADMAP 17.84) ---------------------------------------
#
# `RevBatch[W]` is `RevReal` over `BatchReal[W]`'s lanes: one rollout of W
# worlds records ONE tape whose values and partials are SIMD vectors, and
# one backward sweep returns every world's gradient (lane k of each adjoint).
# Every operation is lane-wise, the same IEEE operation `RevReal` performs
# on world k, so lane k matches a `RevReal` run of world k bit for bit,
# primal and gradient (`test_rev_batch`; 1.9x faster than 8 `RevReal`
# runs, `bench_diffsolver`). Seeds are per input: an input that differs per
# world is one seed whose lanes hold the W values.


struct BatchTapeNode[W: Int](Copyable, ImplicitlyCopyable, Movable):
    var l: Int
    var r: Int
    var dl: SIMD[WorldType, Self.W]
    var dr: SIMD[WorldType, Self.W]

    def __init__(out self, l: Int, r: Int, dl: SIMD[WorldType, Self.W], dr: SIMD[WorldType, Self.W]):
        self.l = l
        self.r = r
        self.dl = dl
        self.dr = dr


struct BatchTape[W: Int](Movable, Deinitable):
    """`Tape` with SIMD partials; `grad` returns one SIMD adjoint per node,
    lane k = world k's."""

    var nodes: List[BatchTapeNode[Self.W]]

    def __init__(out self):
        self.nodes = List[BatchTapeNode[Self.W]]()

    def push(mut self, l: Int, r: Int, dl: SIMD[WorldType, Self.W], dr: SIMD[WorldType, Self.W]) -> Int:
        self.nodes.append(BatchTapeNode[Self.W](l, r, dl, dr))
        return len(self.nodes) - 1

    def input(mut self) -> Int:
        return self.push(-1, -1, SIMD[WorldType, Self.W](0), SIMD[WorldType, Self.W](0))

    def grad(self, out_idx: Int) -> List[SIMD[WorldType, Self.W]]:
        var adj = List[SIMD[WorldType, Self.W]](length=len(self.nodes), fill=SIMD[WorldType, Self.W](0))
        if out_idx >= 0 and out_idx < len(self.nodes):
            adj[out_idx] = SIMD[WorldType, Self.W](1)
        var k = len(self.nodes) - 1
        while k >= 0:
            var a = adj[k]
            if a.ne(0).reduce_or():
                var nd = self.nodes[k]
                if nd.l >= 0:
                    adj[nd.l] += nd.dl * a
                if nd.r >= 0:
                    adj[nd.r] += nd.dr * a
            k -= 1
        return adj^


comptime BatchTapePtr[W: Int] = type_of(alloc[BatchTape[W]](Layout[BatchTape[W]](count=1)).unsafe_leak())


@fieldwise_init
struct RevBatch[W: Int](SolverField):
    """Reverse-mode AD over W worlds in SIMD lanes (see the section comment
    above). `value()` is lane 0; read `v[k]` for the rest."""

    comptime V = SIMD[WorldType, Self.W]
    var v: Self.V
    var idx: Int
    var tape: Optional[BatchTapePtr[Self.W]]

    def _t(self, o: Self) -> BatchTapePtr[Self.W]:
        return self.tape.value() if self.idx >= 0 else o.tape.value()

    def __add__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v + o.v, -1, None)
        var t = self._t(o)
        return Self(self.v + o.v, t[].push(self.idx, o.idx, Self.V(1), Self.V(1)), t)

    def __sub__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v - o.v, -1, None)
        var t = self._t(o)
        return Self(self.v - o.v, t[].push(self.idx, o.idx, Self.V(1), Self.V(-1)), t)

    def __mul__(self, o: Self) -> Self:
        if self.idx < 0 and o.idx < 0:
            return Self(self.v * o.v, -1, None)
        var t = self._t(o)
        return Self(self.v * o.v, t[].push(self.idx, o.idx, o.v, self.v), t)

    @staticmethod
    def zero() -> Self:
        return Self(Self.V(0), -1, None)

    @staticmethod
    def const(v: Real) -> Self:
        return Self(Self.V(v), -1, None)

    def value(self) -> Real:
        return self.v[0]

    def recip(self) -> Self:
        var inv = 1 / self.v
        if self.idx < 0:
            return Self(inv, -1, None)
        var t = self.tape.value()
        return Self(inv, t[].push(self.idx, -1, -inv * inv, Self.V(0)), t)

    def root(self) -> Self:
        var s = sqrt(self.v)
        if self.idx < 0:
            return Self(s, -1, None)
        var t = self.tape.value()
        var d = s.gt(0).select(Self.V(0.5) / s, Self.V(0))
        return Self(s, t[].push(self.idx, -1, d, Self.V(0)), t)

    def positive(self) -> Self:
        return Self(self.v.gt(0).select(Self.V(1), Self.V(0)), -1, None)

    def smooth_positive(self, k: Real) -> Self:
        var s = 1 / (1 + exp(-(self.v * k)))
        if self.idx < 0:
            return Self(s, -1, None)
        var t = self.tape.value()
        return Self(s, t[].push(self.idx, -1, k * s * (1 - s), Self.V(0)), t)

    def exp(self) -> Self:
        var e = exp(self.v)
        if self.idx < 0:
            return Self(e, -1, None)
        var t = self.tape.value()
        return Self(e, t[].push(self.idx, -1, e, Self.V(0)), t)


def rev_batch_seed[W: Int](mut t: BatchTape[W], v: SIMD[WorldType, W]) -> RevBatch[W]:
    """Seed one input whose lane k is world k's value."""
    var p = BatchTapePtr[W](unsafe_from_address=Int(Pointer(to=t)))
    return RevBatch[W](v, p[].input(), p)
