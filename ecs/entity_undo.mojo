"""Undo and redo of entity edits (ROADMAP 17.43, #83): deleting an entity, and changing or removing a component.

An editor must be able to take an edit back with every handle still valid. `EntityUndo` keeps what an edit replaced
in a graveyard world of the same backend and component pack:

- `delete(w, e)` moves e's components to the graveyard and despawns e; `undo` brings e back under the same id and
  generation (`World.respawn`) and copies the components back, so components that hold other entities (a hierarchy
  parent link, a relation) point at live handles again.
- `change(w, e, value)` sets a component and keeps the value it had (or that it had none); `remove[C](w, e)` removes
  one and keeps it. `undo` puts the earlier state back, `redo` the later one. Both go through `World.set` /
  `World.remove`, so change tracking and observers see them like any other write.

    var eu = EntityUndo[SparseSetBackend[Pos, Vel], Pos, Vel]()
    eu.change(w, e, Pos(3, 4))           # one undo step
    eu.change(w, e, Pos(5, 6), True)     # merge: a drag stays one step (same entity, same component, top of the stack)
    eu.begin()                           # a transaction: everything until commit is one undo step
    eu.delete(w, child)
    eu.delete(w, parent)
    eu.commit()
    _ = eu.undo(w)                       # parent and child are back
    _ = eu.undo(w)                       # Pos is what it was before the drag

Nothing is stored as bytes: components are copied as typed values, so any `ComponentType` works, including ones with
no schema. A new edit ends the redo chain. Transactions nest; only the outermost `commit` closes the step, and an
empty transaction leaves no step. `undo` returns False with the world unchanged when there is nothing to undo, or
when an entity of the step cannot come back because a spawn made after the delete took its id (the step stays)."""
from .component import ComponentType
from .entity import Entity
from .storage import StorageBackend
from .world import World

comptime STEP_DELETE = 0
comptime STEP_CHANGE = 1


@fieldwise_init
struct DelStep(Copyable, Movable):
    """One recorded edit. Delete: `gone` and its components in `grave`. Change: `gone` is the entity, `cid` the
    component id, `grave` holds the component as it was before (none = it had none) and `after` as it is after."""

    var gone: Entity
    var grave: Entity
    var kind: Int
    var cid: Int
    var after: Entity
    var txn: Int  # steps of one transaction share this number and undo together


