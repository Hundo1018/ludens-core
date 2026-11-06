"""Undo and redo of entity deletion (ROADMAP 17.43, #83).

Deleting an entity is a change an editor must be able to take back with every handle still valid. `EntityUndo`
removes an entity from a world and keeps its components in a graveyard world of the same backend and component pack;
`undo` brings the entity back under the same id and generation (`World.respawn`) and copies the components back.
Components that hold other entities (a hierarchy parent link, a relation) therefore point at live handles again.

    var eu = EntityUndo[SparseSetBackend[Pos, Vel], Pos, Vel]()
    eu.delete(world, e)        # e is gone; its components are in the graveyard
    _ = eu.undo(world)         # e is back: same id, same generation, same components
    _ = eu.redo(world)         # gone again

Nothing is stored as bytes: the components are copied as typed values, so any `ComponentType` works, including ones
with no schema. A new `delete` ends the redo chain. `undo` returns False (world unchanged) when there is nothing to
undo or the entity's id was reused by a spawn made after the delete (the stale step stays on the stack)."""
from .component import ComponentType
from .entity import Entity
from .storage import StorageBackend
from .world import World


@fieldwise_init
struct DelStep(Copyable, Movable):
    var gone: Entity  # the entity as the world knew it
    var grave: Entity  # where its components wait in the graveyard


struct EntityUndo[B: StorageBackend, *Cs: ComponentType](Movable):
    comptime N: Int = len(Self.Cs)
    var grave: World[Self.B]
    var past: List[DelStep]
    var future: List[DelStep]

    def __init__(out self):
        self.grave = World[Self.B]()
        self.past = List[DelStep]()
        self.future = List[DelStep]()

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
        self.past.append(DelStep(e, g))
        self.future = List[DelStep]()

    def undo(mut self, mut w: World[Self.B]) -> Bool:
        if len(self.past) == 0:
            return False
        var s = self.past[len(self.past) - 1].copy()
        if not self._move_back(w, s.gone, s.grave):
            return False
        _ = self.past.pop()
        # the graveyard entity was despawned by _move_back; redo needs components again, so redo re-captures from `w`
        self.future.append(DelStep(s.gone, Entity(-1, 0)))
        return True

    def redo(mut self, mut w: World[Self.B]) -> Bool:
        if len(self.future) == 0:
            return False
        var s = self.future[len(self.future) - 1].copy()
        if not w.is_alive(s.gone):
            return False
        _ = self.future.pop()
        var g = self._move_out(w, s.gone)
        self.past.append(DelStep(s.gone, g))
        return True
