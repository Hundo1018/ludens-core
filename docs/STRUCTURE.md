# Structure

Generated from `build/archindex.json` by `scripts/gen_structure.py`
(`pixi run structure`); do not edit by hand. The CI job and the `pre-push`
hook run `pixi run structure -- --check`.

Packages are in layer order (`scripts/arch_layers.toml`). For one name use
`pixi run arch -- def NAME`; for the import graph use `pixi run arch -- deps PKG`.
Underscore-prefixed names are package-private and are not listed. Methods are
counted, not listed.

## diag (layer 0) — 8 modules, 61 public declarations

### `diag/arena.mojo`
- struct `FrameArena` — 4 methods

### `diag/counters.mojo`
- struct `Counters` — 4 methods
- `def counter_name(id: Int) -> String`
- aliases: `ARENA_OVERFLOW`, `CCD_BUDGET_EXCEEDED`, `CG_NOT_CONVERGED`, `COLOR_OVERFLOW`, `CONTACT_DROPPED`, `CONTACT_MANIFOLDS`, `CONTACT_POINTS`, `CONTINUUM_ESCAPED`, `CONTINUUM_NAN`, `COUNT`, `COUPLING_REJECTED`, `DRAW_DROPPED`, `EVENT_DROPPED_UNREAD`, `FRAGMENT_EVICTED`, `GAMELOOP_DEBT_DROPPED`, `LOG_DROPPED`, `NAN_QUARANTINED`, `NARROWPHASE_PAIRS`, `OUTBOX_DROPPED`, `PARALLEL_FALLBACK_SERIAL`, `POOL_EXHAUSTED`, `POOL_GROWN`, `TIER_FALLBACK`, `TIMER_FIRES_DROPPED`, `TRACE_DROPPED`, `VEHICLE_FORCE_DROPPED`, `VELOCITY_CLAMPED`

### `diag/draw.mojo`
- struct `DrawCommand` — 0 methods
- struct `DrawQueue` — 9 methods
- struct `Kind` — 0 methods
- aliases: `ARROW`, `BOX`, `LINE`, `POINT`, `SPHERE`, `TEXT`

### `diag/invariant.mojo`
- `def invariant_finite[dtype: DType, w: SIMDLength, //](x: SIMD[dtype, w], msg: String)`

### `diag/level.mojo`
- struct `Level` — 0 methods
- `def level_name(level: Int) -> String`
- aliases: `DEBUG`, `DEBUG_DRAW_ON`, `ERROR`, `INFO`, `LOG_LEVEL`, `OFF`, `TRACE`, `TRACE_ON`, `WARN`

### `diag/log.mojo`
- struct `LogRecord` : Writable — 1 methods
- struct `LogRing` — 4 methods
- `def log[cap: Int, //, level: Int](mut ring: LogRing[cap], tick: Int, category: String, message: String, a: Float64 = 0, b: Float64 = 0)`

### `diag/outbox.mojo`
- struct `OutRecord` — 0 methods
- struct `Outbox` — 4 methods

### `diag/trace.mojo`
- struct `CounterSample` — 0 methods
- struct `ScopedSpan` — 0 methods
- struct `SpanEvent` — 0 methods
- struct `SpanStat` — 0 methods
- struct `TraceBuffer` — 10 methods

## geometry (layer 1) — 45 modules, 280 public declarations

### `geometry/aabb.mojo`
- struct `AABB` — 9 methods
- aliases: `AABB2`, `AABB3`

### `geometry/abc_file.mojo`
- struct `AbcArchive` — 8 methods
- struct `AbcObject` — 0 methods
- `def abc_read(d: List[UInt8]) -> List[AbcObject]`
- aliases: `ABC_CURVES`, `ABC_MESH`, `ABC_POINTS`

### `geometry/blosc.mojo`
- `def blosc_decode(c: List[UInt8], n_out: Int) -> List[UInt8]`
- `def lz4_decode(src: List[UInt8], n_out: Int) -> List[UInt8]`

### `geometry/cga.mojo`
- struct `Circle3` — 1 methods
- struct `Plane3` — 0 methods
- `def apply_versor(v: Multivector[Int(4), Int(1), Int(0)], p: SIMD[.float32, 4]) -> Vec3`
- `def dilate_point(scale: Float32, p: SIMD[.float32, 4]) -> Vec3`
- `def dilate_point_with(d: Multivector[Int(4), Int(1), Int(0)], drev: Multivector[Int(4), Int(1), Int(0)], p: SIMD[.float32, 4]) -> Vec3`
- `def dilator(scale: Float32) -> CGA3`
- `def dilator_reverse(scale: Float32) -> CGA3`
- `def down(P: Multivector[Int(4), Int(1), Int(0)]) -> Vec3`
- `def inner(a: Multivector[Int(4), Int(1), Int(0)], b: Multivector[Int(4), Int(1), Int(0)]) -> Real`
- `def invert_point(center: SIMD[.float32, 4], radius: Float32, p: SIMD[.float32, 4]) -> Vec3`
- `def invert_point_with(s: Multivector[Int(4), Int(1), Int(0)], p: SIMD[.float32, 4]) -> Vec3`
- `def n_inf() -> CGA3`
- `def n_o() -> CGA3`
- `def plane_dual(pl: Plane3) -> CGA3`
- `def point_circle_dist(c: Circle3, p: SIMD[.float32, 4]) -> Real`
- `def point_circle_dist_cga(c: Circle3, p: SIMD[.float32, 4]) -> Real`
- `def reflect_point(pl: Plane3, p: SIMD[.float32, 4]) -> Vec3`
- `def rotor(axis: SIMD[.float32, 4], angle: Float32) -> CGA3`
- `def sphere_dist_sq(s1: Multivector[Int(4), Int(1), Int(0)], s2: Multivector[Int(4), Int(1), Int(0)], r1: Float32, r2: Float32) -> Real`
- `def sphere_dual(center: SIMD[.float32, 4], radius: Float32) -> CGA3`
- `def spheres_intersect(s1: Multivector[Int(4), Int(1), Int(0)], s2: Multivector[Int(4), Int(1), Int(0)]) -> Bool`
- `def translator(t: SIMD[.float32, 4]) -> CGA3`
- `def up(p: SIMD[.float32, 4]) -> CGA3`

### `geometry/checkpoint.mojo`
- trait `RevSystem` — 0 methods
- struct `RevGrad` — 0 methods
- `def grad_checkpointed[S: RevSystem](sys: S, x0: List[Float32], params: List[Float32], steps: Int, every: Int) -> RevGrad`
- `def grad_full[S: RevSystem](sys: S, x0: List[Float32], params: List[Float32], steps: Int) -> RevGrad`

### `geometry/convex_decomp.mojo`
- trait `ConvexDecomposer` — 0 methods
- struct `ClusterDecomposer` : ConvexDecomposer — 1 methods
- struct `ConvexParts` — 5 methods
- struct `SplitDecomposer` : ConvexDecomposer — 1 methods
- struct `VoxelGrid` — 5 methods
- `def decompose_with[D: ConvexDecomposer](d: D, grid: VoxelGrid) -> ConvexParts`
- `def mesh_volume(verts: List[Float64], indices: List[Int]) -> Float64`
- `def voxelize(verts: List[Float64], indices: List[Int], res: Int) -> VoxelGrid`

### `geometry/dcga.mojo`
- struct `DcgaEntity` — 1 methods
- `def dcga_incidence(pt: Array[Float32, Int(15)], e: DcgaEntity) -> Real`
- `def dcga_plane(normal: SIMD[.float32, 4], d: Float32) -> DcgaEntity`
- `def dcga_point(p: SIMD[.float32, 4]) -> Array[Float32, Int(15)]`
- `def dcga_sphere(center: SIMD[.float32, 4], radius: Float32) -> DcgaEntity`
- `def dcga_torus(major: Float32, minor: Float32) -> DcgaEntity`
- `def torus_analytic(major: Float32, minor: Float32, p: SIMD[.float32, 4]) -> Real`
- aliases: `DCGA_DIM`

### `geometry/distance_field.mojo`
- trait `DistanceField3` — 0 methods
- struct `TraceHit` — 0 methods
- `def sphere_trace[F: DistanceField3](f: F, o: SIMD[.float32, 4], d: SIMD[.float32, 4], max_t: Float32, skin: Float32, scale: Float32 = 0.90000000000000002, max_steps: Int = Int(256)) -> TraceHit`

### `geometry/dualquat.mojo`
- struct `DualQuat` — 7 methods

### `geometry/epa.mojo`
- struct `EpaResult` — 1 methods
- struct `Witness` — 1 methods
- `def epa3[A: Support3, B: Support3](a: A, b: B) -> Witness[Int(3)]`
- `def epa_witness3(a: ConvexPoly[Int(3)], b: ConvexPoly[Int(3)]) -> Witness[Int(3)]`
- `def gjk_collide[dim: Int](a: ConvexPoly[dim], b: ConvexPoly[dim]) -> EpaResult[dim]`

### `geometry/field.mojo`
- trait `Field` — 0 methods
- trait `SolverField` — 0 methods
- struct `BatchReal` : Field, SolverField — 8 methods
- struct `BatchTape` — 3 methods
- struct `BatchTapeNode` — 0 methods
- struct `DualBatch` : Field, SolverField — 9 methods
- struct `DualReal` : Field, SolverField — 9 methods
- struct `DualTape` — 3 methods
- struct `DualTapeNode` — 0 methods
- struct `RealF` : Field, SolverField — 8 methods
- struct `RevBatch` : Field, SolverField — 8 methods
- struct `RevDual` : Field, SolverField — 8 methods
- struct `RevReal` : Field, SolverField — 9 methods
- struct `Tape` — 3 methods
- struct `TapeNode` — 0 methods
- `def dcos(x: DualReal) -> DualReal`
- `def dsin(x: DualReal) -> DualReal`
- `def hvp_seed(mut t: DualTape, x: Float32, direction: Float32) -> RevDual`
- `def rev_batch_seed[W: Int](mut t: BatchTape[W], v: SIMD[.float32, W]) -> RevBatch[W]`
- `def rev_seed(mut t: Tape, v: Float32) -> RevReal`
- aliases: `BatchTapePtr`, `DualTapePtr`, `TapePtr`, `V`

### `geometry/fracture_cut.mojo`
- struct `FragmentSet` — 2 methods
- `def cut_by_planes(src: Polytope, planes: List[Float64], min_volume: Float64) -> List[Polytope]`
- `def scatter_seeds(bounds: List[Float64], n: Int, rng_seed: Int, focus_x: Float64, focus_y: Float64, focus_z: Float64, focus: Float64) -> List[Float64]`
- `def voronoi_cell(src: Polytope, seeds: List[Float64], i: Int, min_volume: Float64) -> Polytope`
- `def voronoi_fracture(src: Polytope, seeds: List[Float64], part: Int, min_volume: Float64, mut out: FragmentSet)`
- `def voronoi_fracture_parts(parts: List[Polytope], seeds: List[Float64], min_volume: Float64) -> FragmentSet`

### `geometry/galie.mojo`
- struct `Screw2` — 2 methods
- struct `Screw3` — 2 methods
- `def exp_screw2(b: Screw2) -> Motor2`
- `def exp_screw3(b: Screw3) -> Motor3`
- `def geodesic2(a: Motor2, b: Motor2, t: Float32) -> Motor2`
- `def geodesic3(a: Motor3, b: Motor3, t: Float32) -> Motor3`
- `def log_motor2(m: Motor2) -> Screw2`
- `def log_motor3(m: Motor3) -> Screw3`

### `geometry/gjk.mojo`
- trait `Support3` — 0 methods
- struct `ConvexPoly` : Support3 — 4 methods
- struct `GjkHit` — 0 methods
- struct `Simplex` — 4 methods
- `def gjk_intersect[dim: Int](a: ConvexPoly[dim], b: ConvexPoly[dim]) -> Bool`
- `def gjk_query[dim: Int](a: ConvexPoly[dim], b: ConvexPoly[dim]) -> GjkHit[dim]`

### `geometry/gjk_distance.mojo`
- struct `ConvexDistance` — 0 methods
- `def convex_distance(a: List[SIMD[.float32, 4]], ra: Float32, b: List[SIMD[.float32, 4]], rb: Float32) -> ConvexDistance`
- `def support_distance[A: Support3, B: Support3](a: A, ra: Float32, b: B, rb: Float32) -> ConvexDistance`

### `geometry/gmv.mojo`
- struct `GMV` — 4 methods
- aliases: `BLADES`, `DIM`

### `geometry/inflate.mojo`
- `def inflate(d: List[UInt8], max_out: Int = Int(1073741824)) -> List[UInt8]`
- `def zlib_inflate(d: List[UInt8], max_out: Int = Int(1073741824)) -> List[UInt8]`

### `geometry/isosurface.mojo`
- struct `ScalarGrid` — 2 methods
- struct `TriMesh` — 5 methods
- `def marching_tetrahedra(g: ScalarGrid, iso: Float32) -> TriMesh`
- `def sample_sdf(sdf: Sdf3, origin: SIMD[.float32, 4], spacing: Float32, nx: Int, ny: Int, nz: Int) -> ScalarGrid`
- `def splat_particles(points: List[SIMD[.float32, 4]], radius: Float32, origin: SIMD[.float32, 4], spacing: Float32, nx: Int, ny: Int, nz: Int) -> ScalarGrid`
- `def splat_particles_anisotropic(points: List[SIMD[.float32, 4]], radius: Float32, origin: SIMD[.float32, 4], spacing: Float32, nx: Int, ny: Int, nz: Int, neighbor_radius: Float32, min_neighbors: Int = Int(25), k_r: Float32 = Float32("4"), smooth: Float32 = 0.90000000000000002) -> ScalarGrid`

### `geometry/mat.mojo`
- struct `Mat` — 6 methods
- `def affine_inverse3(mt: Mat[Int(3)]) -> Mat3`
- `def affine_inverse4(mt: Mat[Int(4)]) -> Mat4`
- `def compose_trs3(t: SIMD[.float32, 2], angle: Float32, s: SIMD[.float32, 2]) -> Mat3`
- `def transform_dir3(mt: Mat[Int(3)], v: SIMD[.float32, 2]) -> Vec2`
- `def transform_dir4(mt: Mat[Int(4)], v: SIMD[.float32, 4]) -> Vec3`
- `def transform_point3(mt: Mat[Int(3)], p: SIMD[.float32, 2]) -> Vec2`
- `def transform_point4(mt: Mat[Int(4)], p: SIMD[.float32, 4]) -> Vec3`
- `def transform_point4_simd(mt: Mat[Int(4)], p: SIMD[.float32, 4]) -> Vec3`
- aliases: `Mat2`, `Mat3`, `Mat4`, `SIZE`

### `geometry/mat3.mojo`
- struct `Mat3x3` — 12 methods
- `def sym_eigen3(a: Mat3x3) -> Tuple[SIMD[.float32, 4], Mat3x3]`

### `geometry/mesh_bake.mojo`
- struct `BakeReport` — 0 methods
- struct `BakedMesh` — 1 methods
- struct `RepairResult` — 0 methods
- `def active_edges(verts: List[Float32], idx: List[Int], angle: Float32) -> List[UInt8]`
- `def bake_collision_mesh(verts: List[Float32], idx: List[Int], weld_tol: Float32, target_tris: Int = Int(-1), max_error: Float32 = Float32("0"), active_angle: Float32 = 0.087266462599999997) -> BakedMesh`
- `def cos_approx(x: Float32) -> Real`
- `def repair(verts: List[Float32], mut idx: List[Int]) -> RepairResult`
- `def simplify(mut verts: List[Float32], mut idx: List[Int], target_tris: Int, max_error: Float32) -> Tuple[Int, Float64]`
- `def weld(verts: List[Float32], idx: List[Int], tol: Float32) -> Tuple[List[Float32], List[Int], Int]`

### `geometry/morph.mojo`
- struct `InbetweenMorph` — 3 methods
- struct `MorphSet` — 6 methods

### `geometry/motor.mojo`
- struct `Motor2` — 10 methods
- struct `Motor3` — 12 methods

### `geometry/multivector.mojo`
- struct `Multivector` : Defaultable — 12 methods
- `def gp_sign(a: Int, b: Int, p: Int, q: Int, dim: Int) -> Int`
- `def reverse_sign(a: Int) -> Int`
- `def swap_sign(a: Int, b: Int) -> Int`
- aliases: `BLADES`, `CGA3`, `DIM`, `PGA2`, `PGA3`, `PSS`

### `geometry/obb.mojo`
- struct `OBB` — 4 methods
- `def obb_collide(a: OBB, b: OBB) -> SATResult`
- `def obb_overlaps(a: OBB, b: OBB) -> Bool`

### `geometry/pip.mojo`
- `def point_in_polygon(p: SIMD[.float32, 2], poly: Polygon) -> Bool`
- `def winding_number(p: SIMD[.float32, 2], poly: Polygon) -> Int`

### `geometry/polytope.mojo`
- struct `Polytope` — 18 methods
- struct `SplitResult` — 3 methods
- `def convex_hull(pts: List[Float64]) -> Polytope`
- `def polytope_split(p: Polytope, nx: Float64, ny: Float64, nz: Float64, d: Float64, cap_tag: Int, eps: Float64) -> SplitResult`

### `geometry/pose_space.mojo`
- struct `PoseSpaceRbf` — 4 methods
- `def joint_angle(parent: Motor3, child: Motor3) -> Real`
- `def rotation_angle(m: Motor3) -> Real`
- `def twist_angle(m: Motor3, axis: SIMD[.float32, 4]) -> Real`

### `geometry/predicates.mojo`
- struct `Expansion` — 2 methods
- `def incircle(a: SIMD[.float32, 2], b: SIMD[.float32, 2], c: SIMD[.float32, 2], d: SIMD[.float32, 2]) -> Int`
- `def insphere(a: SIMD[.float32, 4], b: SIMD[.float32, 4], c: SIMD[.float32, 4], d: SIMD[.float32, 4], e: SIMD[.float32, 4]) -> Int`
- `def orient2d(a: SIMD[.float32, 2], b: SIMD[.float32, 2], c: SIMD[.float32, 2]) -> Int`
- `def orient2d_naive(a: SIMD[.float32, 2], b: SIMD[.float32, 2], c: SIMD[.float32, 2]) -> Int`
- `def orient3d(a: SIMD[.float32, 4], b: SIMD[.float32, 4], c: SIMD[.float32, 4], d: SIMD[.float32, 4]) -> Int`
- `def orient3d_naive(a: SIMD[.float32, 4], b: SIMD[.float32, 4], c: SIMD[.float32, 4], d: SIMD[.float32, 4]) -> Int`

### `geometry/quat.mojo`
- struct `Quat` — 9 methods
- `def compose_trs4(t: SIMD[.float32, 4], q: Quat, s: SIMD[.float32, 4]) -> Mat4`
- `def quat_from_mat3(m: Mat[Int(3)]) -> Quat`
- `def slerp(a: Quat, b: Quat, t: Float32) -> Quat`

### `geometry/quickhull.mojo`
- `def convex_hull_2d(points: List[SIMD[.float32, 2]], exact: Bool = True) -> Polygon`

### `geometry/ray.mojo`
- struct `Ray` — 0 methods
- struct `RayHit` — 1 methods
- `def ray_aabb[dim: Int](ray: Ray[dim], box: AABB[dim]) -> RayHit[dim]`

### `geometry/sat.mojo`
- struct `SATResult` — 1 methods
- `def sat_collide(a: Polygon, b: Polygon) -> SATResult`
- `def sat_intersect(a: Polygon, b: Polygon) -> Bool`

### `geometry/sdf.mojo`
- struct `SdfShape` — 5 methods
- `def sdf_box(p: SIMD[.float32, 2], c: SIMD[.float32, 2], half: SIMD[.float32, 2]) -> Real`
- `def sdf_circle(p: SIMD[.float32, 2], c: SIMD[.float32, 2], r: Float32) -> Real`
- `def sdf_collide(a: SdfShape, b: SdfShape) -> SATResult`
- `def sdf_intersect(a: Float32, b: Float32) -> Real`
- `def sdf_obb(p: SIMD[.float32, 2], c: SIMD[.float32, 2], half: SIMD[.float32, 2], angle: Float32) -> Real`
- `def sdf_subtract(a: Float32, b: Float32) -> Real`
- `def sdf_union(a: Float32, b: Float32) -> Real`

### `geometry/sdf3.mojo`
- struct `Sdf3` : DistanceField3 — 7 methods
- struct `SdfContact` — 0 methods
- `def sdf_contact(a: Sdf3, b: Sdf3, seed: SIMD[.float32, 4], iters: Int = Int(32)) -> SdfContact`
- aliases: `KIND_BOX`, `KIND_CAPSULE`, `KIND_PLANE`, `KIND_SPHERE`, `OP_INTERSECT`, `OP_NONE`, `OP_SUBTRACT`, `OP_UNION`

