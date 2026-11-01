/* C host for tests/test_capi.mojo (ROADMAP 12.1).
 *
 * Drives build/libludens.so only through embed/ludens.h and prints
 * "key value" lines that the test compares with a native Mojo run of the
 * same scenario (tests/test_capi.mojo: `scenario`). Keep the two in step.
 */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ludens.h"

typedef struct {
    ld_body player;
    int64_t pre_calls;
    int64_t post_calls;
    int64_t began;
    int64_t ended;
} host_state;

/* Moves the player around a square: 1 s per side at 3 m/s. */
static int32_t drive_player(ld_world* w, double dt, int64_t tick, void* user) {
    (void)dt;
    host_state* s = (host_state*)user;
    static const float vx[4] = {3.0f, 0.0f, -3.0f, 0.0f};
    static const float vz[4] = {0.0f, 3.0f, 0.0f, -3.0f};
    float st[13];
    if (ld_body_get_state(w, s->player, st) != LD_OK) return 1;
    int k = (int)((tick / 60) % 4);
    s->pre_calls++;
    return ld_body_set_velocity(w, s->player, vx[k], st[8], vz[k], 0.0f, 0.0f, 0.0f) == LD_OK ? 0 : 2;
}

static int32_t count_post(ld_world* w, double dt, int64_t tick, void* user) {
    (void)w; (void)dt; (void)tick;
    ((host_state*)user)->post_calls++;
    return 0;
}

static int32_t on_contact(ld_world* w, const ld_contact_event* ev, void* user) {
    (void)w;
    host_state* s = (host_state*)user;
    if (ev->kind == LD_EVENT_BEGAN) s->began++;
    if (ev->kind == LD_EVENT_ENDED) s->ended++;
    return 0;
}

static int32_t destroy_inside(ld_world* w, double dt, int64_t tick, void* user) {
    (void)dt; (void)tick;
    *(int32_t*)user = ld_world_destroy(w);
    return 0;
}

/* Fails on its third call. */
static int32_t fail_third(ld_world* w, double dt, int64_t tick, void* user) {
    (void)w; (void)dt; (void)tick;
    return ++*(int*)user == 3 ? 7 : 0;
}

/* ABI 0.6 (17.90): the same events as ld_contact_event_ex records. */
static int64_t ex_total, ex_impulse, ex_mat7, ex_flag_ok, ex_mismatch, ex_tangent;
static int check_events_ex(ld_world* w, const ld_contact_event* evs, int64_t n) {
    ld_contact_event_ex* ex = (ld_contact_event_ex*)malloc(sizeof(ld_contact_event_ex) * (size_t)(n + 1));
    if (n > 0 && ld_world_get_events_ex(w, ex, n - 1) != LD_ERR_BUFFER) { printf("ex short buffer accepted\n"); return 1; }
    if (ld_world_get_events_ex(w, ex, n) != n) { printf("get_events_ex mismatch\n"); return 1; }
    for (int64_t i = 0; i < n; i++) {
        ex_total++;
        ex_mismatch += !(ex[i].tick == evs[i].tick && ex[i].a == evs[i].a && ex[i].b == evs[i].b &&
                         ex[i].kind == evs[i].kind && ex[i].feature == evs[i].feature);
        ex_impulse += ex[i].normal_impulse > 0.0f;
        ex_mat7 += ex[i].material_a == 7u || ex[i].material_b == 7u;
        ex_flag_ok += (ex[i].flags == (uint32_t)LD_EVENT_FLAG_PERSISTENT) == (ex[i].kind == LD_EVENT_STAY);
        ex_tangent += ex[i].tangent_vel_x != 0.0f || ex[i].tangent_vel_y != 0.0f || ex[i].tangent_vel_z != 0.0f;
    }
    free(ex);
    return 0;
}

/* Reads the last step's event buffer; checks a short buffer is refused. */
static int drain_events(ld_world* w, int64_t* total, int64_t* began) {
    int64_t n = ld_world_event_count(w);
    ld_contact_event* evs = (ld_contact_event*)malloc(sizeof(ld_contact_event) * (size_t)(n + 1));
    if (n > 0 && ld_world_get_events(w, evs, n - 1) != LD_ERR_BUFFER) { printf("short buffer accepted\n"); return 1; }
    if (ld_world_get_events(w, evs, n) != n) { printf("get_events mismatch\n"); return 1; }
    for (int64_t i = 0; i < n; i++) *began += evs[i].kind == LD_EVENT_BEGAN;
    *total += n;
    if (check_events_ex(w, evs, n) != 0) return 1;
    free(evs);
    return 0;
}

/* ABI 0.4 (17.78): worlds on threads */
typedef struct {
    ld_world* w;
    int32_t ticks;
    int32_t rc;
    uint64_t hash;
} job;

