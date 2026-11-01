/* ludens-engine embedding API (ROADMAP 12.1), ABI v0.6.
 *
 * Build the library with `pixi run capi` -> build/libludens.so.
 * Contract (docs/design/12.1-embedding.md):
 *   - v0.x freeze: a declaration below never changes its name, parameter
 *     list, return type or meaning; new functions and new status codes may
 *     be added (minor version bump). `tests/test_capi.mojo` checks every
 *     line of embed/abi_v0.txt is still present here verbatim.
 *   - Units: SI (m, kg, s, rad) unless ld_world_set_unit_scale (0.5) names
 *     another length unit. Right-handed, +Y up for the default gravity the
 *     host passes. Quaternions are x, y, z, w.
 *   - Status: >= 0 success (or a count / handle), < 0 an LD_ERR_* code;
 *     ld_world_last_error() gives the message of the latest failure.
 *   - Threads: a world (and a navmesh) is used from one thread at a time;
 *     different worlds are independent and may step on different threads
 *     at once. ld_world_bind_thread (0.4) makes the rule checked: calls on
 *     a bound world from any other thread return LD_ERR_THREAD.
 *     GPU paths use one device context per process (docs/ARCHITECTURE.md);
 *     the C-ABI worlds are CPU only.
 *   - Callbacks run inside ld_world_step / ld_world_step_ticks and may call
 *     any function on the same world except ld_world_destroy and
 *     ld_world_load (refused with LD_ERR_STATE); a non-zero return stops
 *     the step with LD_ERR_CALLBACK.
 *   - Output buffers are caller-owned; too small -> LD_ERR_BUFFER, nothing
 *     written; the *_count / *_size call gives the size needed.
 */
#ifndef LUDENS_H
#define LUDENS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LD_ABI_MAJOR 0
#define LD_ABI_MINOR 6

#define LD_OK 0
#define LD_ERR_HANDLE (-1)   /* null or destroyed world / navmesh handle */
#define LD_ERR_ARG (-2)      /* invalid argument */
#define LD_ERR_STALE (-3)    /* body handle removed or never issued */
#define LD_ERR_BUFFER (-4)   /* output buffer too small */
#define LD_ERR_FORMAT (-5)   /* save blob truncated or not a world blob */
#define LD_ERR_CALLBACK (-6) /* a host callback returned non-zero */
#define LD_ERR_STATE (-7)    /* refused in the current state */
#define LD_ERR_THREAD (-8)   /* called from a thread other than the bound one (0.4) */

#define LD_PHASE_PRE 0  /* systems run before the physics tick */
#define LD_PHASE_POST 1 /* systems run after it (and after contact subscribers) */

#define LD_EVENT_BEGAN 0
#define LD_EVENT_STAY 1
#define LD_EVENT_ENDED 2

typedef struct ld_world ld_world;
typedef struct ld_nav ld_nav;
typedef int64_t ld_body; /* slot | generation << 32; never negative */

typedef struct ld_contact_event {
    int64_t tick;
    ld_body a;
    ld_body b;
    int64_t kind; /* LD_EVENT_* */
    int64_t feature;
} ld_contact_event;

typedef int32_t (*ld_system_fn)(ld_world* w, double dt, int64_t tick, void* user);
typedef int32_t (*ld_contact_fn)(ld_world* w, const ld_contact_event* ev, void* user);

uint32_t ld_abi_version(void);

int32_t ld_world_create(double dt, float gx, float gy, float gz, ld_world** out_world);
int32_t ld_world_destroy(ld_world* w);
int64_t ld_world_last_error(ld_world* w, char* buf, int64_t cap);
int32_t ld_world_set_solver(ld_world* w, int32_t iterations, int32_t substeps);
int32_t ld_world_set_gravity(ld_world* w, float gx, float gy, float gz);
int64_t ld_world_tick(ld_world* w);