### `geometry/sdf_grid.mojo`
- struct `SdfGrid` : DistanceField3 — 5 methods
- `def bake_sdf_grid(verts: List[Float32], idx: List[Int], res: Int, pad: Float32) -> SdfGrid`
- `def bake_sdf_grid_bvh(verts: List[Float32], idx: List[Int], res: Int, pad: Float32) -> SdfGrid`
- `def closest_on_triangle(p: SIMD[.float32, 4], a: SIMD[.float32, 4], b: SIMD[.float32, 4], c: SIMD[.float32, 4]) -> Vec3`
- `def winding_number(verts: List[Float32], idx: List[Int], p: SIMD[.float32, 4]) -> Float64`

### `geometry/shape.mojo`
- trait `Intersectable` — 0 methods
- struct `Circle` : Intersectable — 1 methods
- struct `Polygon` : Sized — 2 methods
- struct `Sphere` : Intersectable — 1 methods

### `geometry/skinning.mojo`
- `def bind_palette(world: List[Motor3], inverse_bind: List[Motor3]) -> List[Motor3]`
- `def blend2(a: Motor3, b: Motor3, wa: Float32, wb: Float32) -> Motor3`
- `def blend_k(bones: List[Motor3], idx: List[Int], w: List[Float32], base: Int, k: Int) -> Motor3`
- `def blend_k_iter(bones: List[Motor3], idx: List[Int], w: List[Float32], base: Int, k: Int, iters: Int) -> Motor3`
- `def inverse_bind(bind_pose: List[Motor3]) -> List[Motor3]`
- `def skin_dib_k(bones: List[Motor3], rest: List[SIMD[.float32, 4]], idx: List[Int], w: List[Float32], k: Int, iters: Int, mut out: List[SIMD[.float32, 4]])`
- `def skin_lbs(mats: List[Mat[Int(4)]], rest: List[SIMD[.float32, 4]], idx_a: List[Int], idx_b: List[Int], w_a: List[Float32], mut out: List[SIMD[.float32, 4]])`
- `def skin_lbs_k(mats: List[Mat[Int(4)]], rest: List[SIMD[.float32, 4]], idx: List[Int], w: List[Float32], k: Int, mut out: List[SIMD[.float32, 4]])`
- `def skin_motor(bones: List[Motor3], rest: List[SIMD[.float32, 4]], idx_a: List[Int], idx_b: List[Int], w_a: List[Float32], mut out: List[SIMD[.float32, 4]])`
- `def skin_motor_k(bones: List[Motor3], rest: List[SIMD[.float32, 4]], idx: List[Int], w: List[Float32], k: Int, mut out: List[SIMD[.float32, 4]])`
- `def skin_motor_k_scaled(bones: List[Motor3], scale: List[SIMD[.float32, 4]], centre: List[SIMD[.float32, 4]], rest: List[SIMD[.float32, 4]], idx: List[Int], w: List[Float32], k: Int, mut out: List[SIMD[.float32, 4]])`

### `geometry/sparse_volume.mojo`
- struct `SparseVolume` — 5 methods
- `def decode_volume(d: List[UInt8]) -> SparseVolume`
- `def from_dense(values: List[Float32], nx: Int, ny: Int, nz: Int, background: Float32) -> SparseVolume`
- `def to_dense(vol: SparseVolume, nx: Int, ny: Int, nz: Int) -> List[Float32]`
- aliases: `LEAF`

### `geometry/spline.mojo`
- struct `ArcLengthTable` — 2 methods
- struct `BezierPath` — 5 methods
- struct `CatmullRom` — 6 methods
- struct `CubicBezier` — 3 methods
- `def build_arc_length_table[dim: Int](path: BezierPath[dim], n_samples: Int) -> ArcLengthTable`
- `def build_rmf_frames(path: BezierPath[Int(3)], table: ArcLengthTable) -> List[Motor3]`
- `def closest_point[dim: Int](path: BezierPath[dim], query: SIMD[.float32, Int(4) if (dim == Int(3)) else dim], n_coarse: Int = Int(16), newton_iters: Int = Int(8)) -> Real`
- `def frame_at_distance(frames: List[Motor3], table: ArcLengthTable, s: Float32) -> Motor3`
- aliases: `W`

### `geometry/support.mojo`
- struct `SupportBox` : Support3 — 2 methods
- struct `SupportCapsule` : Support3 — 2 methods
- struct `SupportCylinder` : Support3 — 2 methods
- struct `SupportEllipsoid` : Support3 — 3 methods

### `geometry/tetmesh.mojo`
- struct `Embedding` — 0 methods
- struct `TetMesh` — 3 methods
- `def embed(m: TetMesh, p: SIMD[.float32, 4]) -> Embedding`
- `def place(m: TetMesh, nodes: List[SIMD[.float32, 4]], e: Embedding) -> Vec3`
- `def tetrahedralize(verts: List[Float64], indices: List[Int], res: Int) -> TetMesh`

### `geometry/trig.mojo`
- `def cos[dtype: DType, width: SIMDLength, //](x: SIMD[dtype, width]) -> SIMD[dtype, width] where dtype.is_floating_point()`
- `def cosf(x: Float32) -> Float32`
- `def sin[dtype: DType, width: SIMDLength, //](x: SIMD[dtype, width]) -> SIMD[dtype, width] where dtype.is_floating_point()`
- `def sincos[dtype: DType, width: SIMDLength, //](x: SIMD[dtype, width]) -> Tuple[SIMD[dtype, width], SIMD[dtype, width]] where dtype.is_floating_point()`
- `def sinf(x: Float32) -> Float32`

### `geometry/vdb_file.mojo`
- struct `VdbGrid` — 0 methods
- `def vdb_bytes(vol: SparseVolume, name: String, voxel_size: Float64, active_mask: Bool = True) -> List[UInt8]`
- `def vdb_grid(d: List[UInt8], keep_inactive: Bool = False) -> VdbGrid`

### `geometry/vec.mojo`
- `def cross(a: SIMD[.float32, 4], b: SIMD[.float32, 4]) -> Vec3`
- `def cross[dim: Int](a: SIMD[.float32, Int(4) if (dim == Int(3)) else dim], b: SIMD[.float32, Int(4) if (dim == Int(3)) else dim]) -> SIMD[.float32, Int(4) if (dim == Int(3)) else dim]`
- `def distance_sq[w: SIMDLength, //](a: SIMD[.float32, w], b: SIMD[.float32, w]) -> Real`
- `def dot[w: SIMDLength, //](a: SIMD[.float32, w], b: SIMD[.float32, w]) -> Real`
- `def lane_max[w: SIMDLength, //](a: SIMD[.float32, w], b: SIMD[.float32, w]) -> SIMD[.float32, w]`
- `def lane_min[w: SIMDLength, //](a: SIMD[.float32, w], b: SIMD[.float32, w]) -> SIMD[.float32, w]`
- `def length[w: SIMDLength, //](a: SIMD[.float32, w]) -> Real`
- `def length_sq[w: SIMDLength, //](a: SIMD[.float32, w]) -> Real`
- `def normalize[w: SIMDLength, //](a: SIMD[.float32, w]) -> SIMD[.float32, w]`
- `def normalize_or[w: SIMDLength, //](a: SIMD[.float32, w], fallback: SIMD[.float32, w]) -> SIMD[.float32, w]`
- `def splat[d: Int](v: Float32) -> SIMD[.float32, Int(4) if (d == Int(3)) else d]`
- `def tangent_basis(n: SIMD[.float32, 4]) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def vlanes(d: Int) -> Int`
- aliases: `PadW`, `Real`, `Vec2`, `Vec3`, `WorldType`

## ecs (layer 2) — 21 modules, 77 public declarations

### `ecs/archetype.mojo`
- struct `ArchView2` — 7 methods
- struct `Archetype` — 0 methods
- struct `ArchetypeBackend` : Defaultable, StorageBackend — 18 methods
- aliases: `MAX_ARCH`, `N`, `Slot`

### `ecs/bitset_backend.mojo`
- struct `BitsetBackend` : Defaultable, StorageBackend — 15 methods
- aliases: `N`, `Slot`

### `ecs/chunked_backend.mojo`
- struct `ChunkedBackend` : Defaultable, StorageBackend — 18 methods
- aliases: `CHUNK_BYTES`, `CHUNK_ROWS`, `N`, `Slot`

### `ecs/commands.mojo`
- struct `CommandBuffer` — 4 methods
- struct `SetBuffer` — 6 methods
- aliases: `N`, `Slot`

### `ecs/component.mojo`
- trait `ComponentType` — 0 methods
- trait `SimdComponent` — 0 methods

### `ecs/entity.mojo`
- struct `Entity` : Writable — 1 methods

### `ecs/hierarchy.mojo`
- struct `Hierarchy` — 2 methods

### `ecs/host_components.mojo`
- struct `HostComponents` — 13 methods
- `def query_host[B: StorageBackend, A: ComponentType](world: World[B], hc: HostComponents, host_ids: List[Int]) -> List[Entity]`

### `ecs/motor_transform.mojo`
- struct `MotorTransform` : ComponentType — 3 methods
- `def propagate_motor[B: StorageBackend](mut w: World[B], h: Hierarchy)`
- aliases: `ID`

### `ecs/naive_backend.mojo`
- struct `NaiveBackend` : Defaultable, StorageBackend — 15 methods
- aliases: `N`, `Slot`

### `ecs/pool.mojo`
- struct `Disabled` : ComponentType — 0 methods
- struct `Pool` — 11 methods
- struct `PooledEntity` : Writable — 1 methods
- aliases: `ID`

### `ecs/reactive_backend.mojo`
- struct `ObsEvent` — 0 methods
- struct `ReactiveBackend` : Defaultable, StorageBackend — 18 methods
- aliases: `EV_ADD`, `EV_REMOVE`, `EV_SET`, `N`, `Slot`

### `ecs/relations.mojo`
- struct `RelPair` — 0 methods
- struct `RelationStore` — 7 methods

### `ecs/schema.mojo`
- struct `FieldInfo` — 0 methods
- struct `ReadReport` — 0 methods
- struct `TypeRegistry` — 4 methods
- struct `TypeSchema` — 1 methods
- `def address_of[T: AnyType](ref v: T) -> Int`
- `def read_value[T: AnyType](mut v: T, schema: TypeSchema, data: List[UInt8], mut pos: Int) -> ReadReport`
- `def read_values[T: Copyable](mut out: List[T], template: T, schema: TypeSchema, data: List[UInt8], mut pos: Int) -> ReadReport`
- `def schema_of[T: AnyType](version: Int = Int(1)) -> TypeSchema`
- `def write_value[T: AnyType](v: T, schema: TypeSchema, mut out: List[UInt8])`
- `def write_values[T: Copyable](vals: List[T], schema: TypeSchema, mut out: List[UInt8])`

### `ecs/sparse_backend.mojo`
- struct `SparseSetBackend` : Defaultable, StorageBackend — 15 methods
- aliases: `N`, `Slot`

### `ecs/sparse_set.mojo`
- struct `SparseSet` : Boolable, Defaultable, Iterable, Sized — 9 methods
- aliases: `IteratorType`

### `ecs/storage.mojo`
- trait `StorageBackend` — 0 methods
- struct `Filter` — 3 methods
- struct `Record` — 0 methods
- struct `SlotMask` — 1 methods
- `def check_pack[*CTs: ComponentType]()`
- `def resolve_filter[*CTs: ComponentType](f: Filter) -> SlotMask`

### `ecs/system.mojo`
- `def integrate2_simd[A: SimdComponent, B: SimdComponent, *CTs: ComponentType](mut backend: ArchetypeBackend[CTs], dt: Scalar[A.Dtype])`
- `def integrate_simd[A: SimdComponent, B: SimdComponent, *CTs: ComponentType](mut backend: ArchetypeBackend[CTs], dt: Scalar[A.Dtype])`
- aliases: `F`

### `ecs/transform.mojo`
- struct `Parent` : ComponentType — 0 methods
- struct `Transform` : ComponentType — 5 methods
- struct `Transform2` : ComponentType — 3 methods
- aliases: `ID`

### `ecs/transform_systems.mojo`
- `def propagate_dirty[B: StorageBackend](mut w: World[B], h: Hierarchy)`
- `def propagate_full[B: StorageBackend](mut w: World[B], h: Hierarchy)`

### `ecs/world.mojo`
- struct `World` — 26 methods

## fluid (layer 2) — 5 modules, 29 public declarations

### `fluid/d3q19.mojo`
- `def cx(i: Int) -> Int`
- `def cy(i: Int) -> Int`
- `def cz(i: Int) -> Int`
- `def equilibrium(i: Int, rho: Float32, ux: Float32, uy: Float32, uz: Float32) -> Real`
- `def opposite(i: Int) -> Int`
- `def tau_from_viscosity(nu: Float32) -> Real`
- `def viscosity_from_tau(tau: Float32) -> Real`
- `def weight(i: Int) -> Real`
- aliases: `CS2`, `INV_2CS4`, `INV_CS2`, `Q`

### `fluid/lbm.mojo`
- struct `Lbm` — 29 methods
- aliases: `BC_PERIODIC`, `BC_TUNNEL`, `CELL_FLUID`, `CELL_INLET`, `CELL_OUTLET`, `CELL_SOLID`

### `fluid/lbm_cumulant.mojo`
- struct `Lbm27` — 15 methods
- aliases: `Q27`

### `fluid/lbm_gpu.mojo`
- struct `LbmGpu` — 2 methods
- `def collide_kernel[LF: TensorLayout, LC: TensorLayout](f: TileTensor[.float32, LF, MutAnyOrigin], flag: TileTensor[.float32, LC, MutAnyOrigin], n: Int32, inv_tau: Float32, tau: Float32, force_x: Float32)`
- `def stream_kernel[LF: TensorLayout, LC: TensorLayout](f: TileTensor[.float32, LF, MutAnyOrigin], g: TileTensor[.float32, LF, MutAnyOrigin], flag: TileTensor[.float32, LC, MutAnyOrigin], nx: Int32, ny: Int32, nz: Int32, tunnel: Int32)`
- `def tunnel_kernel[LF: TensorLayout, LC: TensorLayout](f: TileTensor[.float32, LF, MutAnyOrigin], flag: TileTensor[.float32, LC, MutAnyOrigin], nx: Int32, ny: Int32, nz: Int32, inlet_u: Float32)`
- aliases: `dtype`

### `fluid/lbm_mrt.mojo`
- struct `Mrt` — 1 methods
- `def mrt_collide(mut l: Lbm, m: Mrt)`
- `def mrt_step(mut l: Lbm, m: Mrt)`

## numerics (layer 2) — 12 modules, 44 public declarations

### `numerics/bicgstab.mojo`
- `def bicgstab[Op: LinearOperator](a: Op, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0), precondition: Bool = False) -> CgResult`

### `numerics/cg.mojo`
- struct `CgResult` — 0 methods
- `def cg[Op: LinearOperator](a: Op, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0)) -> CgResult`
- `def jacobi_solve[Op: LinearOperator](a: Op, b: List[Float32], mut x: List[Float32], iters: Int) -> Real`
- `def pcg[Op: LinearOperator](a: Op, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0)) -> CgResult`

### `numerics/cholesky.mojo`
- struct `IncompleteCholesky` — 1 methods
- struct `SparseCholesky` — 3 methods
- `def pcg_ic0[Op: LinearOperator](a: Op, ic: IncompleteCholesky, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0)) -> CgResult`
- `def rcm_order(a: CsrMatrix) -> List[Int]`

### `numerics/dense.mojo`
- `def cholesky(a: List[Float32], n: Int) -> Tuple[List[Float32], Bool]`
- `def cholesky_solve(l: List[Float32], b: List[Float32], n: Int) -> List[Float32]`
- `def condition_1(a: List[Float32], n: Int) -> Float64`
- `def solve_dense(var a: List[Float32], var b: List[Float32], n: Int) -> List[Float32]`
- `def solve_dense_checked(var a: List[Float32], var b: List[Float32], n: Int, tol: Float32 = 9.9999999999999995E-7) -> List[Float32]`
- `def solve_dense_refined(a: List[Float32], b: List[Float32], n: Int, rounds: Int = Int(3)) -> Tuple[List[Float32], Float64, Float64]`

### `numerics/fft.mojo`
- `def fft(mut re: List[Float32], mut im: List[Float32], inverse: Bool = False)`
- `def fft2(mut re: List[Float32], mut im: List[Float32], n: Int, inverse: Bool = False)`
- `def is_pow2(n: Int) -> Bool`

### `numerics/gmres.mojo`
- `def gmres[Op: LinearOperator](a: Op, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0), restart: Int = Int(30), precondition: Bool = False) -> CgResult`

### `numerics/implicit.mojo`
- trait `ParamDerivative` — 0 methods
- `def implicit_gradient[Op: LinearOperator, P: ParamDerivative](a: Op, p: P, x: List[Float32], dl_dx: List[Float32], mut grad: List[Float64], tol: Float32 = 9.9999999999999995E-7, spd: Bool = True) -> CgResult`

### `numerics/minres.mojo`
- `def minres[Op: LinearOperator](a: Op, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0), precondition: Bool = False, floor: Float32 = 1.2E-4) -> CgResult`

### `numerics/multigrid.mojo`
- struct `PeriodicPoissonMG` — 1 methods
- `def pcg_mg[Op: LinearOperator](a: Op, mut mg: PeriodicPoissonMG, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0)) -> CgResult`

### `numerics/multigrid3.mojo`
- struct `PeriodicPoissonMG3` — 1 methods
- `def pcg_mg3[Op: LinearOperator](a: Op, mut mg: PeriodicPoissonMG3, b: List[Float32], mut x: List[Float32], tol: Float32 = 9.9999999999999995E-7, max_iters: Int = Int(0)) -> CgResult`

### `numerics/sparse.mojo`
- trait `LinearOperator` — 0 methods
- struct `CsrMatrix` : LinearOperator — 5 methods
- struct `ParallelCsr` : LinearOperator — 3 methods
- `def poisson_1d(n: Int, h: Float32 = Float32("1")) -> CsrMatrix`

### `numerics/vecops.mojo`
- `def axpy(alpha: Float32, x: List[Float32], mut y: List[Float32])`
- `def axpy64(alpha: Float64, x: List[Float64], mut y: List[Float64])`
- `def copy_into(src: List[Float32], mut dst: List[Float32])`
- `def dot64(a: List[Float64], b: List[Float64]) -> Float64`
- `def dot_v(a: List[Float32], b: List[Float32]) -> Real`
- `def narrow(src: List[Float64], mut dst: List[Float32])`
- `def norm2(a: List[Float32]) -> Real`
- `def norm64(a: List[Float64]) -> Float64`
- `def scale(alpha: Float32, mut x: List[Float32])`
- `def scale_add(alpha: Float32, mut x: List[Float32], y: List[Float32])`
- `def scale_add64(alpha: Float64, mut x: List[Float64], y: List[Float64])`
- `def widen(src: List[Float32], mut dst: List[Float64])`
- `def zeros(n: Int) -> List[Float32]`
- `def zeros64(n: Int) -> List[Float64]`

## procedural (layer 2) — 16 modules, 151 public declarations

### `procedural/anim.mojo`
- struct `AnimClip` — 5 methods
- struct `AnimPlayer` — 3 methods
- `def blend_bone(p0: SIMD[.float32, 4], q0: Quat, p1: SIMD[.float32, 4], q1: Quat, w: Float32, mode: Int) -> Tuple[SIMD[.float32, 4], Quat]`
- `def blend_poses(pa: List[Float32], ra: List[Float32], pb: List[Float32], rb: List[Float32], bones: Int, w: Float32, mode: Int, mut out_pos: List[Float32], mut out_rot: List[Float32])`
- `def pose_to_motors(p: List[Float32], r: List[Float32], bones: Int, mut out: List[Motor3])`
- aliases: `BLEND_DLB`, `BLEND_GEODESIC`, `BLEND_LINEAR`

### `procedural/anim_compress.mojo`
- struct `ReducedClip` — 4 methods
- `def clip_bytes(clip: AnimClip) -> Int`
- `def reduce_clip(clip: AnimClip, pos_tol: Float32, rot_tol: Float32) -> ReducedClip`

### `procedural/anim_events.mojo`
- struct `EventTrack` — 2 methods
- `def marker_phase(t: Float32, markers: List[Float32], length: Float32) -> Tuple[Int, Float32]`
- `def sync_time(t: Float32, src: List[Float32], src_len: Float32, dst: List[Float32], dst_len: Float32) -> Real`

