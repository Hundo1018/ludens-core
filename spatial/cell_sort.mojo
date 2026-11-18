"""Points grouped by grid cell with a stable counting sort.

`build(cid, cells)` takes each point's cell id (the caller's own cell rule: clamped, floored, 2-D or 3-D) and
fills `start` (cells + 1 offsets) and `items` (point indices): the points of cell c are
`items[start[c] : start[c + 1]]`, in ascending index order. Integers only, so a solver that switches to it
gets the same order it had. Used by the PBF / SPH / unified particle grids (physics), crowd neighbours (nav)
and flocking (ai), which each carried a copy.
"""


struct CellSort(Movable):
    var start: List[Int]  # cells + 1 offsets into items
    var items: List[Int]  # point indices, grouped by cell, ascending within a cell

    def __init__(out self):
        self.start = List[Int]()
        self.items = List[Int]()

    def build(mut self, cid: List[Int], cells: Int):
        """Group the points 0 .. len(cid) - 1 by `cid[i]` in [0, cells)."""
        var n = len(cid)
        self.start = List[Int](length=cells + 1, fill=0)
        for i in range(n):
            self.start[cid[i] + 1] += 1
        for c in range(cells):
            self.start[c + 1] += self.start[c]
        var fill = self.start.copy()
        self.items = List[Int](length=n, fill=0)
        for i in range(n):
            var c = cid[i]
            self.items[fill[c]] = i
            fill[c] += 1
