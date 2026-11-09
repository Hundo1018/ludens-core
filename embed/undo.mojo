"""Undo and redo for edits to a world's bodies (ROADMAP 17.43, ludens-engine #83).

An editor groups its edits into transactions. For each body a transaction touches, the log keeps the body's scene
record (`embed.scene_io.SceneBody`) from before the edit and from after it, so one mechanism covers a move, a velocity,
a property, a layer, an added body and a removed body, with no per-operation inverse to write and keep in step.

    log.begin("move")
    log.touch(world, h)          # before changing body h: keeps its record
    world.teleport(h, ...)
    log.commit(world)            # keeps the records after; an edit that changed nothing leaves no step

    log.begin("add")
    var h = world.add_box(...)
    log.created(world, h)        # a body that did not exist before the transaction
    log.commit(world)

`undo` and `redo` put the records back. A removed body comes back with the same `BodyId` (slot and generation), so
handles an editor holds (the selection, references between objects) are valid again; `BodySet`'s slot reservation
makes that possible. Transactions nest (only the outermost counts), consecutive ones with the same non-zero
`merge_key` on the same bodies merge into one step (a drag is one undo), a new commit ends the redo chain, and the
oldest steps are dropped past `max_steps`.

What it covers is what `scene_io` covers: box and sphere bodies, their pose, velocity, properties, collision layer,
host material and user data. It restores authored state; the solver's runtime state (sleeping, warm-start caches) is
the solver's to rebuild. `SnapshotUndo` is the other implementation of the same contract: one deterministic snapshot
(`EmbedWorld.save`) per step. It restores everything `save` holds, costs memory in proportion to the world, and does
not restore host material ids (`save` does not hold them).
"""
from embed.scene_io import SceneBody, body_equal, body_record, restore_body, same_shape, write_body_record
from embed.world import EmbedWorld
from physics.joints6 import JOINT_BROKEN, Joint6


@fieldwise_init
struct SolverFlags(Copyable, ImplicitlyCopyable, Movable):
    """The scene-wide switches that mean "some body uses this" (`BodySet.any_*`). Setting a property raises one; the
    snapshot even writes an extra block when one is up, so an undo puts them back to their values from before."""
    var props: Bool
    var contact_model: Bool
    var report: Bool
    var bullet: Bool


def read_flags(world: EmbedWorld) -> SolverFlags:
    return SolverFlags(
        world.scene.bset.any_props, world.scene.bset.any_contact_model, world.scene.bset.any_report, world.scene.bset.any_bullet
    )


def write_flags(mut world: EmbedWorld, f: SolverFlags):
    world.scene.bset.any_props = f.props
    world.scene.bset.any_contact_model = f.contact_model
    world.scene.bset.any_report = f.report
    world.scene.bset.any_bullet = f.bullet


@fieldwise_init
struct BodyRec(Copyable, Movable):
    var handle: Int64
    var existed_before: Bool
    var existed_after: Bool
    var before: SceneBody
    var after: SceneBody


@fieldwise_init
struct JointRec(Copyable, Movable):
    """One joint slot's state before and after a transaction. Joint slots never shift (`remove_joint` keeps the slot),
    so the slot number is the identity; an inert (`JOINT_BROKEN`) record means "no joint"."""
    var slot: Int
    var before: Joint6
    var after: Joint6


def _joint_equal(a: Joint6, b: Joint6) -> Bool:
    return (
        a.kind == b.kind and a.a == b.a and a.b == b.b and a.la == b.la and a.lb == b.lb and a.rest == b.rest
        and a.axis_a == b.axis_a and a.axis_b == b.axis_b
    )