### `procedural/anim_graph.mojo`
- struct `BlendSpace1D` — 3 methods
- struct `BlendSpace2D` — 3 methods
- struct `MotionDB` — 3 methods
- struct `Pose` — 5 methods
- struct `Skeleton` — 1 methods
- `def apply_additive(base: Pose, delta: Pose, weight: Float32) -> Pose`
- `def blend(a: Pose, b: Pose, w: Float32, mode: Int = Int(1)) -> Pose`
- `def blend_n(poses: List[Pose], weights: List[Float32], mode: Int = Int(1)) -> Pose`
- `def layer(base: Pose, over: Pose, mask: List[Float32], alpha: Float32, mode: Int = Int(1)) -> Pose`
- `def make_additive(pose: Pose, reference: Pose) -> Pose`
- `def retarget(src_pose: Pose, src: Skeleton, dst: Skeleton) -> Pose`
- `def root_motion(clip: AnimClip, root: Int, t0: Float32, t1: Float32) -> Vec3`
- `def sample_phase(clip: AnimClip, phase: Float32) -> Pose`
- `def strip_root(mut pose: Pose, root: Int, keep_vertical: Bool = True)`
- `def to_world(local: Pose, parent: List[Int]) -> Pose`

### `procedural/anim_state.mojo`
- struct `AnimGraph` — 6 methods
- struct `AnimStateDef` — 0 methods
- struct `AnimTransition` — 0 methods
- struct `Cond` — 0 methods
- aliases: `COND_FALSE`, `COND_GT`, `COND_LT`, `COND_TRIGGER`, `COND_TRUE`, `TRANS_FADE`, `TRANS_INERTIAL`

### `procedural/camera_math.mojo`
- struct `CamSpring` — 2 methods
- struct `CameraPose` — 3 methods
- struct `DollyRail` — 3 methods
- struct `Frustum` — 3 methods
- struct `Plane` — 0 methods
- struct `Shake` — 3 methods
- `def frame_targets(centers: List[SIMD[.float32, 4]], radii: List[Float32], direction: SIMD[.float32, 4], fov_y: Float32, aspect: Float32) -> Vec3`
- `def look_rotation(forward: SIMD[.float32, 4], up_hint: SIMD[.float32, 4]) -> Quat`
- `def ortho(half_w: Float32, half_h: Float32, near: Float32, far: Float32) -> Mat4`
- `def perspective(fov_y: Float32, aspect: Float32, near: Float32, far: Float32) -> Mat4`
- `def spring_damp(x: SIMD[.float32, 4], v: SIMD[.float32, 4], target: SIMD[.float32, 4], half_life: Float32, dt: Float32) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def spring_damp_quat(q: Quat, target: Quat, half_life: Float32, dt: Float32) -> Quat`
- aliases: `SPRING_MOTOR`, `SPRING_SPLIT`

### `procedural/delaunay.mojo`
- `def delaunay(pts: List[SIMD[.float32, 2]]) -> List[Int]`
- `def delaunay_walk(pts: List[SIMD[.float32, 2]]) -> List[Int]`
- `def is_delaunay(pts: List[SIMD[.float32, 2]], tri: List[Int]) -> Bool`

### `procedural/fsm.mojo`
- struct `StateMachine` — 6 methods

### `procedural/ik.mojo`
- struct `FootPlant` — 0 methods
- struct `TwoBone` — 0 methods
- `def chain_lengths(joints: List[SIMD[.float32, 4]]) -> List[Float32]`
- `def fabrik(mut joints: List[SIMD[.float32, 4]], target: SIMD[.float32, 4], iters: Int = Int(16), tol: Float32 = 1.0E-4) -> Int`
- `def fabrik_multi(mut shared: SIMD[.float32, 4], root_anchor: SIMD[.float32, 4], root_len: Float32, mut chains: List[List[SIMD[.float32, 4]]], targets: List[SIMD[.float32, 4]], iters: Int = Int(16)) -> Real`
- `def foot_plant(ankle: SIMD[.float32, 4], ankle_height: Float32, ground_y: Float32, ground_normal: SIMD[.float32, 4], max_lift: Float32, max_tilt: Float32) -> FootPlant`
- `def look_at(forward: SIMD[.float32, 4], desired: SIMD[.float32, 4], max_angle: Float32) -> Tuple[SIMD[.float32, 4], Float32]`
- `def rotate(v: SIMD[.float32, 4], axis: SIMD[.float32, 4], angle: Float32) -> Vec3`
- `def two_bone(root: SIMD[.float32, 4], mid: SIMD[.float32, 4], end: SIMD[.float32, 4], target: SIMD[.float32, 4], pole: SIMD[.float32, 4]) -> TwoBone`

### `procedural/inertialize.mojo`
- struct `Inertializer` — 3 methods
- aliases: `INERT_MOTOR`, `INERT_SPLIT`

### `procedural/levelgen.mojo`
- struct `Grid` — 4 methods
- struct `Room` — 2 methods
- `def bsp_rooms(w: Int, h: Int, min_leaf: Int, seed: Int) -> Tuple[Grid, List[Room]]`
- `def lsystem(axiom: String, rules: Dict[String, String], iterations: Int) -> String`
- `def maze(w: Int, h: Int, seed: Int) -> Grid`
- `def turtle(s: String, step: Float32, angle: Float32) -> List[SIMD[.float32, 2]]`
- `def wfc(w: Int, h: Int, adj: List[Bool], n: Int, seed: Int, max_restarts: Int = Int(20)) -> Grid`

### `procedural/noise.mojo`
- `def fbm2(x: Float32, y: Float32, seed: Int = Int(0), octaves: Int = Int(5), lacunarity: Float32 = Float32("2"), gain: Float32 = 0.5) -> Real`
- `def fbm3(x: Float32, y: Float32, z: Float32, seed: Int = Int(0), octaves: Int = Int(5), lacunarity: Float32 = Float32("2"), gain: Float32 = 0.5) -> Real`
- `def perlin2(x: Float32, y: Float32, seed: Int = Int(0)) -> Real`
- `def perlin3(x: Float32, y: Float32, z: Float32, seed: Int = Int(0)) -> Real`
- `def value3(x: Float32, y: Float32, z: Float32, seed: Int = Int(0)) -> Real`
- `def worley3(x: Float32, y: Float32, z: Float32, seed: Int = Int(0)) -> Real`

### `procedural/scatter.mojo`
- `def dart_throwing(w: Float32, h: Float32, r: Float32, seed: Int, tries: Int) -> List[SIMD[.float32, 2]]`
- `def jittered_grid(w: Float32, h: Float32, cell: Float32, jitter: Float32, seed: Int) -> List[SIMD[.float32, 2]]`
- `def min_distance(pts: List[SIMD[.float32, 2]]) -> Real`
- `def poisson_disk(w: Float32, h: Float32, r: Float32, seed: Int, k: Int = Int(30)) -> List[SIMD[.float32, 2]]`
- `def thin(pts: List[SIMD[.float32, 2]], density: List[Float32], seed: Int) -> List[SIMD[.float32, 2]]`

### `procedural/sequence.mojo`
- struct `ClipKey` — 0 methods
- struct `ClipSample` — 0 methods
- struct `ClipTrack` — 0 methods
- struct `QuatTrack` — 0 methods
- struct `ScalarTrack` — 0 methods
- struct `SeqCursor` — 4 methods
- struct `Sequence` — 15 methods
- struct `Vec3Track` — 0 methods

### `procedural/terrain_gen.mojo`
- struct `TerrainParams` — 1 methods
- `def filter_by_slope(pts: List[SIMD[.float32, 2]], h: List[Float32], nx: Int, nz: Int, cell: Float32, max_slope: Float32) -> List[SIMD[.float32, 2]]`
- `def height_tile(tx: Int, tz: Int, nx: Int, nz: Int, cell: Float32, p: TerrainParams) -> List[Float32]`
- `def hydraulic_erosion(mut h: List[Float32], nx: Int, nz: Int, droplets: Int, seed: Int, inertia: Float32 = 0.050000000000000003, capacity: Float32 = Float32("4"), min_slope: Float32 = 0.01, erode: Float32 = 0.29999999999999999, deposit: Float32 = 0.29999999999999999, evaporate: Float32 = 0.01, gravity: Float32 = Float32("4"), lifetime: Int = Int(30))`
- `def max_slope(h: List[Float32], nx: Int, nz: Int, cell: Float32) -> Real`
- `def slope_at(h: List[Float32], nx: Int, nz: Int, cell: Float32, x: Float32, z: Float32) -> Real`
- `def terrain_height(x: Float32, z: Float32, p: TerrainParams) -> Real`
- `def thermal_erosion(mut h: List[Float32], nx: Int, nz: Int, cell: Float32, talus: Float32, rate: Float32, passes: Int)`

### `procedural/tween.mojo`
- trait `Interpolator` — 0 methods
- struct `GeodesicMotor2` : Interpolator — 1 methods
- struct `GeodesicMotor3` : Interpolator — 1 methods
- struct `LerpReal` : Interpolator — 1 methods
- struct `LerpVec3` : Interpolator — 1 methods
- struct `Tween` — 6 methods
- `def ease[kind: Int](t: Float32) -> Real`
- `def ease_dyn(kind: Int, t: Float32) -> Real`
- `def lerp_real(a: Float32, b: Float32, t: Float32) -> Real`
- `def lerp_vec3(a: SIMD[.float32, 4], b: SIMD[.float32, 4], t: Float32) -> Vec3`
- aliases: `EASE_BACK_IN`, `EASE_BACK_INOUT`, `EASE_BACK_OUT`, `EASE_BOUNCE_IN`, `EASE_BOUNCE_INOUT`, `EASE_BOUNCE_OUT`, `EASE_CIRC_IN`, `EASE_CIRC_INOUT`, `EASE_CIRC_OUT`, `EASE_COUNT`, `EASE_CUBIC_IN`, `EASE_CUBIC_INOUT`, `EASE_CUBIC_OUT`, `EASE_ELASTIC_IN`, `EASE_ELASTIC_INOUT`, `EASE_ELASTIC_OUT`, `EASE_EXPO_IN`, `EASE_EXPO_INOUT`, `EASE_EXPO_OUT`, `EASE_LINEAR`, `EASE_QUAD_IN`, `EASE_QUAD_INOUT`, `EASE_QUAD_OUT`, `EASE_QUART_IN`, `EASE_QUART_INOUT`, `EASE_QUART_OUT`, `EASE_QUINT_IN`, `EASE_QUINT_INOUT`, `EASE_QUINT_OUT`, `EASE_SINE_IN`, `EASE_SINE_INOUT`, `EASE_SINE_OUT`, `PI`, `Value`

## spatial (layer 2) — 6 modules, 13 public declarations

### `spatial/bvh.mojo`
- struct `BVH` : Defaultable — 9 methods
- `def morton_order[D: Int](boxes: List[AABB[D]]) -> List[Int]`
- aliases: `SAH_BINS`

### `spatial/gpu_lbvh.mojo`
- `def bitonic_kernel[LT: TensorLayout](codes: TileTensor[.uint32, LT, MutAnyOrigin], idx: TileTensor[.uint32, LT, MutAnyOrigin], npad: Int32, k: Int32, j: Int32)`
- `def gpu_morton_order_ctx[N: Int, NPAD: Int](mut ctx: DeviceContextBase, boxes: List[AABB[Int(3)]], mut out_order: List[Int])`
- `def morton_kernel[LT: TensorLayout](cx: TileTensor[.float32, LT, MutAnyOrigin], cy: TileTensor[.float32, LT, MutAnyOrigin], cz: TileTensor[.float32, LT, MutAnyOrigin], codes: TileTensor[.uint32, LT, MutAnyOrigin], idx: TileTensor[.uint32, LT, MutAnyOrigin], n: Int32, npad: Int32, minx: Float32, miny: Float32, minz: Float32, invx: Float32, invy: Float32, invz: Float32)`
- aliases: `fdt`, `udt`

### `spatial/hash_grid.mojo`
- struct `SpatialHashGrid` — 3 methods

### `spatial/oct_tree.mojo`
- aliases: `Octree`

### `spatial/quad_tree.mojo`
- aliases: `QuadTree`

### `spatial/tree_core.mojo`
- struct `LooseTree` — 4 methods
- aliases: `CHILDREN`

## collision (layer 3) — 22 modules, 166 public declarations

### `collision/bp_bvh.mojo`
- struct `BVHBroadPhase` : BroadPhase, Defaultable — 3 methods
- aliases: `dim`

### `collision/bp_dbvh.mojo`
- struct `DbvhBroadPhase` : BroadPhase, Defaultable — 3 methods
- aliases: `dim`

### `collision/bp_gpu.mojo`
- `def gpu_pairs_ctx[N: Int, CAP: Int](mut ctx: DeviceContextBase, items: List[BoxProxy[Int(3)]], mut out: List[Pair]) -> Bool`
- `def pair_kernel[LT: TensorLayout, ILT: TensorLayout, CLT: TensorLayout](lox: TileTensor[.float32, LT, MutAnyOrigin], loy: TileTensor[.float32, LT, MutAnyOrigin], loz: TileTensor[.float32, LT, MutAnyOrigin], hix: TileTensor[.float32, LT, MutAnyOrigin], hiy: TileTensor[.float32, LT, MutAnyOrigin], hiz: TileTensor[.float32, LT, MutAnyOrigin], out_a: TileTensor[.int32, ILT, MutAnyOrigin], out_b: TileTensor[.int32, ILT, MutAnyOrigin], cursor: TileTensor[.int32, CLT, MutAnyOrigin], n: Int32, cap: Int32)`
- aliases: `fdt`, `idt`

### `collision/bp_hashgrid.mojo`
- struct `SpatialHashBroadPhase` : BroadPhase, Defaultable — 3 methods
- aliases: `dim`

### `collision/bp_sap.mojo`
- struct `SapBroadPhase` : BroadPhase, Defaultable — 3 methods
- aliases: `dim`

### `collision/bp_tree.mojo`
- struct `TreeBroadPhase` : BroadPhase, Defaultable — 3 methods
- aliases: `OctreeBroadPhase`, `QuadTreeBroadPhase`, `dim`

### `collision/broadphase.mojo`
- trait `BroadPhase` — 0 methods
- struct `BoxProxy` — 0 methods
- struct `BruteForce` : BroadPhase, Defaultable — 3 methods
- struct `Pair` — 0 methods
- aliases: `dim`

### `collision/clip.mojo`
- struct `ClipEdge` — 1 methods
- `def best_edge(p: Polygon, n: SIMD[.float32, 2]) -> ClipEdge`
- `def clip_manifold(a: Polygon, b: Polygon, normal: SIMD[.float32, 2], mut pts: List[SIMD[.float32, 2]], mut depths: List[Float32]) -> Bool`

### `collision/collider_set.mojo`
- struct `ColliderSet` — 50 methods
- struct `CompoundSpec` : Sized — 6 methods
- struct `Pose3` — 0 methods
- struct `ShapeDesc` — 0 methods
- `def support_manifold[A: Support3, B: Support3](a: A, b: B, margin: Float32) -> ContactManifold[Int(3)]`
- aliases: `COMPOUND_MAX_CHILDREN`, `SHAPE_BOX`, `SHAPE_CAPSULE`, `SHAPE_COMPOUND`, `SHAPE_ELLIPSOID`, `SHAPE_HEIGHTFIELD`, `SHAPE_HULL`, `SHAPE_SDF`, `SHAPE_SPHERE`, `SHAPE_TRIMESH`, `SPEC_BASE`

### `collision/contact_events.mojo`
- struct `ContactEvent` — 0 methods
- `def diff_events(cur: List[Int], prev: List[Int], mut out: List[ContactEvent])`
- `def impacts(events: List[ContactEvent], min_impulse: Float32) -> List[ContactEvent]`
- `def pack_key(a: Int, b: Int, feat: Int) -> Int`
- aliases: `EV_BEGAN`, `EV_ENDED`, `EV_STAY`

### `collision/contact_gen.mojo`
- struct `RawContact` — 0 methods
- `def capsule_triangle_manifold(p0: SIMD[.float32, 4], p1: SIMD[.float32, 4], r: Float32, margin: Float32, v0: SIMD[.float32, 4], v1: SIMD[.float32, 4], v2: SIMD[.float32, 4], face_n: SIMD[.float32, 4]) -> ContactManifold[Int(3)]`
- `def collect_bp_pairs[BP: BroadPhase](mut bp: BP, boxes: List[AABB[BP.dim]], statics: List[Bool], mut out: List[Pair], skip: List[Bool] = List())`
- `def speculative_margin(vel_a: SIMD[.float32, 4], vel_b: SIMD[.float32, 4], spec_dt: Float32, base: Float32 = 0.02) -> Real`
- `def sphere_triangle_manifold(c: SIMD[.float32, 4], r: Float32, margin: Float32, v0: SIMD[.float32, 4], v1: SIMD[.float32, 4], v2: SIMD[.float32, 4], face_n: SIMD[.float32, 4]) -> ContactManifold[Int(3)]`
- `def try_compound_pair(colliders: ColliderSet, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, margin: Float32, mut out: List[RawContact])`
- `def try_mesh_pair(colliders: ColliderSet, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, margin: Float32, mut out: List[RawContact])`
- `def try_pair(colliders: ColliderSet, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, vel_i: SIMD[.float32, 4], vel_j: SIMD[.float32, 4], spec_dt: Float32, mut out: List[RawContact], mut sensors: List[RawContact], margin_base: Float32 = 0.02)`
- `def try_sdf_pair(colliders: ColliderSet, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, margin: Float32, mut out: List[RawContact])`

### `collision/gpu_narrow.mojo`
- struct `GpuNarrow` — 1 methods
- `def narrow_kernel(inp: Pointer[Float32, MutAnyOrigin], res: Pointer[Float32, MutAnyOrigin], count: Int32)`

### `collision/gpu_raycast.mojo`
- `def gpu_raycast_ctx[NB: Int, NR: Int](mut ctx: DeviceContextBase, items: List[BoxProxy[Int(3)]], rays: List[Ray[Int(3)]], mut out_proxy: List[Int], mut out_t: List[Float32], max_t: Float32)`
- `def raycast_kernel[BLT: TensorLayout, RLT: TensorLayout](blox: TileTensor[.float32, BLT, MutAnyOrigin], bloy: TileTensor[.float32, BLT, MutAnyOrigin], bloz: TileTensor[.float32, BLT, MutAnyOrigin], bhix: TileTensor[.float32, BLT, MutAnyOrigin], bhiy: TileTensor[.float32, BLT, MutAnyOrigin], bhiz: TileTensor[.float32, BLT, MutAnyOrigin], rox: TileTensor[.float32, RLT, MutAnyOrigin], roy: TileTensor[.float32, RLT, MutAnyOrigin], roz: TileTensor[.float32, RLT, MutAnyOrigin], rdx: TileTensor[.float32, RLT, MutAnyOrigin], rdy: TileTensor[.float32, RLT, MutAnyOrigin], rdz: TileTensor[.float32, RLT, MutAnyOrigin], out_p: TileTensor[.int32, RLT, MutAnyOrigin], out_t: TileTensor[.float32, RLT, MutAnyOrigin], nb: Int32, nr: Int32, max_t: Float32)`
- aliases: `fdt`, `idt`

### `collision/hull.mojo`
- struct `HullShape` — 8 methods
- `def hull_manifold(a_in: ConvexPoly[Int(3)], b_in: ConvexPoly[Int(3)], faces_a: List[Float32], faces_b: List[Float32], margin: Float32 = Float32("0")) -> ContactManifold[Int(3)]`

### `collision/manifold.mojo`
- trait `ManifoldNarrowPhase` — 0 methods
- struct `AABBManifoldNarrowPhase` : ManifoldNarrowPhase — 2 methods
- struct `ContactManifold` — 5 methods
- struct `GjkManifoldNarrowPhase` : ManifoldNarrowPhase — 2 methods
- struct `OBBManifoldNarrowPhase` : ManifoldNarrowPhase — 2 methods
- struct `SATManifoldNarrowPhase` : ManifoldNarrowPhase — 3 methods
- `def box_box_manifold(ca: SIMD[.float32, 4], axa: Array[SIMD[.float32, 4], Int(3)], ha: SIMD[.float32, 4], cb: SIMD[.float32, 4], axb: Array[SIMD[.float32, 4], Int(3)], hb: SIMD[.float32, 4]) -> ContactManifold[Int(3)]`
- `def capsule_box_manifold(cc: SIMD[.float32, 4], cax: SIMD[.float32, 4], hl: Float32, r: Float32, cb: SIMD[.float32, 4], axb: Array[SIMD[.float32, 4], Int(3)], hb: SIMD[.float32, 4]) -> ContactManifold[Int(3)]`
- `def capsule_capsule_manifold(ca: SIMD[.float32, 4], axa: SIMD[.float32, 4], ha: Float32, ra: Float32, cb: SIMD[.float32, 4], axb: SIMD[.float32, 4], hb: Float32, rb: Float32) -> ContactManifold[Int(3)]`
- `def capsule_sphere_manifold(cc: SIMD[.float32, 4], cax: SIMD[.float32, 4], hl: Float32, r: Float32, cs: SIMD[.float32, 4], rs: Float32) -> ContactManifold[Int(3)]`
- `def sphere_box_manifold(cs: SIMD[.float32, 4], r: Float32, cb: SIMD[.float32, 4], axb: Array[SIMD[.float32, 4], Int(3)], hb: SIMD[.float32, 4]) -> ContactManifold[Int(3)]`
- `def sphere_sphere_manifold(ca: SIMD[.float32, 4], ra: Float32, cb: SIMD[.float32, 4], rb: Float32) -> ContactManifold[Int(3)]`
- `def spread4(pts: List[SIMD[.float32, 4]], dep: List[Float32], n: SIMD[.float32, 4]) -> List[Int]`
- `def spread4_core(pts: Span[SIMD[.float32, 4]], dep: Span[Float32], c: Int, n: SIMD[.float32, 4]) -> Tuple[Array[Int, Int(4)], Int]`
- aliases: `Axes3`, `MAX`, `dim`