ld_body ld_body_add_box(ld_world* w, float px, float py, float pz, float hx, float hy, float hz, float mass, int32_t is_static);
ld_body ld_body_add_sphere(ld_world* w, float px, float py, float pz, float r, float mass, int32_t is_static);
int32_t ld_body_remove(ld_world* w, ld_body b);
int32_t ld_body_alive(ld_world* w, ld_body b);
int32_t ld_body_set_velocity(ld_world* w, ld_body b, float vx, float vy, float vz, float wx, float wy, float wz);
int32_t ld_body_apply_impulse(ld_world* w, ld_body b, float jx, float jy, float jz);
int32_t ld_body_teleport(ld_world* w, ld_body b, float px, float py, float pz, float qx, float qy, float qz, float qw);
int32_t ld_body_get_state(ld_world* w, ld_body b, float* out13);
int64_t ld_world_body_count(ld_world* w);
int64_t ld_world_get_bodies(ld_world* w, ld_body* handles, float* poses7, int64_t cap);

int32_t ld_world_raycast(ld_world* w, float ox, float oy, float oz, float dx, float dy, float dz, float max_t, ld_body* out_body, float* out_hit7);

int64_t ld_world_add_system(ld_world* w, int32_t phase, ld_system_fn fn, void* user);
int32_t ld_world_remove_system(ld_world* w, int64_t id);
int64_t ld_world_subscribe_contacts(ld_world* w, int32_t kind_mask, ld_contact_fn fn, void* user);
int32_t ld_world_unsubscribe(ld_world* w, int64_t id);
int32_t ld_world_step(ld_world* w, double frame_dt);
int32_t ld_world_step_ticks(ld_world* w, int32_t n);
int64_t ld_world_event_count(ld_world* w);
int64_t ld_world_get_events(ld_world* w, ld_contact_event* out, int64_t cap);

int64_t ld_world_save_size(ld_world* w);
int64_t ld_world_save(ld_world* w, uint8_t* buf, int64_t cap);
int32_t ld_world_load(ld_world* w, const uint8_t* data, int64_t n);
int32_t ld_world_hash(ld_world* w, uint64_t* out);

int32_t ld_nav_bake(const float* verts_xyz, int64_t nverts, const int32_t* tris, int64_t nidx, const float* cfg7, ld_nav** out_nav);
int32_t ld_nav_destroy(ld_nav* n);
int64_t ld_nav_poly_count(ld_nav* n);
int64_t ld_nav_find_path(ld_nav* n, float sx, float sy, float sz, float gx, float gy, float gz, float* out_xyz, int64_t cap);
int64_t ld_nav_last_error(ld_nav* n, char* buf, int64_t cap);

/* ---- 0.2 (ROADMAP 17.78): bulk pose write, diagnostic counters */
int64_t ld_world_set_poses(ld_world* w, const ld_body* handles, const float* poses7, int64_t n);
int64_t ld_counter_count(void);
int64_t ld_counter_name(int32_t id, char* buf, int64_t cap);
int64_t ld_world_get_counters(ld_world* w, int64_t* out, int64_t cap);

/* ---- 0.3 (ROADMAP 17.80): physics capture (physics/capture.mojo file image) */
int32_t ld_world_capture_begin(ld_world* w, int32_t key_every);
int32_t ld_world_capture_end(ld_world* w);
int64_t ld_world_capture_size(ld_world* w);
int64_t ld_world_capture_read(ld_world* w, uint8_t* buf, int64_t cap);

/* ---- 0.4 (ROADMAP 17.78): host mapping -- layers, user data, thread binding */
int32_t ld_world_bind_thread(ld_world* w, int32_t on);
int32_t ld_body_set_layer(ld_world* w, ld_body b, uint32_t category, uint32_t mask);
int32_t ld_world_raycast_mask(ld_world* w, float ox, float oy, float oz, float dx, float dy, float dz, float max_t, uint32_t mask, ld_body* out_body, float* out_hit7);
int32_t ld_body_set_user(ld_world* w, ld_body b, uint64_t user);
int32_t ld_body_get_user(ld_world* w, ld_body b, uint64_t* out);
int64_t ld_world_find_user(ld_world* w, uint64_t user);