struct EntityUndo[B: StorageBackend, *Cs: ComponentType](Movable):
    comptime N: Int = len(Self.Cs)
    var grave: World[Self.B]
    var past: List[DelStep]
    var future: List[DelStep]
    var max_steps: Int  # undo steps (transactions) kept; the oldest is dropped past this and its graveyard released
    var depth: Int  # open `begin`s
    var next_txn: Int
    var open_txn: Int  # the number of the open transaction, -1 when none

    def __init__(out self, max_steps: Int = 1000):
        self.grave = World[Self.B]()
        self.past = List[DelStep]()
        self.future = List[DelStep]()
        self.max_steps = max_steps
        self.depth = 0
        self.next_txn = 0
        self.open_txn = -1

    # ------------------------------------------------------------------ transactions

    def begin(mut self):
        if self.depth == 0:
            self.open_txn = self.next_txn
            self.next_txn += 1
        self.depth += 1

    def commit(mut self) raises:
        if self.depth == 0:
            raise Error("EntityUndo.commit: no transaction is open")
        self.depth -= 1
        if self.depth == 0:
            self.open_txn = -1
            self._cap()

    def steps(self) -> Int:
        """Undo steps on the stack (a transaction counts once)."""
        var n = 0
        var last = -1
        for i in range(len(self.past)):
            if self.past[i].txn != last:
                n += 1
                last = self.past[i].txn
        return n

    def _txn(mut self) -> Int:
        if self.depth > 0:
            return self.open_txn
        self.next_txn += 1
        return self.next_txn - 1

    def _release(mut self, s: DelStep):
        if self.grave.is_alive(s.grave):
            self.grave.despawn(s.grave)
        if self.grave.is_alive(s.after):
            self.grave.despawn(s.after)

    def _record(mut self, s: DelStep):
        self.past.append(s.copy())
        for i in range(len(self.future)):
            var f = self.future[i].copy()
            self._release(f)
        self.future = List[DelStep]()
        if self.depth == 0:
            self._cap()

    def _cap(mut self):
        while self.steps() > self.max_steps:
            var first = self.past[0].txn
            var kept = List[DelStep]()
            for k in range(len(self.past)):
                if self.past[k].txn == first:
                    var old = self.past[k].copy()
                    self._release(old)
                else:
                    kept.append(self.past[k].copy())
            self.past = kept^

    # ------------------------------------------------------------------ delete

    def _move_out(mut self, mut w: World[Self.B], e: Entity) -> Entity:
        """Copy e's components to a new graveyard entity and despawn e from `w`."""
        var g = self.grave.spawn()
        comptime for i in range(Self.N):
            comptime T = Self.Cs[i]
            if w.has[T](e):
                self.grave.set(g, w.get[T](e))
        w.despawn(e)
        return g

    def _move_back(mut self, mut w: World[Self.B], e: Entity, g: Entity) -> Bool:
        if not w.respawn(e):
            return False
        comptime for i in range(Self.N):
            comptime T = Self.Cs[i]
            if self.grave.has[T](g):
                w.set(e, self.grave.get[T](g))
        self.grave.despawn(g)
        return True

    def delete(mut self, mut w: World[Self.B], e: Entity) raises:
        if not w.is_alive(e):
            raise Error("EntityUndo.delete: the entity is not alive")
        var g = self._move_out(w, e)
        self._record(DelStep(e, g, STEP_DELETE, -1, Entity(-1, 0), self._txn()))

    # ------------------------------------------------------------------ component edits

    def _put(mut self, mut w: World[Self.B], e: Entity, cid: Int, from_grave: Entity):
        """Make component `cid` of e what the graveyard entity holds: its value, or absent."""
        comptime for i in range(Self.N):
            comptime T = Self.Cs[i]
            if T.ID == cid:
                if self.grave.has[T](from_grave):
                    w.set(e, self.grave.get[T](from_grave))
                elif w.has[T](e):
                    w.remove[T](e)

    def change[C: ComponentType](mut self, mut w: World[Self.B], e: Entity, var value: C, merge: Bool = False) raises:
        """Set a component as one undo step. With `merge`, a change to the same component of the same entity on top of
        the stack absorbs this one (the step keeps its first `before`), so a drag is undone in one step."""
        if not w.is_alive(e):
            raise Error("EntityUndo.change: the entity is not alive")
        if merge and len(self.past) > 0 and len(self.future) == 0:
            var top = self.past[len(self.past) - 1].copy()
            var same_txn = self.depth == 0 or top.txn == self.open_txn
            if top.kind == STEP_CHANGE and top.gone == e and top.cid == C.ID and same_txn:
                self.grave.set(top.after, value.copy())
                w.set(e, value^)
                return
        var before = self.grave.spawn()
        if w.has[C](e):
            self.grave.set(before, w.get[C](e))
        var after = self.grave.spawn()
        self.grave.set(after, value.copy())
        w.set(e, value^)
        self._record(DelStep(e, before, STEP_CHANGE, C.ID, after, self._txn()))

    def remove[C: ComponentType](mut self, mut w: World[Self.B], e: Entity) raises:
        """Remove a component as one undo step. Removing one the entity does not have records nothing."""
        if not w.is_alive(e):
            raise Error("EntityUndo.remove: the entity is not alive")
        if not w.has[C](e):
            return
        var before = self.grave.spawn()
        self.grave.set(before, w.get[C](e))
        var after = self.grave.spawn()  # holds nothing: the component is absent afterwards
        w.remove[C](e)
        self._record(DelStep(e, before, STEP_CHANGE, C.ID, after, self._txn()))

    # ------------------------------------------------------------------ undo / redo

    def undo(mut self, mut w: World[Self.B]) -> Bool:
        if len(self.past) == 0 or self.depth > 0:
            return False
        var txn = self.past[len(self.past) - 1].txn
        # newest edit of the step first; a step that cannot be undone whole is put back and refused
        var k = len(self.past) - 1
        while k >= 0 and self.past[k].txn == txn:
            var s = self.past[k].copy()
            if s.kind == STEP_DELETE:
                if not self._move_back(w, s.gone, s.grave):
                    # put back what this call already undid, newest last, and refuse
                    var j = len(self.future) - 1
                    while j >= 0 and self.future[j].txn == txn:
                        var f = self.future.pop()
                        self._redo_one(w, f)
                        j -= 1
                    return False
                _ = self.past.pop()
                self.future.append(DelStep(s.gone, Entity(-1, 0), STEP_DELETE, -1, Entity(-1, 0), txn))
            else:
                if not w.is_alive(s.gone):
                    var j = len(self.future) - 1
                    while j >= 0 and self.future[j].txn == txn:
                        var f = self.future.pop()
                        self._redo_one(w, f)
                        j -= 1
                    return False
                self._put(w, s.gone, s.cid, s.grave)
                _ = self.past.pop()
                self.future.append(s.copy())
            k -= 1
        return True

    def _redo_one(mut self, mut w: World[Self.B], s: DelStep):
        if s.kind == STEP_DELETE:
            var g = self._move_out(w, s.gone)
            self.past.append(DelStep(s.gone, g, STEP_DELETE, -1, Entity(-1, 0), s.txn))
        else:
            self._put(w, s.gone, s.cid, s.after)
            self.past.append(s.copy())

    def redo(mut self, mut w: World[Self.B]) -> Bool:
        if len(self.future) == 0 or self.depth > 0:
            return False
        var txn = self.future[len(self.future) - 1].txn
        var k = len(self.future) - 1
        while k >= 0 and self.future[k].txn == txn:
            if not w.is_alive(self.future[k].gone):
                return False
            k -= 1
        while len(self.future) > 0 and self.future[len(self.future) - 1].txn == txn:
            var s = self.future.pop()
            self._redo_one(w, s)
        return True