### `collision/narrow_batch.mojo`
- struct `NarrowBatch` — 4 methods
- `def is_batchable(kind: Int) -> Bool`
- `def narrow_pair(inp: Pointer[Float32, MutAnyOrigin], res: Pointer[Float32, MutAnyOrigin], k: Int)`
- aliases: `FPtr`, `OUT_STRIDE`, `O_COUNT`, `O_HIT`, `O_NORMAL`, `O_POINTS`, `PAIR_STRIDE`, `P_AX_A`, `P_AX_B`, `P_HALF_A`, `P_HALF_B`, `P_INFL`, `P_KA`, `P_KB`, `P_MR`, `P_POS_A`, `P_POS_B`

### `collision/narrowphase.mojo`
- trait `NarrowPhase` — 0 methods
- struct `AABBNarrowPhase` : NarrowPhase — 2 methods
- struct `CgaShapeNarrowPhase` : NarrowPhase — 3 methods
- struct `CgaSphereNarrowPhase` : NarrowPhase — 2 methods
- struct `CircleNarrowPhase` : NarrowPhase — 2 methods
- struct `Contact` — 1 methods
- struct `GJKNarrowPhase` : NarrowPhase — 2 methods
- struct `OBBNarrowPhase` : NarrowPhase — 2 methods
- struct `SATNarrowPhase` : NarrowPhase — 3 methods
- struct `SDFNarrowPhase` : NarrowPhase — 2 methods
- aliases: `dim`

### `collision/pipeline.mojo`
- struct `CollisionPipeline` — 1 methods
- struct `Manifold` — 0 methods

### `collision/queries.mojo`
- trait `SceneQuery` — 0 methods
- struct `BruteForceQuery` : Defaultable, SceneQuery — 3 methods
- struct `BvhQuery` : Defaultable, SceneQuery — 3 methods
- struct `GridQuery` : Defaultable, SceneQuery — 3 methods
- struct `TreeQuery` : Defaultable, SceneQuery — 3 methods
- aliases: `dim`

### `collision/toi.mojo`
- struct `ToiResult` — 0 methods
- `def swept_box_toi(ca: SIMD[.float32, 4], axa: Array[SIMD[.float32, 4], Int(3)], ha: SIMD[.float32, 4], cb: SIMD[.float32, 4], axb: Array[SIMD[.float32, 4], Int(3)], hb: SIMD[.float32, 4], rel_disp: SIMD[.float32, 4]) -> ToiResult`

### `collision/trimesh.mojo`
- struct `HeightField` — 14 methods
- struct `TriMesh` — 9 methods
- `def closest_point_on_triangle(p: SIMD[.float32, 4], a: SIMD[.float32, 4], b: SIMD[.float32, 4], c: SIMD[.float32, 4]) -> Vec3`

### `collision/world_query.mojo`
- struct `Hit` — 1 methods
- struct `Penetration` — 0 methods
- struct `Probe` — 0 methods
- struct `QueryFilter` — 3 methods
- struct `QueryIndex` — 2 methods
- struct `QueryShape` — 6 methods
- `def capsule_cast(cs: ColliderSet, poses: List[Pose3], a: SIMD[.float32, 4], b: SIMD[.float32, 4], r: Float32, dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Hit`
- `def capsule_penetrations(cs: ColliderSet, poses: List[Pose3], a: SIMD[.float32, 4], b: SIMD[.float32, 4], r: Float32, f: QueryFilter) -> List[Penetration]`
- `def closest_points(cs: ColliderSet, poses: List[Pose3], i: Int, j: Int, search: Float32 = 1.0E+30) -> ConvexDistance`
- `def desc_distance(cs: ColliderSet, da: ShapeDesc, pa: Pose3, db: ShapeDesc, pb: Pose3) -> ConvexDistance`
- `def kid_distance[A: Support3](cs: ColliderSet, a: A, ra: Float32, d: ShapeDesc, pose: Pose3) -> ConvexDistance`
- `def nearest_surface(cs: ColliderSet, poses: List[Pose3], p: SIMD[.float32, 4], f: QueryFilter, search: Float32 = 1) -> Tuple[Int, Probe]`
- `def overlap_capsule(cs: ColliderSet, poses: List[Pose3], a: SIMD[.float32, 4], b: SIMD[.float32, 4], r: Float32, f: QueryFilter) -> List[Int]`
- `def overlap_shape(cs: ColliderSet, poses: List[Pose3], shape: QueryShape, pose: Pose3, f: QueryFilter) -> List[Int]`
- `def overlap_sphere(cs: ColliderSet, poses: List[Pose3], c: SIMD[.float32, 4], r: Float32, f: QueryFilter) -> List[Int]`
- `def point_distance(cs: ColliderSet, i: Int, pose: Pose3, p: SIMD[.float32, 4], search: Float32 = 1.0E+30) -> Probe`
- `def pose3_of(position: SIMD[.float32, 4], q: Quat) -> Pose3`
- `def ray_cast(cs: ColliderSet, poses: List[Pose3], origin: SIMD[.float32, 4], dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Hit`
- `def ray_cast_all(cs: ColliderSet, poses: List[Pose3], origin: SIMD[.float32, 4], dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter, max_hits: Int = Int(64)) -> List[Hit]`
- `def ray_cast_any(cs: ColliderSet, poses: List[Pose3], origin: SIMD[.float32, 4], dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Bool`
- `def ray_cast_batch(cs: ColliderSet, poses: List[Pose3], origins: List[SIMD[.float32, 4]], dirs: List[SIMD[.float32, 4]], max_t: Float32, f: QueryFilter) -> List[Hit]`
- `def ray_cast_indexed(cs: ColliderSet, idx: QueryIndex, origin: SIMD[.float32, 4], dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Hit`
- `def ray_collider(cs: ColliderSet, i: Int, pose: Pose3, origin: SIMD[.float32, 4], dir: SIMD[.float32, 4], max_t: Float32, backfaces: Bool = True) -> Hit`
- `def segment_distance(cs: ColliderSet, i: Int, pose: Pose3, a: SIMD[.float32, 4], b: SIMD[.float32, 4], search: Float32 = 1.0E+30) -> Tuple[Probe, SIMD[.float32, 4]]`
- `def shape_cast(cs: ColliderSet, poses: List[Pose3], shape: QueryShape, pose: Pose3, dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Hit`
- `def shape_distance(cs: ColliderSet, i: Int, pose: Pose3, pts: List[SIMD[.float32, 4]], r: Float32, search: Float32 = 1.0E+30) -> Tuple[ConvexDistance, Int]`
- `def shape_penetrations(cs: ColliderSet, poses: List[Pose3], shape: QueryShape, pose: Pose3, f: QueryFilter) -> List[Penetration]`
- `def sphere_cast(cs: ColliderSet, poses: List[Pose3], c: SIMD[.float32, 4], r: Float32, dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Hit`

## nav (layer 3) — 6 modules, 44 public declarations

### `nav/crowd.mojo`
- trait `Avoidance` — 0 methods
- struct `Crowd` : Sized — 5 methods
- struct `CrowdParams` — 1 methods
- struct `Line` — 0 methods
- struct `Orca` : Avoidance — 1 methods
- struct `SampledRvo` : Avoidance — 1 methods
- struct `SocialForce` : Avoidance — 1 methods
- aliases: `WEIGHT_RVO`

### `nav/heightfield.mojo`
- struct `CompactField` — 6 methods
- struct `Heightfield` — 2 methods
- struct `NavBakeConfig` — 5 methods
- `def dir_dx(d: Int) -> Int`
- `def dir_dz(d: Int) -> Int`
- `def erode(mut f: CompactField, radius_cells: Int)`
- `def erode_window(mut f: CompactField, radius_cells: Int, wx0: Int, wz0: Int, wx1: Int, wz1: Int)`
- `def filter_low_hanging(mut hf: Heightfield, cfg: NavBakeConfig)`
- `def filter_low_height(mut hf: Heightfield, cfg: NavBakeConfig)`
- `def rasterize(mut hf: Heightfield, verts: List[SIMD[.float32, 4]], tris: List[Int], cfg: NavBakeConfig)`
- aliases: `DIR_DX`, `DIR_DZ`

### `nav/hpa.mojo`
- struct `HierFunnel` : PathFinder — 1 methods
- struct `HpaGraph` — 2 methods

### `nav/navmesh.mojo`
- struct `NavMesh` — 16 methods
- `def bake_navmesh(verts: List[SIMD[.float32, 4]], tris: List[Int], cfg: NavBakeConfig) -> NavMesh`
- `def dist3(a: SIMD[.float32, 4], b: SIMD[.float32, 4]) -> Real`

### `nav/path.mojo`
- trait `PathFinder` — 0 methods
- struct `FlowField` — 3 methods
- struct `FlowFieldPath` : PathFinder — 1 methods
- struct `GridAStar` : PathFinder — 1 methods
- struct `MinHeap` : Sized — 3 methods
- struct `NavPath` — 2 methods
- struct `PolyFunnel` : PathFinder — 2 methods
- `def smooth_path(mesh: NavMesh, path: NavPath) -> NavPath`
- `def string_pull(lefts: List[SIMD[.float32, 4]], rights: List[SIMD[.float32, 4]], mut out: NavPath, flag_last: Int)`
- aliases: `PATH_OFFMESH`, `PATH_WALK`

### `nav/volume.mojo`
- trait `VolumeFinder` — 0 methods
- struct `SmoothedVoxelAStar` : VolumeFinder — 1 methods
- struct `SvoAStar` : VolumeFinder — 1 methods
- struct `VolumeConfig` — 1 methods
- struct `VolumeNav` — 12 methods
- struct `VoxelAStar` : VolumeFinder — 1 methods
- `def portal(vol: VolumeNav, a: Int, b: Int) -> Vec3`
- `def smooth_volume(vol: VolumeNav, path: NavPath) -> NavPath`

## scheduler (layer 3) — 15 modules, 63 public declarations

### `scheduler/build_opts.mojo`
- aliases: `SERIAL_ONLY`

### `scheduler/dispatch.mojo`
- trait `Task` — 0 methods
- struct `Dispatch` — 5 methods
- `def dispatch_for[T: Task](d: Dispatch, mut task: T, n: Int, workers: Int = Int(0))`
- aliases: `DISPATCH_HOST`, `DISPATCH_PARALLEL`, `DISPATCH_REVERSE`, `DISPATCH_SERIAL`, `DISPATCH_WORK_STEALING`, `HostParallelFor`, `Opaque`, `TaskFn`

### `scheduler/entity_actor.mojo`
- trait `EntityHandler` — 0 methods
- struct `EntityActorScheduler` : Defaultable, Scheduler — 1 methods
- aliases: `B`, `MAX_ROUNDS`

### `scheduler/events.mojo`
- trait `EventChannel` — 0 methods
- struct `Channel` : Defaultable, EventChannel — 5 methods
- struct `PushChannel` : Defaultable, EventChannel — 4 methods
- aliases: `EventPayload`, `Payload`

### `scheduler/gameloop.mojo`
- struct `FixedLoop` — 2 methods

### `scheduler/jobgraph.mojo`
- trait `DeclaredSystem` — 0 methods
- struct `JobGraphScheduler` : Defaultable, Scheduler — 4 methods
- `def conflicts(rw_a: Tuple[UInt64, UInt64], rw_b: Tuple[UInt64, UInt64]) -> Bool`
- aliases: `B`

### `scheduler/message.mojo`
- trait `MessageType` — 0 methods
- struct `Envelope` — 0 methods
- `def empty_envelopes[M: MessageType](n: Int) -> List[List[Envelope[M]]]`
- `def empty_inboxes[M: MessageType](n: Int) -> List[List[M]]`
- `def has_messages[M: MessageType](inboxes: List[List[M]]) -> Bool`

### `scheduler/policy.mojo`
- trait `DispatchPolicy` — 0 methods
- struct `Parallel` : DispatchPolicy — 1 methods
- struct `Serial` : DispatchPolicy — 1 methods
- aliases: `PARALLEL`

### `scheduler/rng.mojo`
- trait `Rng` — 0 methods
- struct `Pcg32` : Defaultable, Rng — 4 methods
- struct `SplitMix64` : Defaultable, Rng — 3 methods
- struct `XorShift64` : Defaultable, Rng — 3 methods
- `def range_f[R: Rng](mut r: R, lo: Float32, hi: Float32) -> Float32`
- `def range_i[R: Rng](mut r: R, lo: Int, hi: Int) -> Int`
- `def unit_vec2[R: Rng](mut r: R) -> Vec2`
- `def unit_vec3[R: Rng](mut r: R) -> Vec3`

### `scheduler/scheduler.mojo`
- trait `Scheduler` — 0 methods
- trait `System` — 0 methods

### `scheduler/sequential.mojo`
- struct `SequentialScheduler` : Defaultable, Scheduler — 1 methods
- aliases: `B`

### `scheduler/system_actor.mojo`
- trait `ActorSystem` — 0 methods
- struct `SystemActorScheduler` : Defaultable, Scheduler — 1 methods
- aliases: `B`, `K`, `M`, `MAX_ROUNDS`

### `scheduler/tiered.mojo`
- struct `TieredScheduler` : Defaultable, Scheduler — 2 methods
- aliases: `B`

### `scheduler/timers.mojo`
- trait `TimerQueue` — 0 methods
- struct `TimerFire` — 0 methods
- struct `TimerHandle` : Writable — 1 methods
- struct `TimerHeap` : Defaultable, TimerQueue — 4 methods
- struct `TimerWheel` : Defaultable, TimerQueue — 4 methods

### `scheduler/workstealing.mojo`
- `def ws_parallel_for[BodyT: def(Int) -> None](body: BodyT, n: Int, workers: Int)`

## ai (layer 4) — 10 modules, 76 public declarations

### `ai/blackboard.mojo`
- struct `Blackboard` : Sized — 9 methods
- aliases: `CMP_EQ`, `CMP_FALSE`, `CMP_GE`, `CMP_GT`, `CMP_LE`, `CMP_LT`, `CMP_NE`, `CMP_SET`, `CMP_TRUE`, `CMP_UNSET`

### `ai/bt.mojo`
- trait `BtHost` — 0 methods
- struct `BehaviorTree` : Sized — 16 methods
- struct `BtState` — 0 methods
- `def bt_tick[H: BtHost](tree: BehaviorTree, mut st: BtState, mut host: H, agent: Int, mut bb: Blackboard) -> Int`
- aliases: `BT_ACTION`, `BT_CHECK`, `BT_CONDITION`, `BT_COOLDOWN`, `BT_GUARD`, `BT_INVERTER`, `BT_PARALLEL`, `BT_REPEAT`, `BT_SELECTOR`, `BT_SEQUENCE`, `BT_SERVICE`, `BT_SUCCEEDER`, `BT_WAIT`, `FAILURE`, `RUNNING`, `SUCCESS`

### `ai/decision.mojo`
- trait `Decider` — 0 methods
- struct `BtDecider` : Decider — 1 methods
- struct `Cond` — 0 methods
- struct `Fact` — 0 methods
- struct `FsmDecider` : Decider — 3 methods
- struct `Goal` — 0 methods
- struct `GoapDecider` : Decider — 3 methods
- struct `UtilityDecider` : Decider — 1 methods

### `ai/eqs.mojo`
- struct `EnvQuery` : Sized — 10 methods

### `ai/influence.mojo`
- struct `InfluenceMap` — 11 methods
- struct `TeamVision` — 4 methods

### `ai/perception.mojo`
- struct `Memory` — 0 methods
- struct `Perception` — 12 methods
- struct `SenseConfig` — 1 methods
- aliases: `SENSE_HEARING`, `SENSE_SIGHT`

### `ai/planner.mojo`
- struct `Goap` — 2 methods
- struct `Htn` — 4 methods
- struct `Op` — 2 methods
- aliases: `TASK_COMPOUND`, `TASK_PRIMITIVE`

### `ai/smart_objects.mojo`
- struct `SmartObjects` — 9 methods
- aliases: `SLOT_FREE`, `SLOT_OCCUPIED`, `SLOT_RESERVED`

### `ai/steering.mojo`
- struct `Flock` : Sized — 3 methods
- struct `FlockParams` — 0 methods
- struct `Formation` — 2 methods
- `def arrive(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], target: SIMD[.float32, 4], max_speed: Float32, slow_radius: Float32) -> Vec3`
- `def evade(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], threat: SIMD[.float32, 4], threat_vel: SIMD[.float32, 4], max_speed: Float32) -> Vec3`
- `def flee(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], threat: SIMD[.float32, 4], max_speed: Float32) -> Vec3`
- `def follow_path(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], path: List[SIMD[.float32, 4]], look_ahead: Float32, max_speed: Float32) -> Vec3`
- `def pursue(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], quarry: SIMD[.float32, 4], quarry_vel: SIMD[.float32, 4], max_speed: Float32) -> Vec3`
- `def seek(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], target: SIMD[.float32, 4], max_speed: Float32) -> Vec3`
- `def wander(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], mut angle: Float32, mut rng: UInt64, max_speed: Float32, dist: Float32, radius: Float32, jitter: Float32) -> Vec3`
- aliases: `FORMATION_COLUMN`, `FORMATION_LINE`, `FORMATION_WEDGE`

### `ai/utility.mojo`
- struct `Consideration` — 1 methods
- struct `UtilityAI` — 4 methods
- aliases: `CURVE_LINEAR`, `CURVE_LOGISTIC`, `CURVE_POLY`, `CURVE_STEP`, `CURVE_STEP_BELOW`

## physics (layer 4) — 89 modules, 503 public declarations

### `physics/actuator.mojo`
- struct `Actuator` — 7 methods
- struct `ActuatorBank` — 5 methods
- struct `HillParams` — 6 methods
- aliases: `DYN_FILTER`, `DYN_MUSCLE`, `DYN_NONE`

### `physics/adjoint.mojo`
- `def adjoint_program[prog: List[Int], nreg: Int](mut adj: Array[Float32, nreg], consts: Array[Float32, Int(6)], bits: List[Bool], bit_end: Int)`
- `def concat(parts: List[List[Int]]) -> List[Int]`
- `def eval_program[prog: List[Int], nreg: Int](mut reg: Array[Float32, nreg], consts: Array[Float32, Int(6)], mut bits: List[Bool])`
- `def marks_before(prog: List[Int], upto: Int) -> Int`
- `def op(code: Int, dst: Int, a: Int, b: Int) -> List[Int]`
- `def program_is_linear(prog: List[Int]) -> Bool`
- `def program_marks(prog: List[Int]) -> Int`
- `def rollout_generated(u: List[Float32], burst: Int, dt: Float32, mut grad: List[Float32], seed: Int = Int(0)) -> Tuple[Float32, Float32]`
- `def step_consts(dt: Float32) -> Array[Float32, Int(6)]`
- aliases: `C_CDT1`, `C_DRAG1`, `C_DT`, `C_GDT`, `C_KDT`, `C_NEGKDT`, `NREG`, `OP_ADD`, `OP_ADDC`, `OP_MARK`, `OP_MOV`, `OP_MUL`, `OP_MULC`, `OP_SELECT`, `OP_SUB`, `R_VX`, `R_VY`, `R_X`, `R_Y`, `STEP_BITS`, `STEP_IS_LINEAR`, `STEP_PROGRAM`