struct Transaction(Copyable, Movable):
    var name: String
    var merge_key: Int
    var recs: List[BodyRec]
    var jrecs: List[JointRec]
    var flags_known: Bool
    var flags_before: SolverFlags
    var flags_after: SolverFlags

    def __init__(out self, name: String, merge_key: Int):
        self.name = name
        self.merge_key = merge_key
        self.recs = List[BodyRec]()
        self.jrecs = List[JointRec]()
        self.flags_known = False
        self.flags_before = SolverFlags(False, False, False, False)
        self.flags_after = SolverFlags(False, False, False, False)

    def find(self, h: Int64) -> Int:
        for i in range(len(self.recs)):
            if self.recs[i].handle == h:
                return i
        return -1

    def find_joint(self, slot: Int) -> Int:
        for i in range(len(self.jrecs)):
            if self.jrecs[i].slot == slot:
                return i
        return -1


def _apply(mut world: EmbedWorld, rec: BodyRec, to_before: Bool) raises:
    """Put one body back to its record from before (`to_before`) or from after the transaction."""
    var exists = rec.existed_before if to_before else rec.existed_after
    var target = rec.before.copy() if to_before else rec.after.copy()
    var h = rec.handle
    if exists:
        if world.is_alive(h):
            if same_shape(body_record(world, h), target):
                write_body_record(world, h, target)
            else:
                world.remove(h)
                restore_body(world, h, target)
        else:
            restore_body(world, h, target)
    elif world.is_alive(h):
        world.remove(h)


def _apply_step(mut world: EmbedWorld, t: Transaction, to_before: Bool) raises:
    """Put every body and joint of a transaction to its record from before (`to_before`) or after. Order matters
    because a body cannot be removed while a live joint holds it and a joint cannot be restored without its bodies:
    joints that become inert first, then the bodies (restored in the order the transaction made them, removed in
    reverse), then joints that become live."""
    for k in range(len(t.jrecs)):
        var target = t.jrecs[k].before if to_before else t.jrecs[k].after
        if target.kind == JOINT_BROKEN:
            world.restore_joint(t.jrecs[k].slot, target)
    if to_before:
        for k in range(len(t.recs) - 1, -1, -1):
            _apply(world, t.recs[k], True)
    else:
        for k in range(len(t.recs)):
            _apply(world, t.recs[k], False)
    for k in range(len(t.jrecs)):
        var target = t.jrecs[k].before if to_before else t.jrecs[k].after
        if target.kind != JOINT_BROKEN:
            world.restore_joint(t.jrecs[k].slot, target)