static void* run_job(void* p) {
    job* j = (job*)p;
    j->rc = ld_world_step_ticks(j->w, j->ticks);
    ld_world_hash(j->w, &j->hash);
    return NULL;
}

static void* poke(void* p) {
    job* j = (job*)p;
    j->rc = (int32_t)ld_world_tick(j->w);
    return NULL;
}

static ld_world* build(host_state* s) {
    ld_world* w = NULL;
    if (ld_world_create(1.0 / 60.0, 0.0f, -9.8f, 0.0f, &w) != LD_OK) return NULL;
    ld_body_add_box(w, 0.0f, -0.5f, 0.0f, 20.0f, 0.5f, 20.0f, 0.0f, 1);
    for (int i = 0; i < 4; i++)
        for (int k = 0; k < 2; k++)
            ld_body_add_box(w, -3.0f + 2.0f * (float)i, 0.25f + 0.51f * (float)k, 2.0f, 0.25f, 0.25f, 0.25f, 1.0f, 0);
    for (int i = 0; i < 3; i++)
        ld_body_add_sphere(w, -2.0f + 2.0f * (float)i, 1.0f + 0.5f * (float)i, -2.0f, 0.3f, 0.5f, 0);
    s->player = ld_body_add_box(w, 0.0f, 0.4f, 0.0f, 0.4f, 0.4f, 0.4f, 2.0f, 0);
    ld_body_set_material(w, s->player, 7u);
    ld_world_add_system(w, LD_PHASE_PRE, drive_player, s);
    ld_world_add_system(w, LD_PHASE_POST, count_post, s);
    ld_world_subscribe_contacts(w, (1 << LD_EVENT_BEGAN) | (1 << LD_EVENT_ENDED), on_contact, s);
    return w;
}