### `physics/artic_batch.mojo`
- struct `ArticBatch` — 7 methods
- `def aba_instance(model: Pointer[Float32, MutAnyOrigin], parent: Pointer[Int32, MutAnyOrigin], n: Int, state: Pointer[Float32, MutAnyOrigin], qdd: Pointer[Float32, MutAnyOrigin], ws: Pointer[Float32, MutAnyOrigin], gravity: SIMD[.float32, 4])`
- `def artic_step_instance(model: Pointer[Float32, MutAnyOrigin], parent: Pointer[Int32, MutAnyOrigin], n: Int, state: Pointer[Float32, MutAnyOrigin], qdd: Pointer[Float32, MutAnyOrigin], ws: Pointer[Float32, MutAnyOrigin], gravity: SIMD[.float32, 4], dt: Float32)`
- aliases: `FPtr`, `IPtr`, `MODEL_STRIDE`, `M_AXIS`, `M_COM`, `M_IDIAG`, `M_KIND`, `M_MASS`, `M_PIVOT`, `WS`, `W_AV`, `W_AW`, `W_CV`, `W_CW`, `W_D`, `W_IA`, `W_PV`, `W_PW`, `W_Q`, `W_U`, `W_UV`, `W_UW`, `W_V`, `W_W`

### `physics/body_set.mojo`
- struct `BodyId` : Equatable, Writable — 2 methods
- struct `BodySet` : Sized — 17 methods
- aliases: `MOTION_DYNAMIC`, `MOTION_KINEMATIC`, `MOTION_REMOVED`, `MOTION_STATIC`

### `physics/capture.mojo`
- struct `Capture` — 5 methods
- struct `CaptureFrame` — 1 methods
- struct `CaptureReader` — 3 methods
- `def draw_frame(f: CaptureFrame, mut q: DrawQueue[.float32], arrow: Float32 = 0.14999999999999999, life: Int = Int(0))`
- `def verify(rd: CaptureReader, start: Int, frames: Int, dt: Float32, gravity: SIMD[.float32, 4], cfg: SolverConfig) -> Int`
- aliases: `CAPTURE_MAGIC`, `CAPTURE_VERSION`

### `physics/ccd6.mojo`
- `def ca_fraction[B: Body6](bset: BodySet[B], cs: ColliderSet, i: Int, j: Int, h: Float32) -> Real`
- `def ccd_advance[B: Body6](mut bset: BodySet[B], colliders: ColliderSet, h: Float32, all_bodies: Bool = True, par: Bool = False, workers: Int = Int(0), dispatch: Dispatch = Dispatch.parallel())`
- `def ccd_advance_island[B: Body6](mut bset: BodySet[B], colliders: ColliderSet, h: Float32, all_bodies: Bool, members: List[Int], mlo: Int, mhi: Int)`
- aliases: `CCD_AUTO`, `CCD_BULLET`, `CCD_OFF`, `CCD_PAR_MIN`

### `physics/chain.mojo`
- struct `BallLimit` — 0 methods
- struct `Chain` — 34 methods
- struct `ChainLink` — 4 methods
- struct `SpInertia` — 2 methods
- `def read_chain[R: StateReader](mut r: R) -> Chain`
- `def write_chain[W: StateWriter](ch: Chain, mut out: W)`
- aliases: `JOINT_PRISMATIC`, `JOINT_REVOLUTE`

### `physics/chain_scene.mojo`
- `def couple_contacts[B: Body6](mut ch: Chain, mut sc: ContactScene6[B], contacts: List[Int], locals: List[SIMD[.float32, 4]], dt: Float32, mu: Float32 = Float32("0"), iters: Int = Int(8)) -> Tuple[Int, SIMD[.float32, 4]]`

### `physics/chain_shapes.mojo`
- struct `LinkCapsule` — 0 methods
- `def resolve_shape_contacts(mut ch: Chain, world: ColliderSet, poses: List[Pose3], shapes: List[LinkCapsule], dt: Float32, self_collide: Bool = True, iters: Int = Int(8)) -> Int`

### `physics/cloth.mojo`
- struct `ClothHit` — 0 methods
- struct `MeshCloth` : ContinuumSolver — 17 methods
- `def grid_mesh(nx: Int, nz: Int, size_x: Float32, size_z: Float32, origin: SIMD[.float32, 4]) -> Tuple[List[Float32], List[Int]]`
- aliases: `BEND_CROSS_EDGE`, `BEND_DIHEDRAL`

### `physics/cloth_air.mojo`
- struct `ClothAir` — 3 methods
- `def lattice_corners(l: Lbm, origin: SIMD[.float32, 4], dx: Float32, p: SIMD[.float32, 4]) -> Tuple[List[Int], List[Float32]]`
- `def lattice_momentum(l: Lbm, rho: Float32, dx: Float32, dt: Float32) -> Vec3`
- `def lattice_velocity(l: Lbm, origin: SIMD[.float32, 4], dx: Float32, dt: Float32, p: SIMD[.float32, 4]) -> Vec3`

### `physics/cloth_air_parts.mojo`
- struct `AirPart` : CoupledPart — 8 methods
- struct `BallPart` : CoupledPart — 8 methods
- struct `ClothPart` : CoupledPart — 8 methods
- struct `GrainPart` : CoupledPart — 8 methods
- struct `SoftPart` : CoupledPart — 8 methods
- struct `StrandPart` : CoupledPart — 8 methods

### `physics/cloth_anchor.mojo`
- struct `AnchorPart` : CoupledPart — 8 methods
- struct `ClothAnchorPart` : CoupledPart — 8 methods

### `physics/cloth_gas.mojo`
- struct `ClothGas2` — 2 methods

### `physics/collide_par.mojo`
- `def narrow_parallel(mut colliders: ColliderSet, mut poses: List[Pose3], mut vels: List[SIMD[.float32, 4]], mut ci: List[Int], mut cj: List[Int], spec_dt: Float32, margin_base: Float32, mut raws: List[RawContact], mut sraws: List[RawContact], mut counts: List[Int], mut scounts: List[Int], workers: Int, dispatch: Dispatch)`
- `def pairs_parallel[BP: BroadPhase](mut bp: BP, mut boxes: List[AABB[BP.dim]], mut statics: List[Bool], mut out: List[Pair], workers: Int, dispatch: Dispatch, mut skip: List[Bool])`
- `def prep_parallel[B: Body6](mut bset: BodySet[B], mut colliders: ColliderSet, mut cache: List[ContactConstraint], mut cidx: Dict[Int, Int], mut raws: List[RawContact], warm: Bool, workers: Int, dispatch: Dispatch, match_scale: Float32 = Float32("1")) -> List[ContactConstraint]`
- aliases: `BP_PAR_MIN`, `NARROW_PAR_MIN`

### `physics/constraints.mojo`
- struct `ConRow` — 0 methods
- struct `ConstraintSet` — 12 methods
- struct `LoopClosure` — 0 methods
- `def resolve_loops(mut ch: Chain, loops: List[LoopClosure], dt: Float32, mode: Int = Int(1), iters: Int = Int(20), pos_iters: Int = Int(2)) -> Real`
- aliases: `CONE_ELLIPTIC`, `CONE_PYRAMIDAL`, `CON_CONTACT`, `CON_EQUALITY`, `CON_FRICTION_LOSS`, `CON_LIMIT`, `CON_TANGENT`, `SOLVE_CG`, `SOLVE_DIRECT`, `SOLVE_PGS`

### `physics/contact6.mojo`
- struct `ContactConstraint` — 0 methods
- struct `ContactRule` — 0 methods
- `def accumulate_step_impulse[B: Body6](bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int, scale: Float32, h: Float32)`
- `def add_restitution_impulse[B: Body6](bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int)`
- `def anchor_world[B: Body6](bset: BodySet[B], i: Int, r: SIMD[.float32, 4], o: SIMD[.float32, 4], e: SIMD[.float32, 4] = SIMD(Float32("0"), Float32("0"), Float32("0"), Float32("0"), __list_literal__=NoneType(None)), toward: SIMD[.float32, 4] = SIMD(Float32("0"), Float32("0"), Float32("0"), Float32("0"), __list_literal__=NoneType(None))) -> Vec3`
- `def apply_rules[B: Body6](bset: BodySet[B], rules: List[ContactRule], mut pairs: List[ContactConstraint])`
- `def cache_index(cache: List[ContactConstraint]) -> Dict[Int, Int]`
- `def contact_island[B: Body6](bset: BodySet[B], pr: ContactConstraint) -> Int`
- `def island_color(label: Int) -> SIMD[.float32, 4]`
- `def make_contact[B: Body6](bset: BodySet[B], colliders: ColliderSet, cache: List[ContactConstraint], cidx: Dict[Int, Int], rc: RawContact, warm: Bool, match_scale: Float32 = Float32("1")) -> ContactConstraint`
- `def make_sensor_contact(rc: RawContact) -> ContactConstraint`
- `def restitution_pass[B: Body6](mut bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int, iters: Int, threshold: Float32 = 1)`
- `def round_core[B: Body6](bset: BodySet[B], colliders: ColliderSet, i: Int, p: SIMD[.float32, 4], n: SIMD[.float32, 4] = SIMD(Float32("0"), Float32("0"), Float32("0"), Float32("0"), __list_literal__=NoneType(None)), child: Int = Int(-1)) -> Optional[SIMD[.float32, 4]]`
- `def round_reach[B: Body6](bset: BodySet[B], colliders: ColliderSet, i: Int, n: SIMD[.float32, 4], child: Int = Int(-1)) -> Real`
- `def soft_sweep[B: Body6](mut bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int, h: Float32, bias_rate: Float32, mass_scale: Float32, impulse_scale: Float32, use_bias: Bool, iters: Int, mu: Float32, max_push: Float32 = Float32("4"))`
- `def solve_color_parallel[B: Body6](mut bset: BodySet[B], mut pairs2: List[ContactConstraint], lo: Int, hi: Int, h: Float32, bias_rate: Float32, mass_scale: Float32, impulse_scale: Float32, use_bias: Bool, mu: Float32, workers: Int = Int(0), dispatch: Dispatch = Dispatch.parallel(), max_push: Float32 = Float32("4"))`
- `def solve_contact[B: Body6](mut bset: BodySet[B], mut pairs: List[ContactConstraint], c: Int, h: Float32, bias_rate: Float32, mass_scale: Float32, impulse_scale: Float32, use_bias: Bool, mu: Float32, max_push: Float32 = Float32("4"))`
- `def solve_point[B: Body6](mut bset: BodySet[B], ia: Int, ib: Int, n: SIMD[.float32, 4], p: SIMD[.float32, 4], depth: Float32, dt: Float32, acc: Float32) -> Real`
- `def sweep_colored[B: Body6](mut bset: BodySet[B], mut pairs: List[ContactConstraint], clo: List[Int], chi: List[Int], h: Float32, bias_rate: Float32, mass_scale: Float32, impulse_scale: Float32, use_bias: Bool, iters: Int, mu: Float32, par: Bool, workers: Int = Int(0), dispatch: Dispatch = Dispatch.parallel(), max_push: Float32 = Float32("4"))`
- `def warm_start_contacts[B: Body6](mut bset: BodySet[B], pairs: List[ContactConstraint], lo: Int, hi: Int)`
- aliases: `RULE_CONVEYOR`, `RULE_FRICTION`, `RULE_ONE_WAY`

### `physics/continuum.mojo`
- trait `ContinuumSolver` — 0 methods
- struct `ContinuumHealth` — 0 methods
- struct `FemContinuum` : ContinuumSolver — 5 methods
- struct `LbmContinuum` : ContinuumSolver — 5 methods
- struct `MpmContinuum` : ContinuumSolver — 5 methods
- struct `PbfContinuum` : ContinuumSolver — 5 methods
- `def step_checked[S: ContinuumSolver](mut s: S, dt: Float32, gravity: SIMD[.float32, 4], mut counters: Counters) -> ContinuumHealth`

### `physics/cosserat_rod.mojo`
- struct `CosseratRod` — 8 methods

### `physics/coupler.mojo`
- trait `CoupledPart` — 0 methods
- struct `Both` : CoupledPart — 8 methods
- struct `Coupler` — 3 methods
- `def read_reals[R: StateReader](mut r: R) -> List[Float32]`
- `def write_reals[W: StateWriter](mut w: W, d: List[Float32])`
- aliases: `EXPLICIT`, `INTERP`, `ITERATED`

### `physics/coupling.mojo`
- trait `CouplingPort` — 0 methods
- struct `Both` : ContinuumSolver — 5 methods
- struct `BothPorts` : CouplingPort — 2 methods
- struct `OneWay` : CouplingPort — 2 methods
- `def couple_step[P: CouplingPort, B: Body6](mut scene: ContactScene6[B], mut port: P, mut s: P.S, dt: Float32, gravity: SIMD[.float32, 4], cfg: SolverConfig, mut counters: Counters) -> ContinuumHealth`
- aliases: `S`

### `physics/diffrigid.mojo`
- struct `RigidState` — 0 methods
- `def rollout_rigid[F: Field](vx0: F, vy0: F, y0: F, steps: Int, dt: Float32, restitution: Float32) -> RigidState[F]`
- `def rollout_soft[F: Field](vx0: F, vy0: F, y0: F, steps: Int, dt: Float32, k: Float32, c: Float32) -> RigidState[F]`

### `physics/diffsim.mojo`
- struct `DiffState2` — 0 methods
- `def rollout2[F: Field](vx0: F, vy0: F, y0: Float32, steps: Int, dt: Float32) -> DiffState2[F]`
- `def rollout_ctrl[F: Field](u: List[F], burst: Int, dt: Float32) -> DiffState2[F]`
- `def rollout_ctrl_adjoint(u: List[Float32], burst: Int, dt: Float32, mut grad: List[Float32]) -> Real`

### `physics/diffsolver.mojo`
- struct `DiffContact` — 0 methods
- struct `DiffPlane` — 0 methods
- struct `DiffSphere` — 7 methods
- struct `QF` — 4 methods
- struct `SphereWorld` — 3 methods
- struct `V3` — 4 methods
- `def clamp_sym[F: SolverField](x: F, cap: F) -> F`
- `def clamp_sym_k[F: SolverField](x: F, cap: F, k: Float32) -> F`
- `def length[F: SolverField](v: V3[F]) -> F`
- `def relu[F: SolverField](x: F) -> F`
- `def relu_k[F: SolverField](x: F, k: Float32) -> F`
- `def step_worlds_parallel[W: Int](mut worlds: List[SphereWorld[BatchReal[W]]], dt: Float32, frames: Int, workers: Int = Int(0), dispatch: Dispatch = Dispatch.parallel())`
- `def tangent_basis_f[F: SolverField](n: V3[F]) -> Tuple[V3[F], V3[F]]`

### `physics/fem.mojo`
- struct `FemBody` — 19 methods
- struct `FemImplicitOp` : LinearOperator — 5 methods
- struct `Tet` — 0 methods
- `def det3(m: Mat[Int(3)]) -> Real`
- `def fem_from_tetmesh(mut b: FemBody, m: TetMesh, density: Float32)`
- `def make_beam(mut b: FemBody, nx: Int, ny: Int, nz: Int, h: Float32, mass_per_node: Float32)`
- `def polar_rotation(f: Mat[Int(3)]) -> Mat3`
- aliases: `FEM_SOLVE_CG`, `FEM_SOLVE_CHOLESKY`, `FEM_SOLVE_PCG_IC0`

### `physics/fem_material.mojo`
- trait `Material` — 0 methods
- struct `Corotational` : Material — 2 methods
- struct `NhImplicitOp` : LinearOperator — 4 methods
- struct `StVK` : Material — 2 methods
- struct `StableNeoHookean` : Material — 2 methods
- `def cofactor(f: Mat[Int(3)]) -> Mat3`
- `def deformation_gradient(body: FemBody, t: Int) -> Mat3`
- `def inverted_count(body: FemBody) -> Int`
- `def material_forces[M: Material](body: FemBody, mut fx: List[Float32], mut fy: List[Float32], mut fz: List[Float32])`
- `def nh_dpk1(f: Mat[Int(3)], df: Mat[Int(3)], mu: Float32, lam: Float32) -> Mat3`
- `def nh_forces_averaged(body: FemBody, mut fx: List[Float32], mut fy: List[Float32], mut fz: List[Float32])`
- `def step_implicit_nh(mut body: FemBody, dt: Float32, gravity: SIMD[.float32, 4], floor_y: Float32 = -1.0E+30, tol: Float32 = 1.0E-4, max_iters: Int = Int(0)) -> CgResult`
- `def step_material[M: Material](mut body: FemBody, dt: Float32, gravity: SIMD[.float32, 4], floor_y: Float32 = -1.0E+30)`
- `def step_nh_averaged(mut body: FemBody, dt: Float32, gravity: SIMD[.float32, 4], floor_y: Float32 = -1.0E+30)`
- `def step_vbd_nh(mut body: FemBody, dt: Float32, gravity: SIMD[.float32, 4], iters: Int = Int(20), floor_y: Float32 = -1.0E+30)`

### `physics/fem_pd.mojo`
- struct `FemPd` — 1 methods

### `physics/fem_scene.mojo`
- struct `FemContactPort` : CouplingPort — 2 methods
- `def fem_coupled_step[B: Body6](mut scene: ContactScene6[B], mut port: FemContactPort, mut fem: FemContinuum, dt: Float32, gravity: SIMD[.float32, 4], cfg: SolverConfig, mut counters: Counters, substeps: Int = Int(16))`
- `def point_contact[B: Body6](scene: ContactScene6[B], b: Int, x: SIMD[.float32, 4], x_prev: SIMD[.float32, 4], r: Float32, dt: Float32) -> Tuple[Bool, SIMD[.float32, 4], SIMD[.float32, 4]]`
- aliases: `S`

### `physics/fields.mojo`
- struct `ForceField` — 4 methods
- struct `WaterVolume` — 0 methods
- struct `WindGrid` — 3 methods
- `def apply_buoyancy[B: Body6](mut sc: ContactScene6[B], waters: List[WaterVolume], gravity: SIMD[.float32, 4], dt: Float32, samples: Int = Int(8))`
- `def apply_fields[B: Body6](mut sc: ContactScene6[B], fields: List[ForceField], grids: List[WindGrid], gravity: SIMD[.float32, 4], dt: Float32)`
- `def box_submerged_exact(c: SIMD[.float32, 4], half: SIMD[.float32, 4], surface: Float32) -> Tuple[Float32, SIMD[.float32, 4]]`
- `def box_submerged_sampled[B: Body6](body: B, half: SIMD[.float32, 4], surface: Float32, samples: Int) -> Tuple[Float32, SIMD[.float32, 4]]`
- `def sphere_submerged(c: SIMD[.float32, 4], r: Float32, surface: Float32) -> Tuple[Float32, SIMD[.float32, 4]]`
- aliases: `FIELD_DRAG`, `FIELD_GRAVITY`, `FIELD_RADIAL`, `FIELD_WIND`

### `physics/flip.mojo`
- struct `FlipWater2` — 6 methods

### `physics/flip3.mojo`
- struct `FlipWater3` — 6 methods

### `physics/flip_apic.mojo`
- struct `ApicState` — 0 methods
- `def apic_step(mut w: FlipWater2, mut st: ApicState, dt: Float32)`

### `physics/flip_diffuse.mojo`
- struct `DiffuseParticles` — 4 methods
- aliases: `BUBBLE`, `FOAM`, `SPRAY`

### `physics/floating.mojo`
- struct `FloatingChain` — 11 methods
- `def read_floating[R: StateReader](mut r: R) -> FloatingChain`
- `def write_floating[W: StateWriter](fc: FloatingChain, mut out: W)`

### `physics/fracture.mojo`
- struct `FractureEvent` — 0 methods
- struct `FractureSet` — 14 methods
- `def debris_config() -> SolverConfig`
- `def read_fracture[R: StateReader](mut r: R) -> FractureSet`
- `def write_fracture[W: StateWriter](fs: FractureSet, mut out: W)`
- aliases: `EVENT_BOND_BROKEN`, `EVENT_EVICTED`

### `physics/fsi.mojo`
- struct `LbmCoupler` — 5 methods
- struct `LbmSpherePort` : CouplingPort — 4 methods
- `def lbm_continuum_read[R: StateReader](mut s: LbmContinuum, mut r: R)`
- `def lbm_continuum_write[W: StateWriter](s: LbmContinuum, mut w: W)`
- `def lbm_read[R: StateReader](mut l: Lbm, mut r: R)`
- `def lbm_write[W: StateWriter](l: Lbm, mut w: W)`
- `def sphere_drive(pos: SIMD[.float32, 4], vel: SIMD[.float32, 4], omega: SIMD[.float32, 4], origin: SIMD[.float32, 4], dx: Float32, dt: Float32) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def sphere_load(obj_f: SIMD[.float32, 4], obj_t: SIMD[.float32, 4], rho: Float32, dx: Float32, dt: Float32, radius: Float32, gravity: SIMD[.float32, 4]) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def sphere_port_read[R: StateReader](mut p: LbmSpherePort, mut r: R)`
- `def sphere_port_write[W: StateWriter](p: LbmSpherePort, mut w: W)`
- aliases: `S`