struct UndoLog(Movable):
    var past: List[Transaction]
    var future: List[Transaction]
    var cur: Transaction
    var depth: Int
    var max_steps: Int

    def __init__(out self, max_steps: Int = 1000):
        self.past = List[Transaction]()
        self.future = List[Transaction]()
        self.cur = Transaction(String(), 0)
        self.depth = 0
        self.max_steps = max_steps

    def can_undo(self) -> Bool:
        return len(self.past) > 0

    def can_redo(self) -> Bool:
        return len(self.future) > 0

    def undo_name(self) -> String:
        return self.past[len(self.past) - 1].name if len(self.past) > 0 else String()

    def redo_name(self) -> String:
        return self.future[len(self.future) - 1].name if len(self.future) > 0 else String()

    def steps(self) -> Int:
        return len(self.past)

    def begin(mut self, name: String, merge_key: Int = 0) raises:
        """Open a transaction (or nest inside the open one). `merge_key` != 0 lets it merge with the previous step."""
        if self.depth == 0:
            self.cur = Transaction(name, merge_key)
        self.depth += 1

    def _capture_flags(mut self, world: EmbedWorld):
        if not self.cur.flags_known:
            self.cur.flags_known = True
            self.cur.flags_before = read_flags(world)

    def touch(mut self, world: EmbedWorld, h: Int64) raises:
        """Call before changing body `h`: keeps its record. Touching a body twice in a transaction is harmless."""
        if self.depth == 0:
            raise Error("UndoLog.touch: no open transaction")
        if self.cur.find(h) >= 0:
            return
        self._capture_flags(world)
        self.cur.recs.append(BodyRec(h, True, True, body_record(world, h), SceneBody.empty()))

    def created(mut self, world: EmbedWorld, h: Int64) raises:
        """Call right after adding body `h` inside the transaction."""
        if self.depth == 0:
            raise Error("UndoLog.created: no open transaction")
        if not world.is_alive(h):
            raise Error("UndoLog.created: the handle is not a live body")
        if self.cur.find(h) >= 0:
            raise Error("UndoLog.created: the body is already in this transaction")
        self._capture_flags(world)
        self.cur.recs.append(BodyRec(h, False, True, SceneBody.empty(), SceneBody.empty()))

    def touch_joint(mut self, world: EmbedWorld, slot: Int) raises:
        """Call before changing or removing joint `slot`: keeps its state. Touching it twice is harmless."""
        if self.depth == 0:
            raise Error("UndoLog.touch_joint: no open transaction")
        if self.cur.find_joint(slot) >= 0:
            return
        var rec = world.joint_record(slot)
        self.cur.jrecs.append(JointRec(slot, rec, rec))

    def created_joint(mut self, world: EmbedWorld, slot: Int) raises:
        """Call right after adding the joint in slot `slot` inside the transaction."""
        if self.depth == 0:
            raise Error("UndoLog.created_joint: no open transaction")
        if self.cur.find_joint(slot) >= 0:
            raise Error("UndoLog.created_joint: the joint is already in this transaction")
        var inert = world.joint_record(slot)
        inert.kind = JOINT_BROKEN
        self.cur.jrecs.append(JointRec(slot, inert, inert))

    def commit(mut self, world: EmbedWorld) raises:
        """Close the transaction. Nested commits only count down; the outermost one keeps the records from after the
        edit. A transaction that changed nothing leaves no step and keeps the redo chain."""
        if self.depth == 0:
            raise Error("UndoLog.commit: no open transaction")
        self.depth -= 1
        if self.depth > 0:
            return
        var t = Transaction(self.cur.name, self.cur.merge_key)
        t.flags_known = self.cur.flags_known
        t.flags_before = self.cur.flags_before
        t.flags_after = read_flags(world)
        for i in range(len(self.cur.recs)):
            var r = self.cur.recs[i].copy()
            r.existed_after = world.is_alive(r.handle)
            r.after = body_record(world, r.handle) if r.existed_after else SceneBody.empty()
            if not r.existed_before and not r.existed_after:
                continue
            if r.existed_before and r.existed_after and body_equal(r.before, r.after):
                continue
            t.recs.append(r^)
        for i in range(len(self.cur.jrecs)):
            var jr = self.cur.jrecs[i].copy()
            jr.after = world.joint_record(jr.slot)
            if _joint_equal(jr.before, jr.after):
                continue
            t.jrecs.append(jr^)
        self.cur = Transaction(String(), 0)
        if len(t.recs) == 0 and len(t.jrecs) == 0:
            return
        self.future = List[Transaction]()
        if self._merge(t):
            return
        self.past.append(t^)
        if len(self.past) > self.max_steps:
            var kept = List[Transaction]()
            for i in range(1, len(self.past)):
                kept.append(self.past[i].copy())
            self.past = kept^

    def _merge(mut self, t: Transaction) -> Bool:
        if t.merge_key == 0 or len(self.past) == 0 or len(t.jrecs) > 0 or len(self.past[len(self.past) - 1].jrecs) > 0:
            return False
        var n = len(self.past) - 1
        if self.past[n].merge_key != t.merge_key or len(self.past[n].recs) != len(t.recs):
            return False
        for i in range(len(t.recs)):
            ref a = self.past[n].recs[i]
            ref b = t.recs[i]
            if a.handle != b.handle or not (a.existed_before and a.existed_after and b.existed_before and b.existed_after):
                return False
        self.past[n].flags_after = t.flags_after
        var net_change = False
        for i in range(len(t.recs)):
            self.past[n].recs[i].after = t.recs[i].after.copy()
            if not body_equal(self.past[n].recs[i].before, self.past[n].recs[i].after):
                net_change = True
        if not net_change:
            _ = self.past.pop()  # dragged back to where it started: no step at all
        return True

    def abort(mut self, mut world: EmbedWorld) raises:
        """Throw the open transaction away: every body it touched goes back to its record from before."""
        if self.depth == 0:
            raise Error("UndoLog.abort: no open transaction")
        _apply_step(world, self.cur, True)
        if self.cur.flags_known:
            write_flags(world, self.cur.flags_before)
        self.cur = Transaction(String(), 0)
        self.depth = 0

    def undo(mut self, mut world: EmbedWorld) raises -> Bool:
        """Undo the latest step. False when there is none. If a record cannot be applied (the body was changed outside
        the log) this raises and the world may be partly restored; the step stays on the stack."""
        if self.depth > 0:
            raise Error("UndoLog.undo: a transaction is open")
        if len(self.past) == 0:
            return False
        var n = len(self.past) - 1
        _apply_step(world, self.past[n], True)
        if self.past[n].flags_known:
            write_flags(world, self.past[n].flags_before)
        self.future.append(self.past.pop())
        return True

    def redo(mut self, mut world: EmbedWorld) raises -> Bool:
        if self.depth > 0:
            raise Error("UndoLog.redo: a transaction is open")
        if len(self.future) == 0:
            return False
        var n = len(self.future) - 1
        _apply_step(world, self.future[n], False)
        if self.future[n].flags_known:
            write_flags(world, self.future[n].flags_after)
        self.past.append(self.future.pop())
        return True