int main(void) {
    printf("abi %u\n", ld_abi_version());

    /* -- scenario: 120 frames through the accumulator, then 120 fixed ticks */
    host_state s = {0};
    ld_world* w = build(&s);
    if (!w) { printf("create failed\n"); return 1; }
    int64_t frame_events = 0;
    int64_t buffered_began = 0;
    for (int f = 0; f < 120; f++) {
        if (ld_world_step(w, 1.0 / 60.0) < 0) { printf("step failed\n"); return 1; }
        if (drain_events(w, &frame_events, &buffered_began) != 0) return 1;
    }
    int32_t ran = ld_world_step_ticks(w, 120);
    if (drain_events(w, &frame_events, &buffered_began) != 0) return 1;
    uint64_t h = 0;
    ld_world_hash(w, &h);
    printf("ran %d\n", ran);
    printf("evex %lld %lld %lld %lld %lld %lld %zu\n", (long long)ex_total, (long long)ex_mismatch, (long long)ex_impulse,
           (long long)ex_mat7, (long long)ex_flag_ok, (long long)ex_tangent, sizeof(ld_contact_event_ex));
    printf("tick %lld\n", (long long)ld_world_tick(w));
    printf("hash %016llx\n", (unsigned long long)h);
    printf("pre %lld post %lld\n", (long long)s.pre_calls, (long long)s.post_calls);
    printf("began %lld ended %lld buffered_began %lld events %lld\n", (long long)s.began, (long long)s.ended,
           (long long)buffered_began, (long long)frame_events);
    float st[13];
    ld_body_get_state(w, s.player, st);
    printf("player %.6f %.6f %.6f\n", st[0], st[1], st[2]);
    printf("bodies %lld\n", (long long)ld_world_body_count(w));

    /* -- queries */
    ld_body hit_body = -1;
    float hit[7];
    int32_t r = ld_world_raycast(w, 0.0f, 5.0f, -2.0f, 0.0f, -1.0f, 0.0f, 20.0f, &hit_body, hit);
    printf("ray %d body %lld t %.4f\n", r, (long long)hit_body, hit[0]);
    printf("ray_miss %d\n", ld_world_raycast(w, 0.0f, 5.0f, 0.0f, 0.0f, 1.0f, 0.0f, 20.0f, &hit_body, hit));
    int64_t nb = ld_world_body_count(w);
    ld_body* hs = (ld_body*)malloc(sizeof(ld_body) * (size_t)nb);
    float* ps = (float*)malloc(sizeof(float) * 7 * (size_t)nb);
    int64_t small_rc = ld_world_get_bodies(w, hs, ps, nb - 1);
    int64_t got = ld_world_get_bodies(w, hs, ps, nb);
    printf("get_bodies %lld small %lld\n", (long long)got, (long long)small_rc);
    printf("last_pose_is_player %d\n", hs[nb - 1] == s.player && ps[7 * (nb - 1)] == st[0]);
    free(hs);
    free(ps);

    /* -- save / continue / load / continue: same world */
    int64_t sz = ld_world_save_size(w);
    uint8_t* blob = (uint8_t*)malloc((size_t)sz);
    int64_t save_small = ld_world_save(w, blob, sz - 1);
    int64_t saved = ld_world_save(w, blob, sz);
    printf("save %lld of %lld small %lld\n", (long long)saved, (long long)sz, (long long)save_small);
    ld_world_step_ticks(w, 60);
    uint64_t ha = 0, hb = 0;
    ld_world_hash(w, &ha);
    printf("load %d\n", ld_world_load(w, blob, sz));
    ld_world_step_ticks(w, 60);
    ld_world_hash(w, &hb);
    printf("replay_equal %d\n", ha == hb);
    blob[0] ^= 0xFF;
    printf("load_garbage %d\n", ld_world_load(w, blob, sz));
    printf("load_short %d\n", ld_world_load(w, blob, 5));
    free(blob);

    /* -- error paths */
    char msg[256];
    printf("null_world %d\n", ld_world_step(NULL, 0.1));
    ld_body victim = ld_body_add_sphere(w, 5.0f, 3.0f, 5.0f, 0.2f, 1.0f, 0);
    int32_t rm1 = ld_body_remove(w, victim);
    int32_t rm2 = ld_body_remove(w, victim);
    printf("remove %d again %d\n", rm1, rm2);
    ld_body reuse = ld_body_add_sphere(w, 5.0f, 3.0f, 5.0f, 0.2f, 1.0f, 0);
    printf("slot_reused %d stale_alive %d new_alive %d\n", (int)((reuse & 0xFFFFFFFF) == (victim & 0xFFFFFFFF)),
           ld_body_alive(w, victim), ld_body_alive(w, reuse));
    printf("stale_velocity %d\n", ld_body_set_velocity(w, victim, 1, 0, 0, 0, 0, 0));
    printf("nan_box %lld\n", (long long)ld_body_add_box(w, NAN, 0, 0, 1, 1, 1, 1, 0));
    int64_t len = ld_world_last_error(w, msg, sizeof msg);
    printf("msg_len_ok %d\n", len > 0 && (int64_t)strlen(msg) == (len < 255 ? len : 255));
    printf("zero_mass %lld\n", (long long)ld_body_add_sphere(w, 0, 0, 0, 1, 0, 0));
    printf("bad_phase %lld\n", (long long)ld_world_add_system(w, 9, count_post, NULL));
    printf("null_out %d\n", ld_body_get_state(w, s.player, NULL));
    /* ABI 0.3: physics capture */
    printf("capture_bad %d\n", ld_world_capture_begin(w, 0));
    ld_world_capture_begin(w, 10);
    ld_world_step_ticks(w, 25);
    ld_world_capture_end(w);
    ld_world_step_ticks(w, 5);
    int64_t csize = ld_world_capture_size(w);
    uint8_t* cbuf = (uint8_t*)malloc((size_t)csize);
    int64_t cread = ld_world_capture_read(w, cbuf, csize);
    int64_t cframes = 0;
    memcpy(&cframes, cbuf + 24, 8);
    printf("capture_read_all %d\n", csize > 32 && cread == csize);
    printf("capture_frames %lld\n", (long long)cframes);
    printf("capture_small %lld\n", (long long)ld_world_capture_read(w, cbuf, 8));
    free(cbuf);
    printf("bad_dt %d\n", ld_world_create(0.0, 0, 0, 0, &w) == LD_ERR_ARG);
    int calls = 0;
    int64_t t0 = ld_world_tick(w);
    int64_t fid = ld_world_add_system(w, LD_PHASE_PRE, fail_third, &calls);
    int32_t frc = ld_world_step_ticks(w, 10);
    printf("callback_fail %d ticks_done %lld\n", frc, (long long)(ld_world_tick(w) - t0));
    ld_world_remove_system(w, fid);
    int32_t inner = 0;
    ld_world_add_system(w, LD_PHASE_POST, destroy_inside, &inner);
    ld_world_step_ticks(w, 1);
    printf("destroy_inside %d\n", inner);
    printf("destroy %d\n", ld_world_destroy(w));

    /* -- ABI 0.4: two worlds stepped at once on two threads == one alone */
    host_state s1 = {0}, s2 = {0}, s3 = {0};
    ld_world* w1 = build(&s1);
    ld_world* w2 = build(&s2);
    ld_world* w3 = build(&s3);
    uint64_t h3 = 0;
    ld_world_step_ticks(w3, 120);
    ld_world_hash(w3, &h3);
    job j1 = {w1, 120, 0, 0}, j2 = {w2, 120, 0, 0};
    pthread_t t1, t2;
    pthread_create(&t1, NULL, run_job, &j1);
    pthread_create(&t2, NULL, run_job, &j2);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    printf("two_worlds_parallel %d\n", j1.rc == 120 && j2.rc == 120 && j1.hash == h3 && j2.hash == h3);
    /* thread binding */
    ld_world_bind_thread(w1, 1);
    job pk = {w1, 0, 0, 0};
    pthread_create(&t1, NULL, poke, &pk);
    pthread_join(t1, NULL);
    int32_t refused = pk.rc;
    int32_t own = (int32_t)ld_world_tick(w1);
    ld_world_bind_thread(w1, 0);
    pthread_create(&t1, NULL, poke, &pk);
    pthread_join(t1, NULL);
    printf("thread_refused %d own_tick %d after_unbind %d bad_flag %d\n", refused, own, pk.rc, ld_world_bind_thread(w1, 7));
    /* layers and user values */
    ld_body lay_a = ld_body_add_box(w3, 2.0f, 10.0f, 0.0f, 0.5f, 0.5f, 0.5f, 0.0f, 1);
    ld_body lay_b = ld_body_add_box(w3, 4.0f, 10.0f, 0.0f, 0.5f, 0.5f, 0.5f, 0.0f, 1);
    ld_body_set_layer(w3, lay_a, 1u, 0xFFFFFFFFu);
    ld_body_set_layer(w3, lay_b, 2u, 0xFFFFFFFFu);
    ld_body ray_b = -1;
    float rhit[7];
    int32_t ra = ld_world_raycast_mask(w3, 0.0f, 10.0f, 0.0f, 1.0f, 0.0f, 0.0f, 10.0f, 0xFFFFFFFFu, &ray_b, rhit);
    int all_near = ra == 1 && ray_b == lay_a;
    int32_t rb = ld_world_raycast_mask(w3, 0.0f, 10.0f, 0.0f, 1.0f, 0.0f, 0.0f, 10.0f, 2u, &ray_b, rhit);
    int only_far = rb == 1 && ray_b == lay_b;
    printf("mask_ray %d %d none %d\n", all_near, only_far, ld_world_raycast_mask(w3, 0.0f, 10.0f, 0.0f, 1.0f, 0.0f, 0.0f, 10.0f, 4u, &ray_b, rhit));
    ld_body_set_user(w3, s3.player, 0xABCDEF0123ull);
    uint64_t uv = 0;
    ld_body_get_user(w3, s3.player, &uv);
    printf("user %d find %d missing %lld\n", uv == 0xABCDEF0123ull, ld_world_find_user(w3, 0xABCDEF0123ull) == s3.player,
           (long long)ld_world_find_user(w3, 42));
    ld_world_destroy(w1);
    ld_world_destroy(w2);
    ld_world_destroy(w3);

    /* -- navigation: 10 x 10 m floor, wall across x = 0 from z = -5 to z = 3 */
    float verts[] = {-5, 0, -5, 5, 0, -5, 5, 0, 5, -5, 0, 5,
                     -0.2f, 0, -5, 0.2f, 0, -5, 0.2f, 0, 3, -0.2f, 0, 3,
                     -0.2f, 2, -5, 0.2f, 2, -5, 0.2f, 2, 3, -0.2f, 2, 3};
    int32_t tris[] = {0, 2, 1, 0, 3, 2,
                      8, 10, 9, 8, 11, 10,
                      4, 5, 9, 4, 9, 8, 6, 7, 11, 6, 11, 10,
                      5, 6, 10, 5, 10, 9, 7, 4, 8, 7, 8, 11};
    ld_nav* nav = NULL;
    int32_t baked = ld_nav_bake(verts, 12, tris, 36, NULL, &nav);
    printf("nav_bake %d polys_positive %d\n", baked, ld_nav_poly_count(nav) > 0);
    float pts[3 * 64];
    int64_t np = ld_nav_find_path(nav, -3, 0, -3, 3, 0, -3, pts, 64);
    double plen = 0;
    for (int64_t i = 1; i < np; i++) {
        double dx = pts[3 * i] - pts[3 * i - 3], dz = pts[3 * i + 2] - pts[3 * i - 1];
        plen += sqrt(dx * dx + dz * dz);
    }
    printf("nav_points %lld len %.3f\n", (long long)np, plen);
    for (int64_t i = 0; i < np; i++) printf("nav_pt %.3f %.3f %.3f\n", pts[3 * i], pts[3 * i + 1], pts[3 * i + 2]);
    printf("nav_small %lld\n", (long long)ld_nav_find_path(nav, -3, 0, -3, 3, 0, -3, pts, 1));
    int32_t bad_tris[] = {0, 1, 99};
    ld_nav* bad = NULL;
    printf("nav_bad_index %d\n", ld_nav_bake(verts, 12, bad_tris, 3, NULL, &bad));
    printf("nav_destroy %d\n", ld_nav_destroy(nav));
    return 0;
}