### `physics/gpu_artic.mojo`
- struct `GpuArticBatch` — 3 methods
- `def artic_step_kernel(model: Pointer[Float32, MutAnyOrigin], parent: Pointer[Int32, MutAnyOrigin], n: Int32, state: Pointer[Float32, MutAnyOrigin], qdd: Pointer[Float32, MutAnyOrigin], ws: Pointer[Float32, MutAnyOrigin], count: Int32, gx: Float32, gy: Float32, gz: Float32, dt: Float32, steps: Int32)`

### `physics/gpu_cloth.mojo`
- struct `ClothState` — 0 methods
- struct `GpuClothTiming` — 1 methods
- `def apply_kernel[LT: TensorLayout](px: TileTensor[.float32, LT, MutAnyOrigin], py: TileTensor[.float32, LT, MutAnyOrigin], pz: TileTensor[.float32, LT, MutAnyOrigin], dx: TileTensor[.float32, LT, MutAnyOrigin], dy: TileTensor[.float32, LT, MutAnyOrigin], dz: TileTensor[.float32, LT, MutAnyOrigin], n: Int32)`
- `def cpu_cloth_run[W: Int, H: Int](steps: Int, iters: Int, dt: Float32, rest: Float32, self_thickness: Float32 = Float32("0")) -> ClothState`
- `def finalize_kernel[LT: TensorLayout](x: TileTensor[.float32, LT, MutAnyOrigin], y: TileTensor[.float32, LT, MutAnyOrigin], z: TileTensor[.float32, LT, MutAnyOrigin], px: TileTensor[.float32, LT, MutAnyOrigin], py: TileTensor[.float32, LT, MutAnyOrigin], pz: TileTensor[.float32, LT, MutAnyOrigin], vx: TileTensor[.float32, LT, MutAnyOrigin], vy: TileTensor[.float32, LT, MutAnyOrigin], vz: TileTensor[.float32, LT, MutAnyOrigin], n: Int32, inv_dt: Float32)`
- `def gpu_cloth_run_ctx[W: Int, H: Int](mut ctx: DeviceContextBase, steps: Int, iters: Int, dt: Float32, rest: Float32) -> ClothState`
- `def gpu_cloth_run_ctx_timed[W: Int, H: Int](mut ctx: DeviceContextBase, steps: Int, iters: Int, dt: Float32, rest: Float32, readback_every: Int, mut timing: GpuClothTiming) -> ClothState`
- `def init_grid[W: Int, H: Int](mut s: ClothState, rest: Float32)`
- `def jacobi_kernel[LT: TensorLayout](px: TileTensor[.float32, LT, MutAnyOrigin], py: TileTensor[.float32, LT, MutAnyOrigin], pz: TileTensor[.float32, LT, MutAnyOrigin], w: TileTensor[.float32, LT, MutAnyOrigin], dx: TileTensor[.float32, LT, MutAnyOrigin], dy: TileTensor[.float32, LT, MutAnyOrigin], dz: TileTensor[.float32, LT, MutAnyOrigin], grid_w: Int32, grid_h: Int32, rest: Float32)`
- `def predict_kernel[LT: TensorLayout](x: TileTensor[.float32, LT, MutAnyOrigin], y: TileTensor[.float32, LT, MutAnyOrigin], z: TileTensor[.float32, LT, MutAnyOrigin], vy: TileTensor[.float32, LT, MutAnyOrigin], px: TileTensor[.float32, LT, MutAnyOrigin], py: TileTensor[.float32, LT, MutAnyOrigin], pz: TileTensor[.float32, LT, MutAnyOrigin], vx: TileTensor[.float32, LT, MutAnyOrigin], vz: TileTensor[.float32, LT, MutAnyOrigin], w: TileTensor[.float32, LT, MutAnyOrigin], n: Int32, dt: Float32)`
- aliases: `dtype`

### `physics/gpu_contact.mojo`
- struct `GpuContactSolver` — 1 methods
- `def gravity_kernel[LT: TensorLayout](b: TileTensor[.float32, LT, MutAnyOrigin], n: Int32, h: Float32, gx: Float32, gy: Float32, gz: Float32)`
- `def integrate_kernel[LT: TensorLayout](b: TileTensor[.float32, LT, MutAnyOrigin], n: Int32, h: Float32)`
- `def solve_kernel[LT: TensorLayout, LC: TensorLayout](b: TileTensor[.float32, LT, MutAnyOrigin], c: TileTensor[.float32, LC, MutAnyOrigin], lo: Int32, count: Int32, h: Float32, bias_rate: Float32, mass_scale: Float32, impulse_scale: Float32, use_bias: Int32)`
- `def warm_kernel[LT: TensorLayout, LC: TensorLayout](b: TileTensor[.float32, LT, MutAnyOrigin], c: TileTensor[.float32, LC, MutAnyOrigin], lo: Int32, count: Int32)`
- aliases: `dtype`

### `physics/integrator6.mojo`
- trait `SpinIntegrator` — 0 methods
- struct `EulerSpin` : SpinIntegrator — 1 methods
- struct `LgvciSpin` : SpinIntegrator — 1 methods
- struct `MidpointSpin` : SpinIntegrator — 1 methods
- struct `Rk2Spin` : SpinIntegrator — 1 methods
- `def run_spin[I: SpinIntegrator](var pose: Motor3, var wb: SIMD[.float32, 4], inertia: Inertia3, dt: Float32, steps: Int) -> Tuple[Motor3, SIMD[.float32, 4]]`
- `def spin_energy(wb: SIMD[.float32, 4], inertia: Inertia3) -> Real`
- `def spin_momentum_world(pose: Motor3, wb: SIMD[.float32, 4], inertia: Inertia3) -> Vec3`

### `physics/islands.mojo`
- `def find_root(mut parent: List[Int], i: Int) -> Int`
- `def island_count[B: Body6](bset: BodySet[B]) -> Int`
- `def island_labels[B: Body6](bset: BodySet[B]) -> List[Int]`
- `def refresh_islands[B: Body6](mut bset: BodySet[B], edges: List[Int], n_contacts: Int)`
- `def update_sleep[B: Body6](mut bset: BodySet[B], dt: Float32, cfg: SolverConfig)`
- `def wake_if_kinematic_moving[B: Body6](mut bset: BodySet[B], ka: Int, kb: Int)`
- `def wake_island[B: Body6](mut bset: BodySet[B], i: Int)`

### `physics/joint_ext.mojo`
- struct `JointExt` — 3 methods
- `def d6_coords[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def d6_solve[B: Body6](mut bset: BodySet[B], jt: Joint6, mut ex: JointExt, h: Float32, bias_rate: Float32, ms: Float32, isc: Float32, use_bias: Bool)`
- `def ext_impulse[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def ext_sweep[B: Body6](mut bset: BodySet[B], mut joints: List[Joint6], mut ext: List[JointExt], h: Float32, bias_rate: Float32, ms: Float32, isc: Float32, use_bias: Bool, iters: Int, island_filter: Int)`
- `def joint_coordinate[B: Body6](bset: BodySet[B], jt: Joint6, ex: JointExt) -> Real`
- `def sample_ext_loads[B: Body6](bset: BodySet[B], joints: List[Joint6], ext: List[JointExt], h: Float32, mut peak_force: List[Float32], mut peak_torque: List[Float32])`
- `def slider_lock[B: Body6](mut bset: BodySet[B], mut jt: Joint6, ex: JointExt, h: Float32, bias_rate: Float32, ms: Float32, isc: Float32, use_bias: Bool)`
- `def warm_start_ext[B: Body6](mut bset: BodySet[B], joints: List[Joint6], ext: List[JointExt], island_filter: Int)`
- aliases: `D6_ALL_LOCKED`, `D6_FREE`, `D6_LIMITED`, `D6_LOCKED`, `MOTOR_NONE`, `MOTOR_POSITION`, `MOTOR_VELOCITY`

### `physics/joints6.mojo`
- struct `AngularDrive` — 1 methods
- struct `Joint6` — 12 methods
- `def check_breaks(mut joints: List[Joint6], break_force: List[Float32], break_torque: List[Float32], mut peak_force: List[Float32], mut peak_torque: List[Float32], mut broken: List[Int])`
- `def drive_error(qa: Quat, qb: Quat, target: Quat) -> Vec3`
- `def drive_sweep[B: Body6](mut bset: BodySet[B], mut drives: List[AngularDrive], h: Float32, iters: Int)`
- `def joint_axis[B: Body6](mut bset: BodySet[B], ia: Int, ib: Int, pwa: SIMD[.float32, 4], pwb: SIMD[.float32, 4], e: SIMD[.float32, 4], c: Float32, h: Float32, bias_rate: Float32, ms: Float32, isc: Float32, use_bias: Bool, acc_e: Float32, scaled: Bool = False) -> Real`
- `def joint_island[B: Body6](bset: BodySet[B], jt: Joint6) -> Int`
- `def joint_sweep[B: Body6](mut bset: BodySet[B], mut joints: List[Joint6], h: Float32, bias_rate: Float32, ms: Float32, isc: Float32, use_bias: Bool, iters: Int, island_filter: Int)`
- `def sample_loads(joints: List[Joint6], h: Float32, mut peak_force: List[Float32], mut peak_torque: List[Float32])`
- `def warm_start_drives[B: Body6](mut bset: BodySet[B], drives: List[AngularDrive])`
- `def warm_start_joints[B: Body6](mut bset: BodySet[B], joints: List[Joint6], island_filter: Int)`
- aliases: `JOINT_BALL`, `JOINT_BROKEN`, `JOINT_CONE_TWIST`, `JOINT_D6`, `JOINT_DISTANCE`, `JOINT_GEAR`, `JOINT_HINGE`, `JOINT_PULLEY`, `JOINT_ROPE`, `JOINT_SLIDER`, `JOINT_UNIVERSAL`, `JOINT_WELD`

### `physics/lod.mojo`
- struct `DistanceLOD` — 1 methods
- struct `SimBudget` — 2 methods

### `physics/mac_body.mojo`
- struct `DragBody2` — 1 methods
- `def disk_samples(radius: Float32, dx: Float32) -> Tuple[List[Float32], List[Float32]]`
- `def square_samples(half_side: Float32, dx: Float32) -> Tuple[List[Float32], List[Float32]]`

### `physics/mac_fluid.mojo`
- struct `MacFluid2` — 10 methods
- struct `Smoke2` — 3 methods
- `def warm_start_or_zero[Op: LinearOperator](op: Op, rhs: List[Float32], mut x: List[Float32])`

### `physics/mac_fluid3.mojo`
- struct `MacFluid3` — 15 methods
- struct `Smoke3` — 2 methods

### `physics/mac_levelset.mojo`
- struct `LevelSetWater2` — 7 methods

### `physics/mac_levelset3.mojo`
- struct `LevelSetWater3` — 7 methods

### `physics/mac_levelset_particles.mojo`
- struct `LevelSetParticles` — 5 methods

### `physics/mac_levelset_particles3.mojo`
- struct `LevelSetParticles3` — 5 methods

### `physics/mass_props.mojo`
- struct `CompoundMass` — 0 methods
- `def child_mass(spec: CompoundSpec, k: Int, density: Float32) -> Tuple[Float32, SIMD[.float32, 4], Mat3x3]`
- `def compound_mass(spec: CompoundSpec, density: Float32) -> CompoundMass`
- `def hull_mass(verts: List[Float32], density: Float32) -> Tuple[Float32, SIMD[.float32, 4], Mat3x3]`
- `def quat_from_mat(r: Mat3x3) -> Quat`

### `physics/material.mojo`
- `def combine(a: Float32, b: Float32, mode_a: Int, mode_b: Int) -> Real`
- aliases: `COMBINE_AVERAGE`, `COMBINE_MAX`, `COMBINE_MIN`, `COMBINE_MULTIPLY`

### `physics/mpm.mojo`
- struct `MpmParticle` — 0 methods
- struct `MpmRigid` — 0 methods
- struct `MpmSolver` — 10 methods

### `physics/mpm_melt.mojo`
- struct `MpmMelt` — 4 methods
- `def melt_state(h: Float64, c: Float32, latent: Float32, t_melt: Float32) -> Tuple[Float32, Float32]`

### `physics/mpm_rigid.mojo`
- struct `MpmRigidCoupler` — 1 methods
- `def mpm_rigid_read[R: StateReader](mut mpm: MpmSolver, mut r: R)`
- `def mpm_rigid_step[B: Body6](mut mpm: MpmSolver, cp: MpmRigidCoupler, mut scene: ContactScene6[B], dt: Float32, gravity: SIMD[.float32, 4], cfg: SolverConfig)`
- `def mpm_rigid_write[W: StateWriter](mpm: MpmSolver, mut w: W)`

### `physics/multiphase.mojo`
- struct `MultiphaseSph` — 6 methods

### `physics/muscle_ad.mojo`
- struct `ArmParams` — 0 methods
- `def arm_rollout[F: SolverField](p: ArmParams, u: List[F], q0: Float32) -> F`
- `def hill_force_f[F: SolverField](h: HillParams, a: F, l: F, v: F) -> F`

### `physics/muscle_tendon.mojo`
- struct `MuscleTendon` — 6 methods

### `physics/pbf.mojo`
- struct `PbfFluid` — 5 methods
- `def poly6(r2: Float32) -> Real`
- `def spiky_grad(r: Float32) -> Real`
- aliases: `H`

### `physics/pbf_unified.mojo`
- struct `UnifiedPbf` — 9 methods

### `physics/resources.mojo`
- struct `Limits` — 0 methods
- struct `ResourceReport` : Writable — 2 methods
- `def body_set_bytes[B: Body6](b: BodySet[B]) -> Int`
- `def bytes_per_body[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP]) -> Int`
- `def check_room[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP], limits: Limits, bodies: Int, joints: Int = Int(0))`
- `def collider_header_bytes(c: ColliderSet) -> Int`
- `def resource_report[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP]) -> ResourceReport`
- `def shape_payload_bytes(c: ColliderSet) -> Int`

### `physics/rigid6.mojo`
- trait `Body6` — 0 methods
- struct `Inertia3` — 8 methods
- struct `Pose6` — 0 methods
- struct `QuatBody6` : Body6 — 23 methods
- struct `ScrewBody6` : Body6 — 25 methods

### `physics/rigid_air_part.mojo`
- struct `RigidPart` : CoupledPart — 9 methods

### `physics/rope.mojo`
- struct `Rope` : ContinuumSolver — 10 methods

### `physics/screw.mojo`
- struct `ScrewBody` : ComponentType — 2 methods
- `def integrate_screw[B: StorageBackend](mut w: World[B], dt: Float32)`
- `def screw_velocity(omega: SIMD[.float32, 4], v: SIMD[.float32, 4]) -> Screw3`
- `def step_screw(pose: Motor3, vel: Screw3, dt: Float32) -> Motor3`
- aliases: `ID`

### `physics/sediment.mojo`
- struct `Sediment` — 7 methods

### `physics/self_collide.mojo`
- struct `SelfCollider` — 1 methods
- `def resolve_self_collisions(mut px: List[Float32], mut py: List[Float32], mut pz: List[Float32], w: List[Float32], width: Int, thickness: Float32, mut grid: SelfCollider) -> Int`
- aliases: `SKIP`

### `physics/sensors.mojo`
- struct `ImuReading` — 0 methods
- `def read_imu(c: Chain, link: Int, local: SIMD[.float32, 4], qdd: List[Float32], gravity: SIMD[.float32, 4]) -> ImuReading`
- `def read_imu_batch(c: Chain, links: List[Int], locals: List[SIMD[.float32, 4]], qdd: List[Float32], gravity: SIMD[.float32, 4]) -> List[ImuReading]`
- `def read_joint_pos(c: Chain) -> List[Float32]`
- `def read_joint_torque(c: Chain, qdd: List[Float32], gravity: SIMD[.float32, 4]) -> List[Float32]`
- `def read_joint_vel(c: Chain) -> List[Float32]`
- `def read_rangefinder(c: Chain, link: Int, local: SIMD[.float32, 4], dir_local: SIMD[.float32, 4], plane_y: Float32, max_range: Float32 = Float32("100")) -> Real`
- `def read_touch(c: Chain, link: Int, local: SIMD[.float32, 4], floor_y: Float32) -> Real`

### `physics/serialize.mojo`
- struct `BinReader` : StateReader — 3 methods
- struct `BinWriter` : StateWriter — 3 methods
- `def scene_from_bytes(var data: List[UInt8]) -> ContactScene6[QuatBody6]`
- `def scene_from_string(data: String) -> ContactScene6[QuatBody6]`
- `def scene_to_bytes(sc: ContactScene6[QuatBody6]) -> List[UInt8]`
- `def scene_to_string(sc: ContactScene6[QuatBody6]) -> String`

### `physics/sim_cache.mojo`
- struct `CachePlayer` : ContinuumSolver — 5 methods
- struct `PointCacheReader` — 2 methods
- struct `PointCacheWriter` — 3 methods
- `def fnv1a64(b: List[UInt8], n: Int) -> UInt64`
- aliases: `CACHE_MAGIC`, `CACHE_VERSION`, `CACHE_VERSION_PACKED`

### `physics/soft_couple.mojo`
- `def soft_fric[B: Body6](bset: BodySet[B], b: Int, x0: SIMD[.float32, 4], pv: SIMD[.float32, 4], nw: SIMD[.float32, 4], nrm: SIMD[.float32, 4], h: Float32, mu: Float32) -> Vec3`
- `def softbody_pass[B: Body6](mut softs: List[SoftBody], mut bset: BodySet[B], colliders: ColliderSet, h_step: Float32, gravity: SIMD[.float32, 4], iters: Int, ccd: Bool, step: Int = Int(0))`

### `physics/soft_water.mojo`
- `def cloth_water(mut c: MeshCloth, waters: List[WaterVolume], gravity: SIMD[.float32, 4], dt: Float32, density: Float32, thickness: Float32, cd: Float32 = 1.2)`
- `def soft_water(mut sb: SoftBody, waters: List[WaterVolume], gravity: SIMD[.float32, 4], dt: Float32, volume: Float32)`

### `physics/softbody.mojo`
- struct `SEdge` — 0 methods
- struct `SP` — 0 methods
- struct `SoftBody` : ContinuumSolver — 14 methods

### `physics/solver6.mojo`
- struct `ContactReport` — 0 methods
- struct `ContactScene6` — 107 methods
- `def read_state[R: StateReader](mut sc: ContactScene6[QuatBody6], mut r: R)`
- `def write_state[W: StateWriter](sc: ContactScene6[QuatBody6], mut out: W)`
- aliases: `FORCE_MODE_ACCELERATION`, `FORCE_MODE_FORCE`, `FORCE_MODE_IMPULSE`, `FORCE_MODE_VELOCITY_CHANGE`

### `physics/solver_config.mojo`
- struct `SolverConfig` — 1 methods
- struct `UnitScale` — 1 methods
- aliases: `CONTACT_BLOCK`, `CONTACT_GS`, `FRICTION_ELLIPTIC`, `FRICTION_PYRAMID`, `IMPULSE_LAST_SUBSTEP`, `IMPULSE_SUBSTEP_SUM`, `MASS_RATIO_DEFAULT`

### `physics/sph.mojo`
- struct `BoundaryParticles` — 2 methods
- `def box_floor_boundary(lo: SIMD[.float32, 4], hi: SIMD[.float32, 4], spacing: Float32, rho0: Float32) -> BoundaryParticles`
- `def sph_step(mut f: PbfFluid, dt: Float32, gravity: SIMD[.float32, 4])`
- `def sph_step_boundary(mut f: PbfFluid, bnd: BoundaryParticles, dt: Float32, gravity: SIMD[.float32, 4])`
- `def visc_lap(r: Float32) -> Real`

### `physics/sph_rigid.mojo`
- struct `SphRigidCoupler` — 4 methods
- `def sph_rigid_read[R: StateReader](mut f: PbfFluid, mut cp: SphRigidCoupler, mut r: R)`
- `def sph_rigid_step[B: Body6](mut f: PbfFluid, bnd: BoundaryParticles, mut cp: SphRigidCoupler, mut scene: ContactScene6[B], dt: Float32, gravity: SIMD[.float32, 4], cfg: SolverConfig)`
- `def sph_rigid_write[W: StateWriter](f: PbfFluid, cp: SphRigidCoupler, mut w: W)`

### `physics/state_io.mojo`
- trait `StateReader` — 0 methods
- trait `StateWriter` — 0 methods
- `def f64_bits(x: Float64) -> Int`
- `def f64_from_bits(i: Int) -> Float64`

### `physics/strand.mojo`
- struct `StrandCapsule` — 0 methods
- struct `StrandSet` — 9 methods
- struct `StrandSphere` — 0 methods

### `physics/strand_air.mojo`
- struct `StrandAir` — 3 methods