struct SnapshotUndo(Movable):
    """The same contract with one deterministic snapshot per step: `begin` keeps `save()`, `commit` keeps the `save()`
    after it, `undo` / `redo` `load` them. Simple and complete (whatever `save` holds comes back), but each step
    costs two snapshots, which is the whole world however small the edit."""
    var before: List[List[UInt8]]
    var after: List[List[UInt8]]
    var fbefore: List[List[UInt8]]
    var fafter: List[List[UInt8]]
    var pending: List[UInt8]
    var open: Bool

    def __init__(out self):
        self.before = List[List[UInt8]]()
        self.after = List[List[UInt8]]()
        self.fbefore = List[List[UInt8]]()
        self.fafter = List[List[UInt8]]()
        self.pending = List[UInt8]()
        self.open = False

    def can_undo(self) -> Bool:
        return len(self.before) > 0

    def can_redo(self) -> Bool:
        return len(self.fbefore) > 0

    def begin(mut self, world: EmbedWorld) raises:
        if self.open:
            raise Error("SnapshotUndo.begin: a transaction is open")
        self.pending = world.save()
        self.open = True

    def commit(mut self, world: EmbedWorld) raises:
        if not self.open:
            raise Error("SnapshotUndo.commit: no open transaction")
        self.open = False
        var now = world.save()
        if now == self.pending:
            return
        self.fbefore = List[List[UInt8]]()
        self.fafter = List[List[UInt8]]()
        self.before.append(self.pending.copy())
        self.after.append(now^)

    def undo(mut self, mut world: EmbedWorld) raises -> Bool:
        if len(self.before) == 0:
            return False
        var b = self.before.pop()
        var a = self.after.pop()
        world.load(b)
        self.fbefore.append(b^)
        self.fafter.append(a^)
        return True

    def redo(mut self, mut world: EmbedWorld) raises -> Bool:
        if len(self.fbefore) == 0:
            return False
        var b = self.fbefore.pop()
        var a = self.fafter.pop()
        world.load(a)
        self.before.append(b^)
        self.after.append(a^)
        return True

    def bytes(self) -> Int:
        var n = 0
        for i in range(len(self.before)):
            n += len(self.before[i]) + len(self.after[i])
        return n
