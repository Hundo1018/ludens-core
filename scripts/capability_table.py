"""Core capability x host front door table (ROADMAP 17.97): for each capability a game would use, which core module has it,
and whether the host can reach it: an EmbedWorld method, a C-ABI function, save / hash coverage, a scene_io row, an example.

usage: python3 scripts/capability_table.py            print the table for this checkout (markdown)

The capability list is curated by hand (CAPS below). Every cell after it is found by searching the checkout, so the table
says what the code has, not what someone remembers. A cell is "yes" when its regex matches in the named files. "不適用" marks a column that does not apply (a stateless query has nothing to save or
author); "拒絕" marks a save that is refused on purpose (17.95).
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent


def text(*globs):
    out = ""
    for g in globs:
        for p in sorted(root.glob(g)):
            out += p.read_text(errors="replace") + "\n"
    return out


WORLD = text("embed/world.mojo", "embed/ragdoll.mojo", "embed/navigation.mojo")
CAPI = text("embed/capi.mojo")
SCENE = text("embed/scene_io.mojo")
SAVE_TESTS = text("tests/test_save_coverage.mojo", "tests/test_fracture_save.mojo", "tests/test_capi.mojo")
EXAMPLES = text("examples/*.mojo")

# (category, capability, core module paths (must exist), EmbedWorld regex, C-ABI regex, save/hash regex in tests, scene_io regex,
#  examples regex). None = nothing to search for (the cell is "-").
CAPS = [
    ("剛體", "方塊 / 球", ["physics/rigid6.mojo", "physics/solver6.mojo"], r"def add_box|def add_sphere", r"def ld_body_add_box",
     r'"velocity"', r"SHAPE_SPHERE", r"EmbedWorld"),
    ("剛體", "膠囊", ["physics/solver6.mojo"], r"def add_capsule", r"ld_body_add_capsule", None, r"SHAPE_CAPSULE|capsule", r"add_capsule"),
    ("剛體", "凸殼", ["collision/hull.mojo"], r"def add_convex|def add_hull", r"ld_body_add_(convex|hull)", None, None,
     r"from collision\.hull"),
    ("剛體", "三角網格 / 高度場", ["collision/trimesh.mojo"], r"def add_(mesh|heightfield)",
     r"ld_body_add_(trimesh|heightfield)", None, None, r"heightfield|trimesh"),
    ("剛體", "運動學", ["physics/solver6.mojo"], r"def set_kinematic", r"ld_body_set_kinematic", r'"kinematic"', r"kinematic", r"set_kinematic"),
    ("剛體", "材質(摩擦、柔度)", ["physics/material.mojo"], r"def set_material_friction", r"ld_material_set_friction",
     r'"material_friction"', r"SceneMaterial", r"set_material_friction|physics\.material"),
    ("剛體", "碰撞層", ["physics/solver6.mojo"], r"def set_layer", r"ld_body_set_layer", r'"layer"', r"category", r"set_layer"),
    ("剛體", "連續碰撞(CCD)", ["physics/ccd6.mojo"], r"def set_ccd", r"ld_body_set_ccd", None, r"ccd_mode", r"ccd"),
    ("關節", "球 / 距離 / 鉸鏈 / 焊接", ["physics/joints6.mojo"], r"def add_ball_joint", r"ld_joint_add_(ball|hinge)", r'"joint"',
     r"SceneJoint", r"add_ball_joint|add_hinge_joint"),
    ("關節", "限制 / 馬達 / 彈簧 / 滑軌 / cone-twist", ["physics/joint_ext.mojo"], r"def (set_joint_limit|set_joint_motor|add_slider)",
     r"ld_joint_set_(limits|motor)", None, None, r"joint_ext"),
    ("關節", "縮座標關節鏈", ["physics/chain.mojo", "physics/chain_scene.mojo"], r"def add_chain", r"ld_world_add_chain", None, None,
     r"from physics\.chain"),
    ("破壞", "預先破碎的物件", ["physics/fracture.mojo"], r"def add_fracture_box", r"ld_world_add_fracture_box", r"fracture_save",
     None, r"add_fracture_box|physics\.fracture"),
    ("可變形", "繩 / 纜", ["physics/rope.mojo"], r"def add_rope", r"ld_world_add_rope", None, None, r"physics\.rope"),
    ("可變形", "布料", ["physics/cloth.mojo"], r"def add_cloth", r"ld_world_add_cloth", None, None, r"physics\.cloth"),
    ("可變形", "XPBD 軟體", ["physics/softbody.mojo"], r"def add_soft", r"ld_world_add_soft", None, None, r"physics\.softbody"),
    ("可變形", "FEM 體", ["physics/fem.mojo", "physics/fem_scene.mojo"], r"def add_fem", r"ld_world_add_fem", None, None,
     r"physics\.fem"),
    ("可變形", "頭髮 / Cosserat 桿", ["physics/strand.mojo", "physics/cosserat_rod.mojo"], r"def add_(strand|rod)",
     r"ld_world_add_(strand|rod)", None, None, r"physics\.(strand|cosserat)"),
    ("流體", "2D FLIP 水(氣泡事件)", ["physics/flip.mojo", "physics/flip_diffuse.mojo"], r"def add_water", r"ld_world_add_water",
     "REFUSED", None, r"physics\.flip\b|add_water"),
    ("流體", "3D 水(FLIP / level set)", ["physics/flip3.mojo", "physics/mac_levelset3.mojo"], r"def add_water3|flip3",
     r"ld_world_add_water3", None, None, r"flip3|levelset3"),
    ("流體", "粒子流體與剛體耦合(SPH / PBF)", ["physics/sph_rigid.mojo", "physics/pbf_unified.mojo"], r"\bsph_\w|\bpbf_\w|def add_(sph|pbf)\(", r"ld_world_add_(sph|pbf)",
     None, None, r"physics\.(sph|pbf)"),
    ("流體", "MPM(雪、沙、熔化)", ["physics/mpm.mojo", "physics/mpm_rigid.mojo"], r"\bmpm", r"ld_world_add_mpm", None, None,
     r"physics\.mpm"),
    ("流體", "格子氣流(LBM)與剛體", ["fluid/lbm.mojo", "physics/fsi.mojo"], r"\blbm|\bfsi", r"ld_world_add_(lbm|air)", None, None,
     r"fluid\.lbm|physics\.fsi"),
    ("流體", "浮力 / 力場 / 水面浮體", ["physics/water.mojo", "physics/fields.mojo"], r"def add_(field|water_surface|buoyan)",
     r"ld_world_add_(field|buoyan)", None, None, r"physics\.(water|fields)"),
    ("其他物理", "熱 / 燃燒", ["physics/thermal.mojo", "physics/combustion.mojo"], r"thermal|combust", r"ld_world_add_(heat|fire)",
     None, None, r"physics\.(thermal|combustion)"),
    ("其他物理", "可微模擬", ["physics/diffsim.mojo", "physics/diffrigid.mojo"], r"def \w*grad\w*\(", r"ld_world_grad", None, None,
     r"physics\.diff"),
    ("其他物理", "GPU 物理(接觸、布料、LBM)", ["physics/gpu_contact.mojo", "physics/gpu_cloth.mojo"], r"\bgpu", r"ld_world_\w*gpu",
     None, None, r"gpu_contact|gpu_cloth|lbm_gpu"),
    ("查詢", "射線", ["collision/queries.mojo", "collision/world_query.mojo"], r"def raycast", r"ld_world_raycast", "N/A", "N/A", r"raycast"),
    ("查詢", "重疊 / 掃掠", ["collision/queries.mojo", "collision/world_query.mojo"], r"def (overlap|sweep)", r"ld_world_(overlap|sweep)", "N/A", "N/A",
     r"overlap|sweep"),
    ("gameplay", "布娃娃", ["gameplay/ragdoll.mojo", "embed/ragdoll.mojo"], r"struct EmbedRagdoll", r"ld_\w*ragdoll", None, None,
     r"ragdoll"),
    ("gameplay", "角色控制(動態膠囊)", ["gameplay/phys_character.mojo"], r"def add_character|DynamicCharacter", r"ld_\w*character",
     None, None, r"phys_character"),
    ("gameplay", "載具 / 船 / 飛行器", ["gameplay/vehicle.mojo", "gameplay/watercraft.mojo", "gameplay/aircraft.mojo"],
     r"def add_vehicle", r"ld_\w*vehicle", None, None, r"vehicle"),
    ("gameplay", "世界分區串流", ["gameplay/large_world.mojo"], r"WorldPartition|def add_partition", r"ld_\w*partition", None, None,
     r"large_world"),
    ("導航", "navmesh 烘焙與尋路", ["nav/"], r"struct EmbedNav", r"ld_nav_bake", None, None, r"from nav\."),
]


def has(rx, src):
    return rx is not None and re.search(rx, src) is not None


def cell(b):
    if isinstance(b, str):
        return b
    return "✓" if b else "—"


rows = []
for cat, name, mods, rw, rc, rs, rsc, rex in CAPS:
    missing = [m for m in mods if not (root / m).exists()]
    in_world = has(rw, WORLD)
    rows.append((cat, name, ", ".join(f"`{m}`" for m in mods), "；".join(missing), in_world, has(rc, CAPI),
                 ("拒絕" if rs == "REFUSED" else "不適用" if rs == "N/A" else in_world and has(rs, SAVE_TESTS)),
                 "不適用" if rsc == "N/A" else has(rsc, SCENE), has(rex, EXAMPLES)))

print("| 類別 | 能力 | core 模組 | EmbedWorld | C-ABI | 存檔 / 雜湊測試 | scene_io | 範例 |")
print("|---|---|---|:-:|:-:|:-:|:-:|:-:|")
for cat, name, mods, missing, w, c, s, sc, ex in rows:
    note = f"(找不到:{missing})" if missing else ""
    print(f"| {cat} | {name} | {mods}{note} | {cell(w)} | {cell(c)} | {cell(s)} | {cell(sc)} | {cell(ex)} |")
n = len(rows)
print()
print(f"能力 {n} 項:EmbedWorld {sum(r[4] for r in rows)}、C-ABI {sum(r[5] for r in rows)}、存檔 / 雜湊測試 {sum(r[6] is True for r in rows)}、"
      f"scene_io {sum(r[7] is True for r in rows)}、範例 {sum(r[8] for r in rows)}")