### `physics/strand_ext.mojo`
- `def interpolate_strand(guides: List[List[SIMD[.float32, 4]]], weights: List[Float32], root: SIMD[.float32, 4]) -> List[SIMD[.float32, 4]]`
- `def strands_collide[B: Body6](mut s: StrandSet, scene: ContactScene6[B], dt: Float32, mu: Float32 = 0.29999999999999999) -> Int`
- `def strands_interact(mut s: StrandSet, cell: Float32, k: Float32)`
- `def strands_read[R: StateReader](mut s: StrandSet, mut r: R)`
- `def strands_write[W: StateWriter](s: StrandSet, mut w: W)`

### `physics/strand_gas.mojo`
- struct `StrandGas2` — 2 methods

### `physics/tendon.mojo`
- struct `FixedTendon` — 4 methods
- struct `SpatialTendon` — 6 methods
- struct `TendonSite` — 0 methods
- struct `WrapSphere` — 2 methods

### `physics/thermal.mojo`
- struct `HeatGrid` — 5 methods
- struct `HeatParticles` — 5 methods
- struct `HeatTets` — 6 methods
- aliases: `T_MAX`

### `physics/thermal_float.mojo`
- struct `HeatedWater` — 3 methods

### `physics/thermal_smoke.mojo`
- struct `HeatPlate` : CoupledPart — 8 methods
- struct `SmokeGas` : CoupledPart — 8 methods

### `physics/vbd_cloth.mojo`
- `def cpu_vbd_run[W: Int, H: Int](steps: Int, iters: Int, dt: Float32, rest: Float32, self_thickness: Float32 = Float32("0")) -> ClothState`
- `def gpu_vbd_run_ctx[W: Int, H: Int](mut ctx: DeviceContextBase, steps: Int, iters: Int, dt: Float32, rest: Float32) -> ClothState`
- `def vbd_finalize_kernel[LT: TensorLayout](x: TileTensor[.float32, LT, MutAnyOrigin], y: TileTensor[.float32, LT, MutAnyOrigin], z: TileTensor[.float32, LT, MutAnyOrigin], ox: TileTensor[.float32, LT, MutAnyOrigin], oy: TileTensor[.float32, LT, MutAnyOrigin], oz: TileTensor[.float32, LT, MutAnyOrigin], vx: TileTensor[.float32, LT, MutAnyOrigin], vy: TileTensor[.float32, LT, MutAnyOrigin], vz: TileTensor[.float32, LT, MutAnyOrigin], n: Int32, inv_dt: Float32)`
- `def vbd_predict_kernel[LT: TensorLayout](x: TileTensor[.float32, LT, MutAnyOrigin], y: TileTensor[.float32, LT, MutAnyOrigin], z: TileTensor[.float32, LT, MutAnyOrigin], vx: TileTensor[.float32, LT, MutAnyOrigin], vy: TileTensor[.float32, LT, MutAnyOrigin], vz: TileTensor[.float32, LT, MutAnyOrigin], tx: TileTensor[.float32, LT, MutAnyOrigin], ty: TileTensor[.float32, LT, MutAnyOrigin], tz: TileTensor[.float32, LT, MutAnyOrigin], ox: TileTensor[.float32, LT, MutAnyOrigin], oy: TileTensor[.float32, LT, MutAnyOrigin], oz: TileTensor[.float32, LT, MutAnyOrigin], w: TileTensor[.float32, LT, MutAnyOrigin], n: Int32, dt: Float32)`
- `def vbd_solve_kernel[LT: TensorLayout](x: TileTensor[.float32, LT, MutAnyOrigin], y: TileTensor[.float32, LT, MutAnyOrigin], z: TileTensor[.float32, LT, MutAnyOrigin], tx: TileTensor[.float32, LT, MutAnyOrigin], ty: TileTensor[.float32, LT, MutAnyOrigin], tz: TileTensor[.float32, LT, MutAnyOrigin], w: TileTensor[.float32, LT, MutAnyOrigin], grid_w: Int32, grid_h: Int32, rest: Float32, mh2: Float32, color: Int32)`
- aliases: `dtype`

### `physics/water.mojo`
- trait `WaterSurface` — 0 methods
- struct `FftOcean` : WaterSurface — 9 methods
- struct `FlatWater` : WaterSurface — 2 methods
- struct `GerstnerWater` : WaterSurface — 4 methods
- struct `GerstnerWave` — 0 methods
- struct `ShallowWaterFV` : WaterSurface — 6 methods
- struct `ShallowWaterGrid` : WaterSurface — 7 methods
- `def apply_buoyancy_surface[W: WaterSurface, B: Body6](mut sc: ContactScene6[B], waters: List[WaterVolume], water: W, t: Float32, gravity: SIMD[.float32, 4], dt: Float32, samples: Int = Int(8))`
- `def float_body[W: WaterSurface, B: Body6](mut sc: ContactScene6[B], id: BodyId, half: SIMD[.float32, 4], water: W, t: Float32, density: Float32, gravity: SIMD[.float32, 4], drag: Float32 = 1, samples: Int = Int(4)) -> Real`

## gameplay (layer 5) — 49 modules, 328 public declarations

### `gameplay/abilities.mojo`
- struct `Abilities` — 6 methods
- struct `AbilityDef` — 0 methods
- struct `Cue` — 0 methods
- aliases: `CUE_ACTIVATE`, `CUE_CANCEL`, `CUE_FAIL`, `CUE_HIT`, `FAIL_BLOCKED_TAG`, `FAIL_COOLDOWN`, `FAIL_COST`, `FAIL_DEAD`, `FAIL_MISSING_TAG`, `FAIL_NO_TARGET`, `OK`

### `gameplay/achievements.mojo`
- struct `Achievements` — 3 methods
- aliases: `OUT_ACHIEVEMENT`

### `gameplay/aircraft.mojo`
- struct `Wing` : ForceElement — 4 methods

### `gameplay/animator.mojo`
- struct `AnimEvent` — 0 methods
- struct `AnimLibrary` — 1 methods
- struct `AnimatorRef` : ComponentType — 0 methods
- struct `Animators` — 3 methods
- `def tick_animators[B: StorageBackend, Body: Body6, AID: Int](mut rt: Runtime[B, Body], mut anims: Animators, lib: AnimLibrary, dt: Float32, mut events: Channel[AnimEvent])`
- aliases: `ID`

### `gameplay/balance.mojo`
- `def balance_margin(poly: List[SIMD[.float32, 4]], p: SIMD[.float32, 4]) -> Real`
- `def capture_point(com: SIMD[.float32, 4], vel: SIMD[.float32, 4], ground_y: Float32, g: Float32) -> Vec3`
- `def center_of_mass[B: Body6](sc: ContactScene6[B], bodies: List[BodyId]) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def is_balanced(poly: List[SIMD[.float32, 4]], com: SIMD[.float32, 4], vel: SIMD[.float32, 4], ground_y: Float32, g: Float32) -> Bool`
- `def support_polygon(points: List[SIMD[.float32, 4]]) -> List[SIMD[.float32, 4]]`

### `gameplay/bike.mojo`
- struct `Bike` : ForceElement — 2 methods
- struct `BikeBalance` — 1 methods
- `def lean_angle(sc: ContactScene6[QuatBody6], id: BodyId) -> Real`

### `gameplay/blackbox.mojo`
- struct `BlackBox` — 0 methods
- `def pack(bb: BlackBox) -> List[UInt8]`
- `def unpack(b: List[UInt8]) -> BlackBox`
- aliases: `BB_MAGIC`, `BB_VERSION`

### `gameplay/camera_rig.mojo`
- struct `CameraBrain` — 1 methods
- struct `SpringArm` — 3 methods

### `gameplay/character.mojo`
- struct `CharacterConfig` — 1 methods
- struct `CharacterController` — 7 methods

### `gameplay/checkpoint.mojo`
- struct `GameFlow` — 2 methods
- struct `Restored` — 0 methods
- `def load_save_checkpoint(data: List[UInt8], current: GameFlow, mut scene: ContactScene6[QuatBody6], keep: Int = Int(0), sections: Int = Int(3)) -> GameFlow`
- `def respawn(blob: List[UInt8], current: GameFlow, keep: Int) -> Restored`
- `def restore_checkpoint(blob: List[UInt8]) -> Restored`
- `def save_checkpoint(flow: GameFlow, scene: ContactScene6[QuatBody6]) -> List[UInt8]`
- `def take_checkpoint(flow: GameFlow, scene: ContactScene6[QuatBody6]) -> List[UInt8]`
- aliases: `CHECKPOINT_FORMAT`, `KEEP_FLAGS`, `KEEP_INVENTORY`, `KEEP_NONE`, `KEEP_OBJECTIVES`, `SECTION_ALL`, `SECTION_BODIES`, `SECTION_FLOW`

### `gameplay/combat.mojo`
- struct `HitResult` — 0 methods
- struct `HitStop` — 3 methods
- struct `Hurtbox` — 0 methods
- struct `Swing` — 3 methods
- `def closest_segments(p1: SIMD[.float32, 4], q1: SIMD[.float32, 4], p2: SIMD[.float32, 4], q2: SIMD[.float32, 4]) -> Tuple[SIMD[.float32, 4], SIMD[.float32, 4]]`
- `def hitscan(origin: SIMD[.float32, 4], dir_in: SIMD[.float32, 4], max_t: Float32, boxes: List[Hurtbox], team: Int) -> Tuple[Int, Float32]`
- aliases: `DETECT_ARC`, `DETECT_DISCRETE`, `DETECT_LINEAR`

### `gameplay/dialogue.mojo`
- struct `Choice` — 0 methods
- struct `DialogueGraph` — 7 methods
- struct `DialogueNode` — 0 methods
- struct `DialogueState` — 0 methods
- aliases: `CMP_EQ`, `CMP_GE`, `CMP_LT`, `CMP_NE`, `CMP_NONE`, `EFF_ADD`, `EFF_NONE`, `EFF_SET`

### `gameplay/explosion.mojo`
- struct `BlastReport` — 0 methods
- struct `Shockwave` — 2 methods
- `def explode[B: Body6, BP: BroadPhase](mut sc: ContactScene6[B, BP], center: SIMD[.float32, 4], radius: Float32, impulse: Float32, samples: Int = Int(9), filter: QueryFilter = QueryFilter.all(), only: List[Int] = List()) -> BlastReport`
- `def explode_preview[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP], center: SIMD[.float32, 4], radius: Float32, filter: QueryFilter = QueryFilter.all()) -> List[Int]`

### `gameplay/flow.mojo`
- struct `Flags` — 7 methods
- struct `FlowStack` — 5 methods
- struct `FlowState` — 0 methods
- aliases: `FLAG_BOOL`, `FLAG_FX`, `FLAG_INT`, `TICK_ALL`, `TICK_EVENTS`, `TICK_SIM`, `TICK_TIMERS`

### `gameplay/force_element.mojo`
- trait `ForceElement` — 0 methods
- struct `Thruster` : ForceElement — 1 methods

### `gameplay/helicopter.mojo`
- struct `HeliController` — 1 methods
- struct `Helicopter` : ForceElement — 2 methods

### `gameplay/hit_pipeline.mojo`
- struct `DamageEvent` — 0 methods
- struct `HitWindow` — 2 methods
- `def deal_damage(hits: List[HitResult], mut rules: Rules, mut actors: List[Actor], base: Int, dtype: Int, source: Int, mut events: Channel[DamageEvent]) -> Int`
- `def explode_movers[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP], center: SIMD[.float32, 4], radius: Float32, speed: Float32, mut movers: List[Mover], filter: QueryFilter = QueryFilter.all()) -> Int`
- `def knockback(hits: List[HitResult], mut movers: List[Mover], speed: Float32)`
- `def projectile_damage(hits: List[ProjectileHit], body_actor: List[Int], mut rules: Rules, mut actors: List[Actor], base: Int, near: Float32, far: Float32, far_frac: Float32, dtype: Int, source: Int, mut events: Channel[DamageEvent]) -> Int`
- `def targets_from_hits(hits: List[HitResult]) -> List[Int]`

### `gameplay/host_inbox.mojo`
- struct `ConfigEntry` — 0 methods
- struct `ConfigInbox` — 3 methods

### `gameplay/interpolation.mojo`
- trait `PoseInterpolator` — 0 methods
- struct `DqNlerp` : PoseInterpolator — 1 methods
- struct `LerpNlerp` : PoseInterpolator — 1 methods
- struct `MotorGeodesic` : PoseInterpolator — 1 methods
- struct `PoseHistory` — 3 methods
- struct `PoseQT` — 1 methods

### `gameplay/inventory.mojo`
- struct `Inventory` — 3 methods
- struct `LootEntry` — 0 methods
- struct `LootTable` — 2 methods

### `gameplay/large_world.mojo`
- trait `CoordStrategy` — 0 methods
- struct `AbsoluteF32` : CoordStrategy — 1 methods
- struct `BodySpec` — 0 methods
- struct `CellEvent` — 0 methods
- struct `RebaseEvent` — 0 methods
- struct `RebasedF32` : CoordStrategy — 1 methods
- struct `Rebaser` — 4 methods
- struct `WorldPartition` — 5 methods
- struct `WorldPos` — 2 methods
- `def load_large_world[S: CoordStrategy](data: List[UInt8], mut rb: Rebaser[S]) -> ContactScene6[QuatBody6]`
- `def save_large_world[S: CoordStrategy](scene: ContactScene6[QuatBody6], rb: Rebaser[S]) -> List[UInt8]`
- aliases: `EV_LOAD`, `EV_UNLOAD`, `SPEC_BOX`, `SPEC_SPHERE`

### `gameplay/level_flow.mojo`
- struct `LevelDirector` — 6 methods
- struct `LoadLevel` — 0 methods
- `def checked_checkpoint(d: LevelDirector, flow: GameFlow, scene: ContactScene6[QuatBody6]) -> List[UInt8]`
- aliases: `LEVEL_IDLE`, `LEVEL_LOADING`

### `gameplay/loc_keys.mojo`
- struct `LocKeys` — 2 methods
- `def loc_id(name: String) -> Int`

### `gameplay/movement.mojo`
- struct `Ladder` — 0 methods
- struct `MoveConfig` — 1 methods
- struct `Mover` — 4 methods
- aliases: `MODEL_ACCEL`, `MODEL_DIRECT`, `MODEL_QUAKE`, `MODE_CLIMB`, `MODE_DRIVE`, `MODE_FALL`, `MODE_FLY`, `MODE_GLIDE`, `MODE_LADDER`, `MODE_SLIDE`, `MODE_SWIM`, `MODE_WALK`

### `gameplay/netcode.mojo`
- trait `NetPeer` — 0 methods
- trait `NetSim` — 0 methods
- struct `ArenaSim` : NetSim — 6 methods
- struct `InputLog` — 6 methods
- struct `InputValidator` — 1 methods
- struct `LockstepPeer` : NetPeer — 6 methods
- struct `PlayerInput` : Equatable — 4 methods
- struct `PoseRing` — 2 methods
- struct `RollbackPeer` : NetPeer — 7 methods
- struct `SimLink` — 2 methods
- struct `SnapshotClient` : NetPeer — 6 methods
- struct `SnapshotServer` : NetPeer — 6 methods
- `def decode_inputs(msg: List[UInt8]) -> _Decoded`
- `def delta_decode(data: List[UInt8], mut pos: Int, base: List[UInt8]) -> List[UInt8]`
- `def delta_encode(cur: List[UInt8], base: List[UInt8]) -> List[UInt8]`
- `def encode_inputs(from_node: Int, log: InputLog, player: Int, first: Int, last: Int, ack: Int, hash_tick: Int, hash: UInt64) -> List[UInt8]`
- `def fnv_bodies(sc: ContactScene6[QuatBody6], tick: Int) -> UInt64`
- `def get_int(data: List[UInt8], mut pos: Int) -> Int`
- `def get_u64(data: List[UInt8], mut pos: Int) -> UInt64`
- `def get_u8(data: List[UInt8], mut pos: Int) -> UInt8`
- `def motion_plausible(p0: SIMD[.float32, 4], p1: SIMD[.float32, 4], ticks: Int, dt: Float32, max_speed: Float32, slack: Float32 = 1.2) -> Bool`
- `def put_int(mut out: List[UInt8], v: Int)`
- `def put_u64(mut out: List[UInt8], v: UInt64)`
- `def rewind_ray_cast(sc: ContactScene6[QuatBody6], ring: PoseRing, tick: Int, origin: SIMD[.float32, 4], dir: SIMD[.float32, 4], max_t: Float32, f: QueryFilter) -> Hit`
- `def run_offline[S: NetSim](mut sim: S, log: InputLog, until: Int)`
- aliases: `INPUT_BAD_PLAYER`, `INPUT_CONFLICT`, `INPUT_OK`, `INPUT_TOO_FAR_AHEAD`, `INPUT_TOO_OLD`, `MSG_INPUTS`, `MSG_SNAPSHOT`

### `gameplay/objectives.mojo`
- struct `Objective` — 0 methods
- struct `ObjectiveLog` — 4 methods
- `def on_flag_changes(mut log: ObjectiveLog, mut flags: Flags, base: Int) -> Int`
- aliases: `DISPATCH_INDEXED`, `DISPATCH_LINEAR`

### `gameplay/phys_character.mojo`
- struct `DynamicCharacter` — 2 methods

### `gameplay/projectile.mojo`
- struct `ProjectileHit` — 0 methods
- struct `ProjectileSet` — 6 methods
- `def lead_direction(shooter: SIMD[.float32, 4], speed: Float32, target: SIMD[.float32, 4], target_vel: SIMD[.float32, 4]) -> Vec3`
- aliases: `DRAG_LINEAR`, `DRAG_QUADRATIC`, `HIT_FUSE`, `HIT_PENETRATE`, `HIT_RICOCHET`, `HIT_STOP`

### `gameplay/ragdoll.mojo`
- struct `Ragdoll` — 6 methods
- `def blend_world(anim_world: Pose, phys_world: Pose, w: Float32) -> Pose`

### `gameplay/ragdoll_ctl.mojo`
- struct `BalanceResult` — 0 methods
- struct `RagdollModes` — 4 methods
- `def balance_assist(mut sc: ContactScene6[QuatBody6], rd: Ragdoll, support: List[SIMD[.float32, 4]], ground_y: Float32, g: Float32, kp: Float32, kd: Float32, max_force: Float32) -> BalanceResult`
- `def grab(mut sc: ContactScene6[QuatBody6], hand: BodyId, obj: BodyId, break_force: Float32, break_torque: Float32) -> Int`
- `def release(mut sc: ContactScene6[QuatBody6], joint: Int)`
- `def segment_masses(total: Float32, halves: List[SIMD[.float32, 4]]) -> List[Float32]`
- aliases: `MODE_ACTIVE`, `MODE_GETUP`, `MODE_LIMP`, `MODE_STUMBLE`

### `gameplay/replay.mojo`
- struct `InputFrame` — 0 methods
- struct `Recorder` — 1 methods
- struct `SimState` — 0 methods
- struct `Snapshot` — 0 methods
- `def checksum(st: SimState) -> UInt64`
- `def first_divergence(rec: Recorder, dt: Float32, gravity: SIMD[.float32, 4]) -> Int`
- `def ghost(rec: Recorder, dt: Float32, gravity: SIMD[.float32, 4]) -> List[SIMD[.float32, 4]]`
- `def replay_from_start(rec: Recorder, until: Int, dt: Float32, gravity: SIMD[.float32, 4]) -> SimState`
- `def restore(snap: Snapshot) -> SimState`
- `def seek(rec: Recorder, until: Int, dt: Float32, gravity: SIMD[.float32, 4]) -> SimState`
- `def sim_tick(mut st: SimState, inp: InputFrame, dt: Float32, gravity: SIMD[.float32, 4])`
- `def take(st: SimState) -> Snapshot`
- aliases: `EV_PICKUP`

### `gameplay/rules.mojo`
- struct `Actor` — 1 methods
- struct `Attributes` — 6 methods
- struct `EffectDef` — 0 methods
- struct `EffectInst` — 0 methods
- struct `Modifier` — 0 methods
- struct `Rules` — 5 methods
- struct `TagRegistry` — 2 methods
- `def actor_from_bytes(b: List[UInt8]) -> Actor`
- `def actor_to_bytes(a: Actor) -> List[UInt8]`
- aliases: `EVAL_DIRTY`, `EVAL_FULL`, `EVAL_INCREMENTAL`, `FX`, `KIND_DURATION`, `KIND_INFINITE`, `KIND_INSTANT`, `KIND_PERIODIC`, `OP_ADD`, `OP_MUL`, `OP_OVERRIDE`, `STACK_COUNT`, `STACK_REFRESH`

