"""Free-surface water on a 3-D MAC grid with a level set (ROADMAP 17.60:
the 3-D counterpart of `physics.mac_levelset.LevelSetWater2`; Enright /
Foster & Fedkiw, Gibou's ghost fluid for the surface pressure).

An n x n x n box of cells with solid walls on all six sides unless
`set_open` turns some into outlets (the same rule as `LevelSetWater2`:
boundary face from its interior neighbour, Dirichlet p = 0 at dx / 2 for
liquid cells next to it). phi at the
cell centres is a signed distance, negative in the liquid. u on the x
faces ((n + 1) x n x n), v on the y faces (n x (n + 1) x n), w on the z
faces (n x n x (n + 1)); the wall faces stay zero. Gravity acts along -y,
as in `physics.flip3.FlipWater3`. One `step(dt)`:

  1. advect phi, u, v and w semi-Lagrangian (RK2, trilinear, clamped to
     the box);
  2. gravity on the v faces next to liquid;
  3. pressure on the liquid cells only: -lap p = -div u / dt with the
     walls as Neumann (no flux) and the surface as Dirichlet p = 0 placed
     where phi crosses zero between a liquid cell and an air neighbour
     (ghost fluid: the neighbour's coefficient becomes 1 / theta,
     theta = phi_l / (phi_l - phi_a) >= 0.01, into the diagonal); solved
     by `numerics.pcg` matrix-free;
  4. faces between liquid and liquid or liquid and air get u -= dt grad p
     (air pressure 0 at the theta point);
  5. velocities are extrapolated into the air in `extrap` rings (each air
     face takes the mean of its known neighbours);
  6. every `reinit_every` steps phi is redistanced by fast sweeping over
     the eight sweep orders (Zhao 2005), keeping the cells next to the
     zero crossing fixed.

The 3-D Godunov update is the sorted-neighbour form: with the three
smallest axis values x0 <= x1 <= x2, the new distance is x0 + dx when that
is at most x1, else the two-axis root when it is at most x2, else the
three-axis root.
"""

from .mac_levelset import LevelSetWater

comptime LevelSetWater3 = LevelSetWater[3]
"""The 3-D level-set water (n x n x n cells); one struct with `LevelSetWater2` (physics/mac_levelset.mojo)."""