/* ---- 0.5 (ROADMAP 17.78): units at the boundary. per_meter host length
 * units make one meter (100: centimetres); positions, sizes, velocities and
 * gravity are then all given in host units, and the solver's absolute
 * length tolerances are rescaled to match. A setting, not saved. */
int32_t ld_world_set_unit_scale(ld_world* w, float per_meter);

/* ---- 0.6 (ROADMAP 17.90): richer contact events. ld_contact_event_ex is 104 bytes:
 * the five ld_contact_event fields, then impulse and kinematics at the contact. */
typedef struct ld_contact_event_ex {
    int64_t tick;
    ld_body a;
    ld_body b;
    int64_t kind;     /* LD_EVENT_* */
    int64_t feature;
    float normal_impulse; /* N s this tick, restitution included; 0 for sensors / ENDED */
    float force;          /* normal_impulse over the time it covers (N) */
    float approach;       /* normal approach speed at contact prep (m/s) */
    float peak;           /* largest normal_impulse since the contact began */
    float point_x; /* contact point carrying most of the impulse */
    float point_y;
    float point_z;
    float normal_x; /* from a to b */
    float normal_y;
    float normal_z;
    float tangent_vel_x; /* velocity of b relative to a at the point, normal part removed (m/s) */
    float tangent_vel_y;
    float tangent_vel_z;
    uint32_t material_a;  /* ld_body_set_material, 0 = none */
    uint32_t material_b;
    uint32_t flags;       /* LD_EVENT_FLAG_* */
} ld_contact_event_ex;
#define LD_EVENT_FLAG_PERSISTENT 1 /* the contact existed on the previous tick (kind == LD_EVENT_STAY) */
int64_t ld_world_get_events_ex(ld_world* w, ld_contact_event_ex* out, int64_t cap);
int32_t ld_body_set_material(ld_world* w, ld_body b, uint32_t material);
int32_t ld_body_get_material(ld_world* w, ld_body b, uint32_t* out);

/* ---- 0.6 (ROADMAP 17.90): a destructible box. pieces welded Voronoi fragments; each weld
 * breaks at stress (Pa) times its seam area and reports a fracture event. One fractured
 * object per world; such a world cannot be saved or loaded (LD_ERR_STATE). Returns the
 * fragment count; first gets the first fragment's handle. */
typedef struct ld_fracture_event {
    int64_t tick;
    int64_t kind; /* LD_FRACTURE_* */
    int64_t bond;
    ld_body a;    /* fragment handle */
    ld_body b;    /* fragment handle, -1 = external body or none */
} ld_fracture_event;
#define LD_FRACTURE_BOND_BROKEN 0
#define LD_FRACTURE_EVICTED 1
int64_t ld_world_add_fracture_box(ld_world* w, float px, float py, float pz, float hx, float hy, float hz, int32_t pieces, int32_t seed, float stress, float density, ld_body* first);
int64_t ld_world_get_fragments(ld_world* w, ld_body* out, int64_t cap);
int64_t ld_world_fracture_event_count(ld_world* w);
int64_t ld_world_get_fracture_events(ld_world* w, ld_fracture_event* out, int64_t cap);

/* ---- 0.6 (ROADMAP 17.90): the frame export stream. ld_world_export_frame writes a
 * little-endian record set to an 8-byte aligned buffer: header 24 B (u32 magic 0x3146444C
 * "LDF1", u32 version 1, i64 body count, i64 tick), then per live body in slot order 72 B:
 * i64 handle, f32 pos[3], f32 rot[4] xyzw, f32 vel[3], f32 omega[3], u32 flags
 * (LD_FRAME_ASLEEP | LD_FRAME_STATIC), u32 material, u32 user (low 32 bits). */
#define LD_FRAME_ASLEEP 1
#define LD_FRAME_STATIC 2
int64_t ld_world_frame_size(ld_world* w);
int64_t ld_world_export_frame(ld_world* w, uint8_t* buf, int64_t cap);

#ifdef __cplusplus
}
#endif

#endif /* LUDENS_H */