### `gameplay/rules_ecs.mojo`
- struct `Buff` : ComponentType — 0 methods
- struct `Dot` : ComponentType — 0 methods
- struct `Life` : ComponentType — 0 methods
- struct `Stat` : ComponentType — 0 methods
- `def health[B: StorageBackend](w: World[B], e: Entity) -> Int`
- `def is_dead[B: StorageBackend](w: World[B], e: Entity) -> Bool`
- `def spawn_actor[B: StorageBackend](mut w: World[B], base: Int, hp: Int, buff_mul: Int, buff_duration: Int, dot_amount: Int, dot_period: Int, dot_duration: Int) -> Entity`
- `def speed[B: StorageBackend](w: World[B], e: Entity) -> Int`
- `def tick_once[B: StorageBackend](mut w: World[B], tick: Int)`
- aliases: `ID`

### `gameplay/rules_table.mojo`
- `def load_abilities(text: String, mut ab: Abilities, mut reg: TagRegistry, attrs: List[String], dtypes: List[String], effects: Dict[String, Int], mut names: Dict[String, Int])`
- `def load_effects(text: String, mut rules: Rules, mut reg: TagRegistry, attrs: List[String], mut names: Dict[String, Int])`
- `def load_records[T: Copyable & Deinitable](text: String, template: T, schema: TypeSchema, enums: Dict[String, List[String]], tag_fields: List[String], mut reg: TagRegistry) -> List[Tuple[String, T]]`

### `gameplay/runtime.mojo`
- struct `RigidBodyRef` : ComponentType — 0 methods
- struct `Runtime` — 32 methods
- struct `StepHandle` — 0 methods
- aliases: `ID`

### `gameplay/save.mojo`
- struct `BodyRecord` — 0 methods
- struct `SaveReader` — 3 methods
- struct `SaveWriter` — 3 methods
- `def load_bodies(mut sc: ContactScene6[QuatBody6], recs: List[BodyRecord]) -> Int`
- `def save_bodies(sc: ContactScene6[QuatBody6]) -> List[BodyRecord]`
- aliases: `SAVE_FORMAT`

### `gameplay/sequence_player.mojo`
- struct `BodyBinding` — 0 methods
- struct `SeqEvent` — 0 methods
- struct `SequencePlayer` — 2 methods

### `gameplay/skin_link.mojo`
- `def animator_palette(anims: Animators, slot: Int, parent: List[Int], inverse_bind: List[Motor3]) -> List[Motor3]`
- `def fit_bone_boxes(bind: Pose, rest: List[SIMD[.float32, 4]], idx: List[Int], w: List[Float32], k: Int, threshold: Float32 = 0.5) -> Tuple[List[SIMD[.float32, 4]], List[SIMD[.float32, 4]]]`
- `def fit_bone_capsules(bind: Pose, rest: List[SIMD[.float32, 4]], idx: List[Int], w: List[Float32], k: Int, threshold: Float32 = 0.5) -> Tuple[List[SIMD[.float32, 4]], List[SIMD[.float32, 4]], List[Float32]]`
- `def pin_cloth_to_skin(mut cloth: MeshCloth, cloth_vert: List[Int], skin_vert: List[Int], skinned: List[SIMD[.float32, 4]], dt: Float32)`
- `def pin_fem_to_skin(mut body: FemBody, nodes: List[Int], skin_vert: List[Int], skinned: List[SIMD[.float32, 4]])`
- `def pin_softbody_to_skin(mut body: SoftBody, pts: List[Int], skin_vert: List[Int], skinned: List[SIMD[.float32, 4]], dt: Float32)`

### `gameplay/terrain_stream.mojo`
- struct `TerrainStreamer` — 1 methods
- `def generate_tiles(txs: List[Int], tzs: List[Int], nx: Int, nz: Int, cell: Float32, p: TerrainParams, d: Dispatch, workers: Int = Int(0)) -> List[List[Float32]]`

### `gameplay/tiers.mojo`
- trait `TierPolicy` — 0 methods
- struct `AggregateTiers` : TierPolicy — 1 methods
- struct `BudgetTiers` : TierPolicy — 2 methods
- struct `CausalReach` : TierPolicy — 1 methods
- struct `ClusterProxy` — 0 methods
- struct `DistanceTiers` : TierPolicy — 2 methods
- struct `RoundRobin` : TierPolicy — 1 methods
- struct `Tier` : ComponentType — 0 methods
- aliases: `ID`

### `gameplay/vehicle.mojo`
- struct `Aero` — 3 methods
- struct `SuspensionConfig` — 0 methods
- struct `Vehicle` — 12 methods
- struct `VehicleConfig` — 2 methods
- struct `VehicleInput` — 1 methods
- struct `VehicleSet` — 2 methods
- struct `WheelConfig` — 0 methods
- struct `WheelState` — 1 methods
- `def chassis_body(cfg: VehicleConfig, pos: SIMD[.float32, 4], rot: Quat) -> QuatBody6`
- `def spawn_chassis(mut sc: ContactScene6[QuatBody6], cfg: VehicleConfig, pos: SIMD[.float32, 4], rot: Quat = Quat.identity()) -> BodyId`

### `gameplay/vehicle_drive.mojo`
- struct `DriveConfig` — 3 methods
- struct `TorqueCurve` — 4 methods
- `def split_axle(kind: Int, torque: Float32, w_left: Float32, w_right: Float32, preload: Float32, lock: Float32, max_bias: Float32) -> Tuple[Float32, Float32]`
- aliases: `DIFF_LOCKED`, `DIFF_LSD`, `DIFF_OPEN`, `RAD_S_TO_RPM`

### `gameplay/vehicle_element.mojo`
- struct `VehicleElement` : ForceElement — 1 methods

### `gameplay/vehicle_kinds.mojo`
- struct `QuadController` — 1 methods
- struct `QuadRotor` : ForceElement — 3 methods
- struct `TrackDrive` : ForceElement — 5 methods
- `def hitch(mut sc: ContactScene6[QuatBody6], tractor: BodyId, trailer: BodyId, point: SIMD[.float32, 4]) -> Int`

### `gameplay/vehicle_seat.mojo`
- struct `Seat` — 4 methods

### `gameplay/vehicle_tire.mojo`
- struct `TireCurve` — 3 methods
- struct `TireModel` — 2 methods
- `def solve_axis(tire: TireModel, on_x: Bool, a: Float32, b: Float32, other_s: Float32, den: Float32, mu_eff: Float32, fz: Float32) -> Real`

### `gameplay/vehicle_tunnel.mojo`
- struct `CarShape` — 2 methods
- struct `PolarPoint` — 0 methods
- struct `TunnelResult` — 0 methods
- `def car_cd(shape: CarShape, nx: Int = Int(48), ny: Int = Int(24), nz: Int = Int(24), u: Float32 = 0.050000000000000003, nu: Float32 = 0.02, steps: Int = Int(800), avg: Int = Int(200)) -> TunnelResult`
- `def plate_polar(alpha: Float32, chord: Int = Int(16), nx: Int = Int(112), ny: Int = Int(96), nz: Int = Int(4), u: Float32 = 0.050000000000000003, nu: Float32 = 0.02, steps: Int = Int(2400), avg: Int = Int(300)) -> PolarPoint`
- `def scaled_cd(measured: Float32, reference_measured: Float32, reference_real: Float32) -> Real`

### `gameplay/vehicle_wheel.mojo`
- trait `WheelCast` — 0 methods
- struct `CapsuleWheel` : WheelCast — 1 methods
- struct `RayWheel` : WheelCast — 1 methods
- struct `SphereWheel` : WheelCast — 1 methods
- struct `WheelHit` — 1 methods

### `gameplay/watercraft.mojo`
- struct `HullBuoyancy` : ForceElement — 2 methods
- struct `Rudder` : ForceElement — 2 methods

## embed (layer 6) — 6 modules, 154 public declarations

### `embed/capi.mojo`
- `def ld_abi_version() -> UInt32`
- `def ld_body_add_box(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], px: Float32, py: Float32, pz: Float32, hx: Float32, hy: Float32, hz: Float32, mass: Float32, is_static: Int32) -> Int64`
- `def ld_body_add_sphere(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], px: Float32, py: Float32, pz: Float32, r: Float32, mass: Float32, is_static: Int32) -> Int64`
- `def ld_body_alive(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64) -> Int32`
- `def ld_body_apply_impulse(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, jx: Float32, jy: Float32, jz: Float32) -> Int32`
- `def ld_body_get_material(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, dst: Optional[Pointer[UInt32, MutAnyOrigin]]) -> Int32`
- `def ld_body_get_state(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, out13: Optional[Pointer[Float32, MutAnyOrigin]]) -> Int32`
- `def ld_body_get_user(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, dst: Optional[Pointer[UInt64, MutAnyOrigin]]) -> Int32`
- `def ld_body_remove(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64) -> Int32`
- `def ld_body_set_layer(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, category: UInt32, mask: UInt32) -> Int32`
- `def ld_body_set_material(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, material: UInt32) -> Int32`
- `def ld_body_set_user(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, user: UInt64) -> Int32`
- `def ld_body_set_velocity(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, vx: Float32, vy: Float32, vz: Float32, wx: Float32, wy: Float32, wz: Float32) -> Int32`
- `def ld_body_teleport(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], b: Int64, px: Float32, py: Float32, pz: Float32, qx: Float32, qy: Float32, qz: Float32, qw: Float32) -> Int32`
- `def ld_counter_count() -> Int64`
- `def ld_counter_name(id: Int32, buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_nav_bake(verts_xyz: Optional[Pointer[Float32, MutAnyOrigin]], nverts: Int64, tris: Optional[Pointer[Int32, MutAnyOrigin]], nidx: Int64, cfg7: Optional[Pointer[Float32, MutAnyOrigin]], out_nav: Optional[Pointer[Pointer[NoneType, MutUntrackedOrigin], MutAnyOrigin]]) -> Int32`
- `def ld_nav_destroy(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int32`
- `def ld_nav_find_path(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], sx: Float32, sy: Float32, sz: Float32, gx: Float32, gy: Float32, gz: Float32, out_xyz: Optional[Pointer[Float32, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_nav_last_error(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_nav_poly_count(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_add_fracture_box(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], px: Float32, py: Float32, pz: Float32, hx: Float32, hy: Float32, hz: Float32, pieces: Int32, seed: Int32, stress: Float32, density: Float32, first: Optional[Pointer[Int64, MutAnyOrigin]]) -> Int64`
- `def ld_world_add_system(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], phase: Int32, f: def(Optional[Pointer[NoneType, MutUntrackedOrigin]], Float64, Int64, Optional[Pointer[NoneType, MutUntrackedOrigin]]) abi("C") thin -> Int32, user: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_add_water(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], nx: Int32, ny: Int32, cell: Float32, x0: Float32, y0: Float32, x1: Float32, y1: Float32, seed: Int32) -> Int64`
- `def ld_world_bind_thread(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], on: Int32) -> Int32`
- `def ld_world_body_count(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_bubble_event_count(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_capture_begin(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], key_every: Int32) -> Int32`
- `def ld_world_capture_end(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int32`
- `def ld_world_capture_read(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_capture_size(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_create(dt: Float64, gx: Float32, gy: Float32, gz: Float32, out_world: Optional[Pointer[Pointer[NoneType, MutUntrackedOrigin], MutAnyOrigin]]) -> Int32`
- `def ld_world_destroy(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int32`
- `def ld_world_event_count(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_export_frame(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_find_user(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], user: UInt64) -> Int64`
- `def ld_world_fracture_event_count(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_frame_size(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_get_bodies(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], handles: Optional[Pointer[Int64, MutAnyOrigin]], poses7: Optional[Pointer[Float32, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_get_bubble_events(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], dst: Optional[Pointer[Int64, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_get_counters(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], values: Optional[Pointer[Int64, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_get_events(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], dst: Optional[Pointer[Int64, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_get_events_ex(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], dst: Optional[Pointer[Int64, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_get_fracture_events(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], dst: Optional[Pointer[Int64, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_get_fragments(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], dst: Optional[Pointer[Int64, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_hash(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], dst: Optional[Pointer[UInt64, MutAnyOrigin]]) -> Int32`
- `def ld_world_last_error(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_load(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], data: Optional[Pointer[UInt8, MutAnyOrigin]], n: Int64) -> Int32`
- `def ld_world_raycast(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], ox: Float32, oy: Float32, oz: Float32, dx: Float32, dy: Float32, dz: Float32, max_t: Float32, out_body: Optional[Pointer[Int64, MutAnyOrigin]], out_hit7: Optional[Pointer[Float32, MutAnyOrigin]]) -> Int32`
- `def ld_world_raycast_mask(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], ox: Float32, oy: Float32, oz: Float32, dx: Float32, dy: Float32, dz: Float32, max_t: Float32, mask: UInt32, out_body: Optional[Pointer[Int64, MutAnyOrigin]], out_hit7: Optional[Pointer[Float32, MutAnyOrigin]]) -> Int32`
- `def ld_world_remove_system(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], id: Int64) -> Int32`
- `def ld_world_save(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_save_size(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_set_gravity(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], gx: Float32, gy: Float32, gz: Float32) -> Int32`
- `def ld_world_set_poses(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], handles: Optional[Pointer[Int64, MutAnyOrigin]], poses7: Optional[Pointer[Float32, MutAnyOrigin]], n: Int64) -> Int64`
- `def ld_world_set_solver(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], iterations: Int32, substeps: Int32) -> Int32`
- `def ld_world_set_unit_scale(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], per_meter: Float32) -> Int32`
- `def ld_world_step(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], frame_dt: Float64) -> Int32`
- `def ld_world_step_ticks(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], n: Int32) -> Int32`
- `def ld_world_subscribe_contacts(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], kind_mask: Int32, f: def(Optional[Pointer[NoneType, MutUntrackedOrigin]], Pointer[Int64, MutAnyOrigin], Optional[Pointer[NoneType, MutUntrackedOrigin]]) abi("C") thin -> Int32, user: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_tick(h: Optional[Pointer[NoneType, MutUntrackedOrigin]]) -> Int64`
- `def ld_world_transfer_load(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], registered: Optional[Pointer[UInt8, MutAnyOrigin]], data: Optional[Pointer[UInt8, MutAnyOrigin]], n: Int64) -> Int32`
- `def ld_world_transfer_save(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], registered: Optional[Pointer[UInt8, MutAnyOrigin]], buf: Optional[Pointer[UInt8, MutAnyOrigin]], cap: Int64) -> Int64`
- `def ld_world_transfer_size(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], registered: Optional[Pointer[UInt8, MutAnyOrigin]]) -> Int64`
- `def ld_world_unsubscribe(h: Optional[Pointer[NoneType, MutUntrackedOrigin]], id: Int64) -> Int32`
- aliases: `ContactFn`, `F32Ptr`, `Handle`, `HandlePtr`, `I32Ptr`, `I64Ptr`, `LD_EVENT_FLAG_PERSISTENT`, `NPtr`, `SystemFn`, `U64Ptr`, `U8Ptr`, `WPtr`

### `embed/navigation.mojo`
- struct `EmbedNav` — 2 methods

### `embed/scene_io.mojo`
- struct `BodyProps` — 1 methods
- struct `SceneBody` — 1 methods
- struct `SceneChange` — 0 methods
- struct `SceneDoc` — 0 methods
- struct `SceneField` — 0 methods
- struct `SceneJoint` — 0 methods
- struct `SceneMaterial` — 0 methods
- `def add_body_record(mut world: EmbedWorld, s: SceneBody) -> Int64`
- `def body_equal(a: SceneBody, b: SceneBody) -> Bool`
- `def body_record(world: EmbedWorld, h: Int64) -> SceneBody`
- `def export_body(world: EmbedWorld, i: Int) -> SceneBody`
- `def export_scene(world: EmbedWorld) -> SceneDoc`
- `def import_scene(mut world: EmbedWorld, doc: SceneDoc)`
- `def restore_body(mut world: EmbedWorld, h: Int64, s: SceneBody)`
- `def same_shape(a: SceneBody, b: SceneBody) -> Bool`
- `def scene_apply(base: List[SceneField], changes: List[SceneChange]) -> List[SceneField]`
- `def scene_diff(a: List[SceneField], b: List[SceneField]) -> List[SceneChange]`
- `def scene_from_fields(fields: List[SceneField]) -> SceneDoc`
- `def scene_to_fields(doc: SceneDoc) -> List[SceneField]`
- `def write_body_record(mut world: EmbedWorld, h: Int64, s: SceneBody)`
- aliases: `BODY_BOX`, `BODY_CAPSULE`, `BODY_SPHERE`, `CHANGE_ADDED`, `CHANGE_CHANGED`, `CHANGE_REMOVED`, `SCENE_FORMAT_VERSION`

### `embed/transfer.mojo`
- struct `TransferInfo` — 0 methods
- `def settings_hash(world: EmbedWorld) -> UInt64`
- `def transfer_check(world: EmbedWorld, blob: List[UInt8], registered: List[String]) -> Int`
- `def transfer_info(blob: List[UInt8]) -> TransferInfo`
- `def transfer_load(mut world: EmbedWorld, blob: List[UInt8], registered: List[String])`
- `def transfer_save(world: EmbedWorld, registered: List[String]) -> List[UInt8]`
- `def transfer_status_name(status: Int) -> String`
- aliases: `TRANSFER_MAGIC`, `TRANSFER_VERSION`, `XFER_CORRUPT`, `XFER_MAGIC`, `XFER_OK`, `XFER_REGISTRATION`, `XFER_SCALAR`, `XFER_SETTINGS`, `XFER_TRUNCATED`, `XFER_VERSION`

### `embed/undo.mojo`
- struct `BodyRec` — 0 methods
- struct `SnapshotUndo` — 7 methods
- struct `SolverFlags` — 0 methods
- struct `Transaction` — 1 methods
- struct `UndoLog` — 12 methods
- `def read_flags(world: EmbedWorld) -> SolverFlags`
- `def write_flags(mut world: EmbedWorld, f: SolverFlags)`

### `embed/world.mojo`
- struct `BodyState` — 0 methods
- struct `BubbleRec` — 0 methods
- struct `EmbedWorld` — 44 methods
- struct `FractureRec` — 0 methods
- struct `RayResult` — 0 methods
- struct `TickEvent` — 0 methods
- `def fnv1a(data: List[UInt8]) -> UInt64`
- `def pack_body(id: BodyId) -> Int64`
- `def unpack_body(h: Int64) -> BodyId`
- aliases: `ABI_MAJOR`, `ABI_MINOR`, `EVENT_BEGAN`, `EVENT_ENDED`, `EVENT_STAY`, `LD_ERR_ARG`, `LD_ERR_BUFFER`, `LD_ERR_CALLBACK`, `LD_ERR_FORMAT`, `LD_ERR_HANDLE`, `LD_ERR_STALE`, `LD_ERR_STATE`, `LD_ERR_THREAD`, `LD_OK`, `PHASE_POST`, `PHASE_PRE`

## oop (layer 6) — 2 modules, 8 public declarations

### `oop/engine.mojo`
- struct `FatObject` — 1 methods
- struct `FatScene` — 4 methods
- struct `GameObject` — 2 methods
- struct `Scene` — 6 methods
- aliases: `PAYLOAD_WORDS`

### `oop/rules_oop.mojo`
- struct `OopCharacter` — 5 methods
- struct `OopEffect` — 0 methods
- aliases: `FX`

## harness (layer infra) — 4 modules, 19 public declarations

### `harness/bench.mojo`
- struct `ABResult` — 2 methods
- struct `BenchRow` — 2 methods
- struct `BenchTable` — 3 methods
- `def measure[F: def() -> None](body: F, warmup: Int = Int(3), reps: Int = Int(20)) -> Int`
- `def measure_ab[FA: def() -> None, FB: def() -> None](a: FA, b: FB, rounds: Int = Int(15), warmup: Int = Int(3)) -> ABResult`
- `def now() -> Int`

### `harness/gradcheck.mojo`
- trait `GradProblem` — 0 methods
- struct `GradReport` — 1 methods
- `def default_steps() -> List[Float64]`
- `def gradcheck[P: GradProblem](p: P, x: List[Float64], steps: List[Float64]) -> GradReport`
- `def max_rel_diff(a: List[Float64], b: List[Float64]) -> Float64`

### `harness/meshes.mojo`
- struct `MeshData` — 2 methods
- `def box_mesh(hx: Float64, hy: Float64, hz: Float64) -> MeshData`
- `def l_prism(thick: Float64) -> MeshData`
- `def prism(outline: List[Float64], tris: List[Int], z0: Float64, z1: Float64) -> MeshData`
- `def u_prism(thick: Float64) -> MeshData`

### `harness/runner.mojo`
- struct `Suite` — 6 methods
- `def fuzz_seed(default: UInt64) -> UInt64`
- aliases: `DEVICE_TAG`
