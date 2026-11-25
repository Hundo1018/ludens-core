# LudensEngine 的範疇論結構

引擎的「swap seam」架構不是偶然好用 —— 它是一組範疇論結構的具體實作。本文把既有
的 trait seam、parity 測試與 GA 數學層放進同一張圖,並指出哪些「定律」已由測試
機械化(`tests/test_laws.mojo` 與各 parity 套件)。

## 1. 基本圖景

- **對象(objects)**:世界狀態 —— `World[B]` 的完整元件內容(以查詢可觀察的
  值語意呈現,與 backend 無關)。
- **態射(morphisms)**:系統 —— `World → World` 的狀態轉移(movement、
  integrate、propagate、despawn⋯)。恆等態射 = 空系統;合成 = 依序執行。
  這構成範疇 **𝑾**(對象 = 世界狀態,態射 = 系統)。

## 2. Seam = 函子;parity 測試 = 自然性方格

每個 `StorageBackend` 決定一個「實作函子」`F_B : 𝑾 → Set`:把抽象世界狀態送到
該 backend 的具體儲存,把每個系統送到它在該儲存上的執行。兩個 backend 之間的
「swap」是自然變換 `η : F_sparse ⇒ F_archetype`(由值語意的 get/set 給出的逐
對象轉換)。

**自然性方格**(對每個系統 f):

```
F_sparse(W) ──F_sparse(f)──▶ F_sparse(W')
     │                             │
     η_W                           η_W'
     ▼                             ▼
F_arch(W) ───F_arch(f)────▶  F_arch(W')
```

「先換 backend 再跑系統」=「先跑系統再換 backend」。**這正是
`test_backend_parity` 逐值斷言的內容** —— 6 個 backend 對同一場景產生相同的查
詢計數與聚合值。同理:

| Seam(trait) | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `StorageBackend`(sparse-set / archetype / bitset / reactive / chunked / naive) | ecs/storage.mojo、chunked_backend.mojo | 實作函子間的自然同構 | `test_backend_parity`、`test_iter_parity` | `bench_ecs`、`bench_locality`、`bench_chunked` |
| 傳播策略 full/dirty/**motor** | ecs/transform_systems.mojo、ecs/motor_transform.mojo | 同一態射的三個實作;dirty 是 full 的等價優化 | `test_transform`、`test_motor_transform` | `bench_transform` |
| `Scheduler`(sequential / system-actor / entity-actor)×(serial/parallel) | scheduler/scheduler.mojo、system_actor.mojo、entity_actor.mojo | 態射合成的不同求值策略(直接迭代 vs mailbox dataflow),世界逐位相同 | `test_scheduler_parity` | `bench_scheduler` |
| `BroadPhase`(rebuild 5 種 + DBVH 持久化) | collision/broadphase.mojo、bp_dbvh.mojo | 同一謂詞的加速結構;結果集相等 | `test_broadphase`、`test_bvh`、`test_dbvh` | `bench_collision`、`bench_dbvh` |
| `NarrowPhase`(boolean,含 CGA 代數路徑) | collision/narrowphase.mojo | 同一謂詞的解析 vs 代數實作 | `test_narrowphase` 系列、`test_cga_narrowphase`、`test_cga_plane` | `bench_collision` |
| `ManifoldNarrowPhase`(AABB/SAT/OBB/GJK/hull) | collision/manifold.mojo、hull.mojo | 接觸謂詞的富化(點集+深度),normal/depth 與 boolean 路徑一致 | `test_manifold`、`test_hull` | `bench_manifold` |
| `SceneQuery`(brute/bvh/grid/tree) | collision/queries.mojo | 同一查詢謂詞的加速結構 | `test_queries` | `bench_queries` |
| 真實幾何查詢的候選預篩:線性掃描(`_candidates`)vs `QueryIndex`(碰撞器世界盒 BVH,一次建置多次查詢);網格射線候選:線段 AABB vs BVH 下降 / heightfield 格線 DDA;批次:serial vs 平行派發(17.53) | collision/world_query.mojo、collision/trimesh.mojo(`ray_candidates`)、spatial/bvh.mojo(`ray_leaves`)、physics/solver6.mojo(`ray_cast_batch`) | 同一「最近命中」函數的不同候選集合:候選集只要包含真正命中者,答案就相同;候選依碰撞器索引排序,等 `t` 的平手規則也相同,故逐位相同 | `test_query_ext`(400 條射線 × 300 碰撞器:indexed == linear 逐位;300 條射線:BVH / DDA 找到與逐三角形暴力相同的三角形;平行批次 == serial 逐位) | `bench_query_ext`(N = 16–4096 線性 vs index 含建置;批次 serial vs 平行;1 km 斜射線的候選數) |
| solver6 pair 收集 brute O(n²) vs `BroadPhase` 全 seam(17.0e:`ContactScene6[B,BP]`,collider 註冊表移至 `collision/collider_set.mojo`) | physics/solver6.mojo(`_collect_pairs`)、collision/contact_gen.mojo(`collect_bp_pairs`) | 同一接觸對集合的加速枚舉,現貫穿真正會跑的 `BroadPhase` trait(brute/BVH/DBVH/SAP/hashgrid/octree);fat-AABB 保守超集 + 逐對正規化排序 → 命中集相等、同序 → 逐位一致,與後端無關 | `test_solver_broadphase`、`test_solver_bp_seam`(6 後端 × 6 案例矩陣,含極端案例) | `bench_solver_scale`(N=64…4096 全後端矩陣 + SAP/hashgrid 20:1 尺寸展延列) |
| BVH 建樹啟發式 median vs binned SAH | spatial/bvh.mojo(`build(sah=)`) | 同一加速結構的建構品質變體;查詢結果集/最近命中相等,SAH 樹更緊 | `test_sah` | `bench_sah` |
| `Rng` | scheduler/rng.mojo | 種子單子(state monad)的可交換實作 | `test_rng` | `bench_rng` |
| `for_each2` vs `query2+get/set` | ecs/storage.mojo | 同一態射的無配置實作 | `test_iter_parity` | `bench_ecs`(存取路徑 rows) |
| `Body6`(quat+tensor vs motor/screw) | physics/rigid6.mojo | SE(3) 動力學的兩個表示函子,比 action 不比係數 | `test_rigid6`、`test_solver6` | `bench_rigid6` |
| `SpinIntegrator`(Euler/RK2/Midpoint/**Lgvci** 變分) | physics/integrator6.mojo | 同一連續流的離散化家族(含 Moser–Veselov 變分積分子) | `test_integrator6` | `bench_rigid6` |
| 布料 CPU vs GPU | physics/gpu_cloth.mojo | 同一態射的裝置實作(host/device) | `test_gpu_cloth` | `bench_gpu_cloth` |
| 布料 solver XPBD vs VBD | physics/gpu_cloth.mojo、vbd_cloth.mojo | 同一變分能量的不同下降子(Jacobi 投影 vs 著色 Newton 塊下降) | `test_vbd_cloth`(物性 + CPU/GPU parity) | `bench_vbd_cloth`(同品質水準比成本) |
| 剛體變換表示 motor/DQ/mat4/quat | geometry/motor.mojo、dualquat.mojo、mat.mojo、quat.mojo | SE(3) 表示函子(§3) | `test_motor_parity` | `bench_ga` |
| 蒙皮 DLB vs LBS | geometry/skinning.mojo | 表示函子在蒙皮插值上的作用 | `test_skinning` | `bench_ga`(skin rows) |
| `Field`(RealF/DualReal/DualBatch/RevReal tape / comptime 生成伴隨)+ `GMV` vs 特化 | geometry/field.mojo、gmv.mojo、physics/adjoint.mojo | 對偶數函子(切叢提升)+ 伴隨函子(反向掃,執行期 tape 與編譯期展開兩實作);係數環參數化 | `test_diffsim`、`test_gmv_ad`、`test_adjoint`、`test_laws` | `bench_diffsim` |
| CCD 階段 speculative vs swept/TOI;TOI 求解:盒專用 swept-SAT(閉式)vs 保守推進(GJK 距離,任意凸 / 網格,17.46) | physics/solver6.mojo、collision/toi.mojo、physics/ccd6.mojo | 同一「不穿隧」謂詞的一階(裕度)與二階(掃掠)保證;慢速路徑逐位一致;保守推進的 TOI 恆 ≤ 精確值 | `test_ccd6`、`test_ccd_shapes` | `bench_ccd`、`bench_ccd_shapes` |
| 接觸摩擦錐 金字塔(逐軸夾)vs 橢圓(切向向量夾於圓盤);靜 / 動摩擦;滾動 / 扭轉阻力(17.50) | physics/contact6.mojo(`solve_contact`、`_solve_rolling`)、physics/solver_config.mojo(`friction_cone`) | 同一 Coulomb 錐的兩種多面 / 圓近似:未達上限時兩者走相同步驟;μ = 0 時逐位相同;沿切向基底軸滑動時上限相同(差 < 1 mm),45° 時金字塔上限為 √2 μN;滾動 / 扭轉係數 0 時不進該分支(預設場景逐位不變) | `test_contact_model` | `bench_contact_model` |
| 接觸法向求解 逐點 GS vs 逐 manifold 塊求解(小型 LCP,主動集列舉)(17.50) | physics/contact6.mojo(`_block_normal`、`_block_try`)、physics/solver_config.mojo(`contact_solver`) | 同一 manifold 法向互補問題的兩種解法:單點 manifold 與黏附時塊求解即逐點路徑(逐位相同);靜置箱高度差 < 1e-5 m;四點共面的秩虧 A 以 1e-4 相對對角正則化取最小範數分配 | `test_contact_block` | `bench_contact_model` |
| 布料彎曲 跨邊距離 vs 帶號雙面角(17.56) | physics/cloth.mojo(`BEND_CROSS_EDGE` / `BEND_DIHEDRAL`、`_dihedral`) | 同一彎曲能的兩種約束:平面內等比拉伸時雙面角約束不動(1e-17 m)、跨邊距離約束拉回(0.078 m);預設跨邊,改模型前後輸出逐字相同 | `test_cloth_models` | `bench_cloth_mesh` |
| 慣性化殘差空間 位置 + 旋轉分開 vs 單一 motor(螺旋)(17.64) | procedural/inertialize.mojo(`INERT_SPLIT` / `INERT_MOTOR`) | 同一殘差的兩種衰減路徑:純平移或繞骨原點的旋轉兩者一致(1e-5),起點皆為顯示中的姿勢、終點逐位為目標;繞遠處樞軸的偏移 motor 走弧(與樞軸距離 1.0)、分開者走弦(0.707) | `test_inertialize_motor` | `bench_anim_runtime` |
| 碰撞管線執行 串行 vs 分塊 fan-out(narrowphase、make_contact;經 `Dispatch`,17.54) | physics/collide_par.mojo、physics/solver6.mojo(`_collect_pairs`) | 同一候選序列上的映射:分塊結果依塊序串接、prep 逐槽寫入,順序與串行相同,故對任何 workers 數與派發器逐位相同 | `test_collide_par` | `bench_collide_par` |
| ECS 查詢過濾 `select`(with / without / any)於六後端的原生實作;變更偵測 pull(`changed` / `added`,寫入日誌)(17.77) | ecs/storage.mojo(`Filter`、`check_pack`)、六個 backend 的 `select`、ecs/world.mojo | 同一實體集合謂詞在不同儲存上的求值:排序後的實體集合與逐個 `has` 的暴力過濾相等,六後端彼此相等;日誌路徑與全掃描回退結果相同 | `test_ecs_query`、`test_ecs_pack_guard` | `bench_ecs_query` |
| 窄相 重算 vs 複製(兩端未動的候選對沿用上次輸出,`reuse_still_pairs`,17.85) | physics/solver6.mojo(`_narrow_reuse`)、collision/collider_set.mojo(`epoch`) | 純函數的記憶化:輸入(碰撞器 epoch、兩端位姿與線速度、`spec_dt`、裕度)逐位相同則輸出相同,依候選順序串接,故逐位相同 | `test_np_reuse` | `bench_tiers`(`+ reuse_still_pairs` 列) |
| 連續體求解器 FEM / MPM / PBF / LBM 轉接器,同一 `ContinuumSolver` 契約(17.55) | physics/continuum.mojo | 同一「推進 dt + 健康檢查 + 隔離 + 狀態讀寫」介面的四個實作;泛型驅動對四者相同,狀態寫出 → 讀入 → 續跑逐位相同 | `test_continuum` | `bench_continuum` |
| FEM 本構 `Corotational` / `StableNeoHookean` / `StVK`(`Material` trait,17.58) | physics/fem_material.mojo | 同一「F ↦ P」介面的三個應力律;小應變(線性化)與剛體旋轉下三者一致,大壓縮 / 反轉處分歧(量給出);`Corotational` 經 seam 與 `FemBody.elastic_forces` 逐位相同 | `test_fem_material` | `bench_fem_material` |
| 肌肉:`Actuator.muscle` vs Hill 曲線(`HillParams`,17.57) | physics/actuator.mojo | 曲線皆關閉時 fl = fv = 1、fp = 0 精確成立,Hill 變體退化為原肌肉(恆等元);開啟時是同一啟動動力學上的乘性修飾 | `test_muscle_hill`(2 s 軌跡逐位相同) | `bench_hair_muscle` |
| LBM 固體邊界:靜止 half-way bounce-back vs Ladd 移動壁面(17.59) | fluid/lbm.mojo | 壁速為 0 時 Ladd 項為 0,退化為靜止 bounce-back(恆等元) | `test_lbm_moving`(壁速 0 時與靜止格子逐位相同) | `bench_fsi` |
| 水面 `FlatWater` / `GerstnerWater` / `ShallowWaterGrid` / `FftOcean` / `ShallowWaterFV`(`WaterSurface` trait,17.60) | physics/water.mojo | 同一「(x, z, t) ↦ 高度」查詢;Gerstner 振幅全為 0 時退化為平面(恆等元),陡度 0 的單波為解析正弦;FFT 海洋的單一頻譜分量 = 陡度 0 的 Gerstner 單波 | `test_water`(振幅 0 與平面逐位相同;單波誤差 0)、`test_fft_ocean`(單模態對 Gerstner 2.3e-6 m;無模態 = 水位) | `bench_water` |
| 格網流體 `MacFluid2` / `Lbm`(17.60) | physics/mac_fluid.mojo、fluid/lbm.mojo | 兩個求解器作用在同一不可壓縮流上;可觀察量 = Taylor–Green 渦振幅的衰減率,對解析 2νk² | `test_taylor_green`(MAC 1.0048、LBM 1.0041,彼此 0.07 %) | `bench_grid_fluid` |
| 連續體狀態來源:即時求解 vs `CachePlayer`(點快取播放,17.63) | physics/sim_cache.mojo | 同一 `ContinuumSolver` 契約的兩個實作;錄製幀上兩者差 ≤ 量化誤差上限(err = 0 時逐位相同) | `test_sim_cache` | `bench_sim_cache` |
| 熱傳導離散:有限差分格網 vs 線性四面體(17.61) | physics/thermal.mojo | 同一熱方程 dT/dt = α∇²T 的兩個離散;在 1D 半無限棒的 erfc 閉式解上 parity | `test_thermal`(兩者對 erf 0.014 / 0.025 K,互差 0.016 K) | `bench_thermal` |
| 耦合排程:顯式交錯 vs 子步插值 vs Aitken 迭代(17.61) | physics/coupler.mojo | `Coupler[A, B]` 對任意兩個 `CoupledPart` 的三種排程;ratio 1 時插值 = 顯式逐位元相同,弱耦合三者一致,dt 減半時三者互差減半 | `test_coupler`(子步比 2–16 插值的能量誤差皆低於顯式;介面衝量不平衡隨 dt 下降) | `bench_coupler` |
| 蒙皮方法 × 影響數:DLB / LBS × K(17.65) | geometry/skinning.mojo | 全骨同一剛體運動時 DLB = LBS = 該運動;K = 2 與 `skin_motor` 逐位相同;K = 1 = 該骨 motor;扭轉體積處分歧(量給出) | `test_skin_k` | `bench_skin_k` |
| 角色本體後端:kinematic `Mover` vs `DynamicCharacter`(17.66) | gameplay/movement.mojo、gameplay/phys_character.mojo | 平地同輸入下穩態速度與煞停距離一致;外力響應(衝量、對腳下物體的反作用)只有動態後端有 | `test_phys_character`(煞停 0.58333 vs 0.583333 m) | `bench_phys_character` |
| 浸沒體積:取樣積分 vs `polytope` 精確切割(17.74,延伸 17.28) | gameplay/watercraft.mojo、physics/fields.mojo | 同一「物體在水面下的體積與形心」;軸對齊盒上精確切割 = 閉式解,取樣誤差隨層數收斂 | `test_force_elements`(0.6 vs 0.6 m³) | `bench_force_elements` |
| 點分佈取樣器:Poisson-disk / dart throwing / 抖動格(17.69) | procedural/scatter.mojo | 宣稱最小間距者皆滿足之(Poisson / dart ≥ r、抖動 0.25 ≥ 0.5 格);同 seed 逐位相同 | `test_pcg` | `bench_pcg` |
| 屬性求值:全量重算 / 增量和 / 髒快取(17.70) | gameplay/rules.mojo | 同一「目前值」;定點整數使加總精確可交換,任意序列後三者相同 | `test_rules`(20000 步、4002 次讀取全同) | `bench_rules` |
| 目標條件派發:線性掃描 vs 事件型別倒排索引(17.72) | gameplay/objectives.mojo | 同一事件序列下完成集合與完成序相同 | `test_flow`(300 目標、5000 事件) | `bench_flow` |
| 動畫轉場 淡入(兩次取樣 + 混合)vs 慣性化(一次取樣 + 衰減殘差)(17.64) | procedural/anim_state.mojo、procedural/inertialize.mojo | 同一「來源姿態 → 目標 clip」轉場的兩個實作:轉場結束後兩者逐位等於目標 clip 的取樣;殘差為 0 時目標姿態不變 | `test_anim_runtime` | `bench_anim_runtime`(轉場佔比 0 / 50 / 100 %) |
| 角色速度整合 直設 / 加速度式 / Quake 式(17.67) | gameplay/movement.mojo | 同一「期望速度 → 水平速度」映射的三個實作:平地等速直行的穩態速度相同(皆 3 m/s);暫態不同(加速度式 3 s 少走 0.2 m) | `test_movement` | `bench_movement` |
| 時間軸求值 隨機 seek(二分)vs 順序游標(17.68) | procedural/sequence.mojo | 同一「t → 軌道值」純函式的兩種段落定位:段索引相同、算術相同,故逐位相同;事件同經 `EventTrack` | `test_camera_seq` | `bench_sequence` |
| 鏡頭姿勢彈簧 位置 + 旋轉向量分開 vs 相對 motor 的 6 維 log(17.68) | procedural/camera_math.mojo(`CamSpring`,`SPRING_SPLIT` / `SPRING_MOTOR`) | 同一臨界阻尼彈簧作用在兩種座標:純平移(差 1.4e-5 m,float32 motor 乘積捨入)或純旋轉(2.9e-7 rad)兩者一致,半步兩次 = 一步;繞樞軸 90° 時 motor 走弧(與 5 m 樞軸距離 4.9999995)、分開者走弦(最近 3.54 m) | `test_camera_spring` | `bench_sequence` |
| 近戰命中偵測 每 tick 離散 vs 端點線性掃掠 vs 弧線掃掠(17.71) | gameplay/combat.mojo | 同一「刀身這一 tick 碰到誰」的三種近似:每 tick 位移小於目標厚度時命中集合相同(慢揮三者皆 1 次);高速下差異寫成行為斷言(72 m/s:離散 0、線性 0、弧線 1) | `test_combat` | `bench_combat`(命中率與成本 vs 角速度) |
| 宿主交換 逐物件 getter / teleport vs 批量 SoA(`ld_world_get_bodies` / `ld_world_set_poses`);元件 編譯期 `ComponentType` vs 宿主定義 blob(17.78) | embed/capi.mojo、physics/solver6.mojo(`teleport_many`)、ecs/host_components.mojo | 同一姿態交換 / 同一元件讀寫腳本的兩條路徑:取回的姿態逐位相同、批量寫入後狀態與逐一 teleport 逐位相同;blob 與編譯期元件的實體集合與值相同 | `test_host_bulk`、`test_python_binding` | `python/bench_bulk.py`、`bench_host_components` |
| 變更偵測 push observers vs 輪詢 | ecs/reactive_backend.mojo | 同一成員變化事件流的推/拉實作;重播 ≡ 輪詢結果 | `test_observers` | `bench_ecs_events` |
| 組件寫入 直接 vs 延遲(SetBuffer) | ecs/commands.mojo | 同一寫入序列的即時與 sync-point 重播;錄製序保序 | `test_deferred_set` | `bench_ecs_events` |
| 線代 scalar vs SIMD | geometry/mat.mojo | 同一線性映射的 lane 寬度變體 | `test_mat` | `bench_linalg` |
| 曲線表示:generalized Catmull-Rom(comptime `alpha`:uniform/centripetal/chordal)vs 分段三次 Bezier(17.36) | geometry/spline.mojo(`CatmullRom.segment_bezier`) | 同一段曲線的兩個表示函子;`alpha=0` 化簡為教科書封閉式「均勻 CR = Bezier(P1, P1+(P2-P0)/6, P2-(P3-P1)/6, P2)」,任意 `alpha` 走同一 Barry-Goldman 構造的 Hermite→Bezier 轉換,不是特例分支 | `test_spline`、`test_spline_parity`、`test_spline_frames`(RMF motor 幀 + galie 測地線內插,同層跨模組整合) | `bench_spline` |
| 高頻生滅實體:直接 `spawn`+set+`despawn` vs entity pool `acquire`/`release`,跨六個 `StorageBackend`(17.37) | ecs/pool.mojo | 同一「取得一個帶模板值的活實體」態射的兩個實作;`acquire` 對已存在的模板欄位是 in-place overwrite(archetype 不遷移,只有 `Disabled[DID]` 標記自己遷移),`spawn`+逐一 `set` 是逐欄新增(每次遷移一個 archetype)——同一終態(值相等、查詢集相同),路徑成本不同 | `test_pool`(六 backend parity;耗盡 grow/refuse、雙重釋放、外來實體、跨 release/re-acquire 的過期 handle 四個極端案例) | `bench_pool`(churn N=1..1e5;N=1 對照組——含一次性 `prime`——之下 pool 全六 backend 皆較慢,1.19x-1.74x,N=1e5 轉為較快,1.08x-1.51x,矩陣見報告) |

**架構定律**:任何新 seam 實作必須附上它的自然性方格(parity 測試)。這是引擎
「swappability holds end-to-end」的形式化理由。
**架構定律 v2(2026-07-13)**:每個 seam 的**所有**變體必須同時出現在上表的
「定律測試」與「Benchmark」兩欄 —— parity 測試 + `BENCHMARK_REPORT.md` 對應
row,缺一不收(相對方法時刻有對應 benchmark)。新增 seam 或變體時,本表為
覆蓋矩陣,benchmark 欄不得留空。

**架構定律 v3(2026-08-11,使用者明令)**:v2 管「有沒有對應的量測」,v3 管
「實作本身是否完整」。每項交付另須滿足:

1. **接上專案** —— 新能力必須接進**真正會跑到的路徑**,不得留為孤島。
   立法當下的反例:`geometry/quickhull.mojo` 寫好數月卻從未接進 narrowphase
   (當時 grep 在 `collision/` 與 `physics/` 零命中),能力等於不存在。該孤島已於
   同日 `947a37f` 補上生產入口 `SATNarrowPhase.add_cloud` /
   `SATManifoldNarrowPhase.add_cloud`,反例僅存為立法緣由。若刻意不接(如
   `collision/bp_gpu.mojo` 不實作 `BroadPhase` trait —— trait 無處放 device
   context),**理由必須寫在檔頭**。
2. **普通案例** —— 名目輸入下行為正確。
3. **整合案例** —— 與其他子系統一起跑仍成立:換 backend 逐位相同、接進 solver
   後既有測試不變、CPU/GPU parity、序列化後續跑逐位相同。
4. **極端案例** —— 退化與邊界:零/單一元素、全部重合、共面共線、零長度法向、
   除零、超出容量、極大/極小步長、族群變動、瞬移(打破時間連續性假設)。
   **本專案至今最多真 bug 由這一類抓到** —— MPM 的 P2G stencil 偏移(自由落體
   動量暴衝 366000×)、PBF 的三個 bug、LBVH 的重複 Morton 碼、SAP 的瞬移、
   chunked backend 的鄰頁釋放、CGA rotor 的雙向量符號(只有跨實作比對才抓得到)。

**Phase 4 新增(2026-07-13,皆遵定律 v2)**:上表最後五列 —— CCD 兩階段
(speculative/swept)、變更偵測(push/poll)、組件寫入(直接/延遲)、布料 solver
(XPBD/VBD)—— 加上 `SpinIntegrator` 的 `LgvciSpin`(變分,入 `bench_rigid6`)與
`Field` 的 `RevReal` tape(入 `bench_diffsim`)。六個新變體各附 parity test +
report row。

### 2.1 Phase 6–13 補齊的 seam(2026-09-03)

§2 的表定型於 Phase 4。Phase 6–13 長出的物理、流體、可變形體、GPU 與排程 seam
同受定律 v2 約束(parity 測試 + `BENCHMARK_REPORT.md` row,缺一不收),整理如下。
每列的「範疇論解讀」仍是「同一態射／謂詞,不同求值」——swap 的自然性方格由
「定律測試」欄機械化。補這張表時關掉了一個既存的 v2 缺口:`bench_lbm` 先前沒有
LES 對照列,`test_lbm_les` 的 seam 從此有量測(見末列)。

**加速結構、Morton 排序、平行求值**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| SAP 掃掠剪除(時間連續性)vs DBVH/hashgrid/rebuild | collision/bp_sap.mojo | 同一重疊謂詞的加速結構;命中集與 brute 相等,成本由逆序數而非 fat margin 決定 | `test_sap` | `bench_sap` |
| GPU 全對 broadphase vs CPU 加速結構 | collision/bp_gpu.mojo | 同一謂詞的 host/device 實作;命中集相等、次序不定(原子游標)→ 刻意不實作 `BroadPhase` trait,理由在檔頭 | `test_gpu_broadphase` | `bench_gpu_broadphase` |
| GPU 批次 raycast vs CPU BVH 走訪 | collision/gpu_raycast.mojo | 同一射線查詢的裝置實作;逐 proxy-id 相等 | `test_gpu_raycast` | `bench_gpu_raycast` |
| LBVH 建樹(第三種啟發式)+ CPU LSD-radix vs GPU bitonic Morton 排序 | spatial/bvh.mojo(`morton_order`)、spatial/gpu_lbvh.mojo | median/SAH 之外的第三個建構函子;查詢結果集相等,建樹支配 median | `test_lbvh`、`test_gpu_lbvh` | `bench_gpu_lbvh` |
| 島求解 serial vs threaded | physics/solver6.mojo(`_solve_islands_parallel`) | 態射合成的求值策略;任一 worker 寬度下世界逐位相同(須先對齊睡眠行為) | `test_islands_par` | `bench_islands` |
| 島內圖著色 vs 純 Gauss–Seidel | physics/contact6.mojo(`sweep_colored`) | 同一不動點迭代的掃描序變體;決定性、與執行緒數無關 | `test_colored` | `bench_colored` |
| work-stealing `ws_parallel_for` vs 靜態 `parallelize` | scheduler/workstealing.mojo | 同一平行 for 的排程策略;每個索引恰執行一次,結果不變 | `test_workstealing` | `bench_workstealing` |
| job graph 由讀寫集推導 vs 註冊序 | scheduler/jobgraph.mojo | 態射合成序的自動化;拓撲序下世界逐位相同 | `test_jobgraph` | `bench_jobgraph` |

**縮座標多體動力學**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 關節鏈:縮座標 CRBA+RNEA vs O(n) ABA vs 極大座標 solver6 | physics/chain.mojo(`step`／`step_aba`) | SE(3)ⁿ 動力學的三個實作;同初態下關節角一致 | `test_chain`、`test_aba` | `bench_chain` |
| 反向動力學(RNEA 掃)vs 正向動力學(CRBA 稠密解)往返 | physics/chain.mojo(`inverse_dynamics`／`mass_matrix`) | 同一運動方程的兩向;τ→q̈→τ 還原 | `test_inverse_dynamics` | `bench_chain`(idt 表) |
| 縮座標接觸(point-Jacobian `J H⁻¹ Jᵀ`)vs 極大座標接觸 | physics/chain.mojo(`point_jacobian`／`resolve_contacts`) | 同一接觸不動點在兩種座標下;落地高度一致 | `test_chain_contact` | `bench_chain_contact` |
| 縮座標鏈對靜態世界(`Chain.resolve_contacts`)vs 對 `ContactScene6` 物體的雙向接觸(`chain_scene.couple_contacts`,17.51) | physics/chain_scene.mojo | 同一接觸列;對靜態物體兩者為同一不動點,對動態物體多出物體側的有效質量與反向衝量(動量守恆) | `test_chain_scene`(靜態箱上兩者落點差 0;擺錘撞箱:給出的衝量 = 箱子動量;5 kg 腿站在 1 kg 箱上壓 49.000023 N) | — |
| 浮動基座 vs 六個偽關節;複合慣量 vs 單位加速度 兩種 H 組裝 | physics/floating.mojo(`mass_matrix`／`_mass_matrix_units`) | 6-DOF 根的兩個表示 + 質量矩陣兩獨立推導互為 parity | `test_floating` | `bench_floating` |
| 關節運動子空間 revolute vs prismatic + 關節極限 | physics/chain.mojo(`revolute`／`prismatic`／`resolve_limits`) | 同一 link 態射的運動子空間變體;極限為投影 | `test_joints_lib`、`test_joints6` | `bench_chain`(jt 表) |
| 縮座標關節的彈簧 / 阻尼:顯式 `Actuator` PD 力矩 + `Chain.step` vs 隱式欄位 + `Chain.step_implicit`(17.51) | physics/chain.mojo、physics/actuator.mojo | 同一「線性彈簧 - 阻尼」的兩種時間離散:顯式在 ω dt > 2 時發散,後向 Euler 對任意剛度皆穩定(只在對角加正項);性質全為 0 時兩者為同一半隱式步(容差 1e-4) | `test_chain_props`(剛度 1e5 @ 1/60:顯式 inf、隱式衰減;阻尼每步因子 I / (I + b dt);armature 週期;彈簧平衡角;摩擦停止時間) | `bench_chain_props`(N = 8 / 32 / 64) |
| 關節限制 / 馬達 / 彈簧的座標變體:極大座標 `Joint6` + `JointExt`(hinge / slider / cone-twist / rope 的單邊不等式、速度 / 位置馬達、軟彈簧)vs 縮座標 `Chain.resolve_limits` + 致動器(17.47) | physics/joint_ext.mojo、physics/joints6.mojo、physics/solver6.mojo(`ext_sweep` 在兩個子步迴圈) | 同一「關節座標 q 上的限制 + 驅動」在兩種座標下的實作;ext 全為預設值時 pass 不執行(`any_ext`),與 17.47 之前逐位相同 | `test_joints_ext`(停止角 / 馬達穩態 / 彈簧週期對解析值;快照往返逐位)、`test_ragdoll`(限制膝)、`test_joint_parity`(同一根桿:自由擺角度差 ≤ 0.0099 rad、週期相同;力矩平衡角 0.42432 / 0.42044 vs 解析 0.42044;限制停止角 0.49998 / 0.5)、`test_joint_d6`(D6 的特例 == weld / hinge / slider) | `bench_joints_ext`(64 節鏈,四種關節 × iters 4 / 8) |

**統一約束、致動、腱、感測**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 統一約束求解器 vs 交替通道;金字塔 vs 橢圓摩擦錐 | physics/constraints.mojo(`CONE_PYRAMIDAL`／`CONE_ELLIPTIC`) | equality/limit/friction/contact 一體 vs 分通道;等工作量下打平,錐耦合列是能力差而非速度差 | `test_constraints` | `bench_constraints` |
| 摩擦錐求解器 PGS vs active-set Newton(13.5);同一 KKT 解的兩個下降法 | physics/constraints.mojo(`solve` vs `solve_cone_newton`;錐型為執行期旗標,非 trait seam) | 同一 LCP / 錐互補問題的兩個解法:PGS 是迭代投影,Newton 是對作用集與滑動方向的精確子問題;兩者在可解的情形收斂到同一 KKT 點 | `test_constraints_newton`(橢圓錐 sweep 與 PGS 一致 1e-7、耦合 KKT 條件、錐形斜坡方向) | `bench_constraints`(匹配精度對照) |
| 致動器(仿射傳動 + 內部動力學低通)vs 直接 PD 伺服 | physics/actuator.mojo | 力生成態射的抽象層;高增益極限下兩者收斂 | `test_actuator` | `bench_actuator` |
| 腱力臂:解析 Jacobian vs 中央差分;`FixedTendon` vs `SpatialTendon`、繞行 on/off | physics/tendon.mojo | 同一長度映射的解析與數值梯度;1–2 DOF 差分勝、交叉點 2–8 DOF | `test_tendon` | `bench_tendon` |
| 感測:逐呼叫 `read_imu`(O(S·L))vs 共享掃描 `read_imu_batch`(O(L+S))vs 差分 | physics/sensors.mojo | 同一觀測函子的攤銷實作;N=1 控制組須略慢方為可信 | `test_sensors` | `bench_sensors` |

**可變形體**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| FEM:線性 vs co-rotational 彈性;顯式 `step` vs 隱式 `step_implicit` | physics/fem.mojo | 同一彈性能量的線性化變體 + 時間積分子(隱式走 CG) | `test_fem`、`test_numerics` | `bench_fem`、`bench_numerics` |
| MPM:彈性 vs 塑性(行列式夾限回映)於同場景 | physics/mpm.mojo(`set_plastic`) | 同一 P2G/G2P 態射 + 本構回映;塑性僅 +0.5% 成本 | `test_mpm` | `bench_mpm` |
| SPH(密度誤差→壓力**力**,CFL 限步)vs PBF(密度誤差→**約束**投影) | physics/sph.mojo、pbf.mojo | 同一不可壓縮謂詞的力法與投影法;PBF 步長 4× 但每模擬秒成本相當 | `test_sph`、`test_pbf` | `bench_sph`、`bench_pbf` |
| 布料自碰撞 on/off,橫跨 XPBD 與 VBD 兩 solver | physics/self_collide.mojo | 同一自碰撞約束在兩下降子上的加入;結果集一致 | `test_self_collide` | `bench_self_collide` |

**幾何謂詞與代數**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 精確幾何謂詞 vs 裸浮點符號(orient2d/3d、incircle、insphere) | geometry/predicates.mojo(`*` vs `*_naive`) | 同一符號謂詞的精確與近似實作;退化輸入下符號一致 | `test_predicates` | `bench_predicates` |
| 靜態關卡中相:brute vs BVH;`TriMesh` vs `HeightField` | collision/trimesh.mojo | 同一靜態幾何查詢的加速結構 + 兩種關卡表示;靜置高度一致 | `test_trimesh` | `bench_trimesh` |
| 網格接觸 active-edge 修正 on / off(17.45) | collision/contact_gen.mojo(`_fix_inactive_edge_normal`、`_round_on_flat_seam`) | 同一網格接觸的兩種法向選擇;無內部邊(全 active)時逐位相同 | `test_active_edges` | `bench_mesh_bake` |
| 球 / 膠囊對網格:解析三角形 manifold vs 盒近似(17.45) | collision/contact_gen.mojo(`sphere_triangle_manifold`、`capsule_triangle_manifold`) | 三角面中心靜置高度相等(皆為 r);滾動 / 邊緣行為為能力差,以解析加速度記錄 | `test_mesh_round` | `bench_trimesh` |
| 距離表示:`SdfGrid` 取樣 vs 精確三角形距離(17.45) | geometry/sdf_grid.mojo | 同一 signed distance 的格點近似;差 ≤ 一個格對角線 | `test_sdf_grid` | `bench_mesh_bake` |
| 3D SDF 迭代接觸 vs 解析 sphere/box 對(+ CSG 無解析對照) | geometry/sdf3.mojo(`sdf_contact`、`OP_SUBTRACT`) | 同一接觸謂詞的隱式場實作;解析對照存在處 parity | `test_sdf3` | `bench_sdf3` |
| DCGA `Cl(4,1)⊗Cl(4,1)` 統一四次 incidence vs 手寫 plane/sphere/torus | geometry/dcga.mojo | 「簽名 ↦ 代數」函子在張量積代數上的值;成本恆定不分曲面(統一性),1.6–1.9× | `test_dcga` | `bench_dcga` |

**其他**

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 可微接觸模型:剛性衝量 vs 軟性罰函數 | physics/diffrigid.mojo(`rollout_rigid`／`rollout_soft`) | 同一接觸態射的兩個可微化;梯度對兩模型各自定義 | `test_diffrigid` | `bench_diffrigid` |
| 動畫混合:線性(norm-lerp)vs DLB vs 測地(等速螺旋) | procedural/anim.mojo(`BLEND_LINEAR`／`BLEND_DLB`／`BLEND_GEODESIC`) | §3 表示函子在姿態混合上的作用;測地留在運動流形上 | `test_anim` | `bench_anim` |
| 線性解:全域 CG/PCG vs 局部 Jacobi 掃;Jacobi 前條件子 on/off | numerics/cg.mojo、sparse.mojo | 同一線性系統的迭代子家族;matrix-free 與顯式 CSR 兩路徑 | `test_numerics` | `bench_numerics` |
| FEM 隱式步的線性解:matrix-free CG / 組裝後稀疏 Cholesky(RCM)/ IC(0)-PCG(17.84,`FemBody.solver`) | physics/fem.mojo、numerics/cholesky.mojo | 同一 `A = M − dt² ∂f/∂x` 系統的三種解法;組裝矩陣作用於向量 = matrix-free 運算子(2.7e-5 / 57.9);2 s 懸臂尖端軌跡三者差 ≤ 2.1e-7 m;非對稱系統另有 GMRES(m)(`numerics/gmres.mojo`,`test_solvers`) | `test_fem_solvers`、`test_solvers` | `bench_fem` |
| LBM Smagorinsky LES vs 純 BGK(常數為 0 ⇒ 逐位相同) | fluid/lbm.mojo(`eddy_viscosity`) | 同一碰撞算子的湍流閉合變體;優勢區是粗網格高 Re(BGK 發散、LES 收斂) | `test_lbm_les` | `bench_lbm`(LES 表) |

### 2.2 `diag`(可觀測性層,Phase 17.9/17.10/17.32–17.34,2026-09-27)

`diag` 是 layer 0(見 `docs/ARCHITECTURE.md` §1),零引擎依賴,錯誤處理政策
(§2)的 detect/record/terminate 三層都落在這裡。它自己也長出兩個效能 seam:

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 每幀暫存記錄:`FrameArena` bump 配置(一次配置、`reset()` 重用)vs 每幀新建 `List` | diag/arena.mojo | 同一「每幀 N 筆暫存記錄」需求的兩個配置策略;逐值內容相等(`test_diag_arena` 的 parity 檢查),配置開銷不同 | `test_diag_arena` | `bench_diag`(arena vs list 表) |
| 分級日誌 / 追蹤 span 的 compile-time on/off(`LUDENS_LOG_LEVEL`／`LUDENS_TRACE`) | diag/log.mojo、diag/trace.mojo | 同一呼叫點在兩個編譯期特化下的行為;停用側必須是「本來就沒呼叫」的自然態射(單位態射),而非「呼叫了但跳過」 | `test_diag_log`、`test_diag_trace` | `bench_diag`(log 表量到 disabled==no-call within noise;trace 表量到 on/off 皆為 few% of a phase-sized span) |

第一列沒有共用 trait 統一 `FrameArena`/`List`(曾考慮做一個
`FrameAllocator`-風格 trait,後放棄):兩者的呼叫形狀本質不同
——`List` 不需要預知總數就能逐步成長,`FrameArena.alloc[T]` 需要一次要求
`n`——沒有生產呼叫點需要在兩者間透過共用介面切換(切換只發生在 benchmark 這一
層),強行做出的 trait 不會反映任何真實呼叫點的用法。定律 v2 要求的是「parity
測試 + benchmark row」,不是「必須有 trait」——這裡以逐值內容相等的 parity 檢
查(`test_diag_arena`)取代,量測仍在 `bench_diag`。

第二列的「定律」跟其他 seam 不同:不是「兩個變體算出同一個答案」,而是「停用
的那一側必須什麼都沒發生」——`log[level]`﹑`TraceBuffer.begin`/`end` 用
`comptime if` 把停用分支消去到空函式體,`test_diag_log`/`test_diag_trace` 直接
斷言停用時 ring/buffer 保持空;`bench_diag` 則把這個「什麼都沒發生」換算成數
字(log 停用 vs 完全不呼叫,誤差在雜訊內;trace 停用/啟用相對一個真實 phase
大小的 span,開銷同樣落在雜訊內)。

### 2.3 `scheduler.timers` + `procedural.tween`(Phase 17.35,2026-09-28)

計時器落在 layer 3(`scheduler`),補間落在 layer 2(`procedural`,只能引入
`geometry`/`diag`)——兩者是 17.35 同一份設計筆記(`docs/design/wave-a-services.md`)
的兩半,各自長出一個 seam:

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `TimerQueue`:陣列二元 min-heap vs 二階環狀 timing wheel | scheduler/timers.mojo | 同一「到期」謂詞的兩個資料結構;`advance()` 回傳的 fired 序列以 `(due_tick, schedule 序號)` 全序比對逐位相同,與實作無關(`_HeapEntry`/`_WheelEntry` 對呼叫者不可見) | `test_timers`(seeded 隨機 schedule/cancel/advance 腳本,12 個種子逐位比對) | `bench_timers`(schedule 吞吐 + 近到期 drain 成本,N=1e2..1e6;heap 對 window 不敏感,wheel 隨散布視窗變寬而變貴,見表 3) |
| 緩動分派:`ease[kind]`(comptime 参數)vs `ease_dyn(kind)`(執行期,`comptime for` 展開的 if 鏈) | procedural/tween.mojo | 同一組 31 條 Penner 曲線的兩個求值路徑;數值逐點相等(`test_tween` 的 `ease_dyn==ease` 檢查),只有分派成本不同 | `test_tween` | `bench_tween`(同一 kind 比兩種分派,見下方數字) |
| 補間插值子:`lerp_real`/`lerp_vec3`(線性)vs `geodesic3`(PGA motor 測地線,`geometry.galie`) | procedural/tween.mojo | §3 表示函子在「補間」這個態射上的作用,呼應 `procedural/anim.mojo` 的 `BLEND_GEODESIC` 列;端點以**作用**比對(`M` 與 `−M` 是同一剛體運動,不比係數),`Tween[Motor3,...]` 的端點與 `geodesic3` 的端點在任意取樣點上的作用一致 | `test_tween`(motor 端點 BY ACTION + `Tween.value_at(0.5)` == 原生 `geodesic3(a,b,0.5)`) | `bench_tween` |

**`schedule()` 單看插入成本,heap 與 wheel 在 N≈1000–10000 之間交叉**(heap
在 N=1000 約 44 ns/op,wheel 約 57 ns/op;到 N=10000 heap 約 71 ns/op,wheel
降到約 55 ns/op)——小 N 時 wheel 的固定環狀陣列配置蓋過它 O(1) 插入的優勢。
**近到期 drain 成本(window=256 tick)則 wheel 在整個 1e2..1e6 測試範圍全勝**,
差距隨 N 擴大——N=1e6 時 heap 約 324 ns/op 對 wheel 約 43 ns/op(≈7.5×,本表
最大差距落在 N=1e5,≈8.2×),正是設計筆記點名的「wheel 優勢區是大 N、且多數計
時器接近到期」。固定 N=200000 改掃散布視窗(表 3)則誠實地展示 wheel 的代價:
視窗從 256 拉到 300000 tick(超出兩階環的 65536 tick 全域,見
`scheduler/timers.mojo` 模組註解的別名重掃代價),wheel 每 op 成本從約 22 ns
(≈9× 領先)漲到約 58 ns(≈3.6×)再到約 135 ns(≈1.6×),heap 全程持平在約
200–211 ns 左右(它本就不在乎到期時間分布)——wheel 仍領先但優勢明顯收斂,與
模組文件承認的取捨一致。

**分派成本(`bench_tween` 表 1,同一 kind 比兩種路徑,N=2e6 次呼叫)**:
comptime 分派(`ease[kind]`)完全內聯、無分支,`EASE_QUAD_IN` 約 1.2 ns/op;
執行期分派(`ease_dyn`)兩個 kind 都多付出約 10–11 ns/op 的分派開銷
(`EASE_QUAD_IN` id=1 約 +11 ns,`EASE_BOUNCE_INOUT` id=30 約 +10 ns)——與
「if 鏈長度應該正比分派成本」的預期相反(鏈尾要多比 29 次卻沒有多付這些成本),
讀作編譯器把 0..30 的稠密等式鏈降成跳轉表而非線性掃描;無論如何,comptime 分
派仍是唯一「真正不用付錢」的路徑。

### 2.4 `scheduler.events`(Phase 17.38,2026-09-28)

事件匯流排落在 layer 3(`scheduler`);seam 是 pull(共用雙緩衝 + 每個 reader
一個 cursor,production 實作)對 push(`send()` 當下就 fan-out 複製進每個訂閱
者自己的 inbox,呼應既有 `scheduler/message.mojo` 的 mailbox 風格,僅作為
seam 的對照組)。`collision.contact_events.ContactEvent` 轉接器**刻意不放進
`scheduler/events.mojo`**——`collision` 與 `scheduler` 同為 layer 3,同層引入
違反 §1 的 reach-through 規則——轉接器改放進
`tests/test_events_contacts.mojo`,在 `gameplay`(layer 5)套件出現前,這個測
試本身就是定律 v3 要求的「接上專案」生產式呼叫端。

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `EventChannel`:pull 雙緩衝+cursor(`Channel[E]`)vs push fan-out(`PushChannel[E]`) | scheduler/events.mojo | 同一「遞送」態射的兩個求值策略;送出序號(`send()` 呼叫序)全序決定遞送序,與實作無關——重播同一腳本兩次逐位相同(`test_events.mojo` 的 determinism 檢查),換 seam 三個 reader(先註冊/frame 中途註冊/`update()` 後註冊)的觀察序列逐位相同(parity 檢查) | `test_events`(component:普通/parity/多數極端案例)、`test_events_gameloop`(integration:`scheduler.gameloop.FixedLoop` 真實 tick 驅動,驗證「writer 之前/之後讀」逐位不漏)、`test_events_contacts`(integration:真實 `physics.solver6.ContactScene6` 疊出的 `ContactEvent` 經轉接器送達 reader,began/ended 都收到) | `bench_events`(readers×events/frame 雙表;readers 才是 seam 分歧的軸,見下方數字) |

**未讀丟棄計數走 `diag.counters`**:pull 側的雙緩衝每次 `update()` 回收前一
週期時,任何 cursor 仍落後的 reader 都被計入本地 `dropped_unread`(仿
`diag/log.mojo`﹑`diag/draw.mojo`﹑`diag/trace.mojo` 既有的「容器自帶
`dropped: Int`」慣例),`Channel.sync_counters` 再把這個本地計數併入共用的
`diag.counters.Counters`(新 id `EVENT_DROPPED_UNREAD`)並歸零,避免重複計
數——`test_events.mojo` 的「一個從不讀取的 reader」極端案例直接斷言這條路徑
真的計數,不只是文件宣稱。push 側刻意沒有這個計數器:沒 reader 讀走的
inbox 只會變長,不會丟棄——這正是為什麼 pull 才是 production 選擇,而不是
對稱地補一個 push 並不真的需要的計數器。

**`bench_events` 表 1(1000 events/frame,readers 掃 1..32)找到真正的交叉
點**:readers=1 時 push 略勝(約 3.3 對 pull 約 5.3 ns/op——pull 每週期的固定
開銷,例如 `update()` 逐一檢查每個 cursor,在最小 reader 數時攤不掉);
readers=2 兩者打平(約 4.6 ns/op);readers≥4 起 pull 反超且差距隨 reader 數擴
大——8 個 reader 約 3.75 對 5.15 ns/op(push 慢約 1.4×),16 個約 3.57 對
11.66 ns/op(≈3.3×),32 個約 3.47 對 12.31 ns/op(≈3.5×)。pull 的 ns/op 隨
reader 數增加反而略降(固定開銷被更多次讀取攤薄),push 的 ns/op 卻比「純粹
O(readers) 次複製、單位成本應該打平」的預期漲得更多——讀作 fan-out 進多個
「各自獨立」的 `List` 一旦數量夠多,快取局部性的代價會疊加在複製本身之上,
這是設計筆記「push 成本 ∝ readers 次複製」這句話沒有拆開講的部分。表 2 固定
4 個 reader(交叉帶內)改掃 events/frame(1e2..1e6),兩者全程接近,沒有一方
持續大幅領先——與表 1 的結論一致:這個 seam 的分歧軸是 reader 數,不是事件
數。

### 2.5 `physics.body_set` 動作型別與 `physics.material` 組合模式(Phase 17.0g-2,2026-09-28)

17.0g-1 把 `statics: List[Bool]` 換成 Int 動作常數(`MOTION_STATIC`/
`MOTION_DYNAMIC`)時就在文件裡點名「KINEMATIC 之後補上,只能附加不能插入」;
17.0g-2 補了 `MOTION_KINEMATIC`(17.24)與逐 body 摩擦/恢復係數 + 逐對組合模
式(17.23)。兩者都是「同一態射的三/四個實例」形狀的 seam(17.25 的睡眠公開
API 刻意**不算**新 seam——既有的 `wake_islands`/`update_sleep`(今在 physics/islands.mojo)內部機制只是
介面化,見 ROADMAP 17.25 條目)。

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| body 動作型別:`MOTION_STATIC`/`MOTION_DYNAMIC`/`MOTION_KINEMATIC` | physics/body_set.mojo、physics/contact6.mojo(`solve_contact`/`solve_point`、`warm_start_contacts` 等接觸求解站台)、physics/joints6.mojo(`joint_sweep`/`warm_start_joints` 等關節求解站台) | 同一「位姿推進」態射的三個實例;`BodySet.moves`(讀速度:dynamic∪kinematic)與`is_dynamic`(質量項/衝量:僅 dynamic)兩個謂詞的交集決定每個站台的行為——kinematic 靜止時兩個謂詞在其 slot 上的取值與 static 完全相同,退化為同一分支,逐位相等 | `test_kinematic.mojo`(KEY PARITY TEST:零速度 kinematic 與 static 在同場景跑 200 步,每個動態 body 逐位相同;整合案例含 island/sleep/broadphase seam 與序列化續跑;極端案例含 kinematic 撞靜態牆零接觸、`move_to` 巨位移仍有限、kinematic 夾擠動態體仍有限) | `bench_kinematic`(N=16..1024 個動態箱疊在 kinematic 對 static 平台上,量測 kinematic 路徑多付出的 `velocity_at` 讀取成本) |
| 材質組合模式:`COMBINE_AVERAGE`/`COMBINE_MIN`/`COMBINE_MULTIPLY`/`COMBINE_MAX`(`physics.material.combine`,PhysX「較高優先模式勝」規則) | physics/material.mojo、physics/body_set.mojo(逐 body `friction`/`friction_combine`/`restitution_combine`)、physics/contact6.mojo(`solve_contact`、`restitution_pass`) | 同一「逐對係數」態射的四個求值分支,選哪一支由兩個 body 各自的模式取 `max` 決定(而非某個全域開關);兩個係數相等時四個分支在該點退化為同一個數值(`combine(1,1,·,·) == 1` 對全部四模式成立,是四個分支的共同不動點) | `test_materials.mojo`(普通:`combine` 四種公式的直接算術含優先權規則;整合/極端:兩 body 係數與模式皆為 1.0 時四模式跑出逐位相同的軌跡——parity;冰面對橡膠依組合模式排序的滑行距離,配合 `MULTIPLY<=MIN<=AVERAGE<=MAX`(係數皆在 [0,1] 時恆成立)的解析證明;預設 `restitution_combine=MAX` 重現既有 `max(a,b)` 彈跳行為) | `bench_materials`(N=1024 個同時接觸,四種組合模式各跑一輪 solver step——分派開銷應與選哪個模式無關,只是分支目標不同) |

摩擦係數的「未設定」哨兵值(`BodySet.friction[i] < 0`)是恆等閘門的關鍵:
`eff_friction` 在未呼叫 `set_friction` 時用該步的 `cfg.default_friction` 頂
替,兩個 body 都走這條路徑時 `combine(mu, mu, AVERAGE, AVERAGE) == mu`(IEEE
754 下 `(x+x)*0.5` 對任意有限浮點數精確成立,不是近似),所以 17.0g-2 之前寫
好的每一個場景在沒有呼叫任何新 API 的前提下逐位重現舊行為——這正是
`.campaign/golden_test_stdout_1.1.0.txt` 這條恆等閘門守住的東西,`test_serialize`
的 blob 位元組數變大(新增五個逐 body 欄位:`motion`/`friction`/
`friction_combine`/`restitution_combine`/`can_sleep`)是本次變更唯一允許改動
的 golden 行。

`bench_kinematic` 量化的成本**只**來自 `moves(i)` 在 kinematic 側多讀一次
`velocity_at`——`combine()` 的分派本身對 static/kinematic/dynamic 一視同仁
(每一對接觸都會呼叫,不分 body 動作型別),`bench_materials` 的四列因此預期
彼此接近,證明「選哪個組合模式」不是新的可觀測成本軸,只有「有沒有 kinematic
body 需要讀它的速度」才是。**兩個 bench 都得先把箱子釘醒**
(`set_can_sleep(id, False)`)才量得出這個小差異——箱子一旦睡著,整對接觸直接被
`BodySet.impulse_inert` 跳過,睡/醒狀態的落差(整對跳過 vs 全套求解)比 kinematic 多
讀一次速度大得多,會把要量的東西完全蓋掉,`bench_kinematic.mojo` 的檔頭把這
個混淆變數寫在建場景的地方。控制掉睡眠之後,`bench_kinematic` 四個 N 的
kinematic/static 比值落在 **0.97×–1.00×**(N=16 約 0.97×、N=64 約 0.99×、
N=256 約 1.00×、N=1024 約 1.00×,`flock` 鎖下的正式記錄跑)——一次額外的
`velocity_at` 讀取在雜訊範圍內,不是可觀測的成本軸;`bench_materials` 的四個
組合模式在 N=1024 落在 14.1–15.6 M ns/step(約 1.1× 展延,同量級雜訊),印證
「選哪個模式不改變求解成本」。`bench_sleep_wake` 印證 `wake(id)` 的 O(bodies)
宣稱:N 每擴大約 4 倍(16→64→256→1024),單次 `wake` 成本分別約
37/128/440/2308 ns,倍率 3.5×/3.4×/5.2×——與體數大致線性成長一致,不是
O(island size) 或常數(最後一段倍率略高於線性,讀作單次呼叫量測在 ns 級別本
身的雜訊,`bench_sleep_wake.mojo` 每點已是 3000 次重複的總時間平均)。

### 2.6 可微 / 批次接觸求解器(Phase 17.20 / 17.18,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 接觸求解的係數環:`RealF` / `DualReal` / `DualBatch` / `RevReal` / `BatchReal[W]`(`SolverField`) | geometry/field.mojo、physics/diffsolver.mojo | 同一個「一幀」態射在五個係數環上的像;分支全部改寫為指示函數 `positive`(導數定義為 0 = 接觸開關的次梯度約定),所以批次的各 lane 走不同分支仍是同一條指令流 | `test_diffsolver`(`RealF` 對 `ContactScene6`:落下 / 三球疊 / 滑轉滾;DualReal / DualBatch / RevReal / 中央差分四方梯度一致;批次 lane 對純量世界 ≤1e-4;NaN 世界不外溢;無接觸 = 精確彈道、μ=0 不自轉、重合球心有限、靜止高度對落下高度導數為 0) | `bench_diffsolver`(世界佈局:純量循序 / SIMD 8 lane / lane × 核,N=1..4096;梯度:FD / DualReal / DualBatch / RevReal,NP=1..16) |
| 解算器實作:`ContactScene6`(具體 `Vec3`/`Real`,全功能)vs `SphereWorld[F]`(可微子集:動態球 + 靜態平面) | physics/solver6.mojo + contact6.mojo、physics/diffsolver.mojo | 同一接觸演算法的兩個實作;子集邊界寫在 diffsolver 檔頭 | 同上(parity 容差 1e-4..5e-3,非逐位:運算分組不同) | 同上 |

### 2.7 反射 / 型別註冊表(Phase 17.11,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 序列化:反射驅動(`ecs.schema`,單筆自描述 / 批次)vs 手寫 | ecs/schema.mojo | 同一「值 → 位元組 → 值」往返態射的兩個實作;反射版的 schema 由編譯器的欄位表生成,手寫版的欄位清單由人維護。往返皆為恆等(逐位) | `test_schema`(round-trip 逐位、反射 == 手寫、ECS backend 互換後逐位相同、V1→V2 按名稱遷移) | `bench_schema`(N=16..65536:單筆 / 批次 / 手寫的 ns 與 B per value) |

### 2.8 接觸求解的裝置實作(Phase 17.17,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 批次 articulation:`Chain.dynamics_aba` / `Chain.dynamics`(CRBA)vs `ArticBatch`(kernel 本體在主機)vs `GpuArticBatch`(同一本體在裝置) | physics/chain.mojo、physics/artic_batch.mojo、physics/gpu_artic.mojo | 同一前向動力學的三個實作;主機版與 `dynamics_aba` 逐位相同(同一組 helper、同一順序),與 CRBA 在浮點誤差內;裝置版呼叫同一函式 | `test_artic_batch`(轉動逐位、混合關節對 CRBA、珠子解析解、實例獨立、能量)、`test_gpu_artic`(裝置 vs 主機,需 GPU) | `bench_gpu_batch`(每實例步:`step_aba` / `step_host` / 裝置融合步) |
| 批次 narrowphase:`ColliderSet.pair_manifold` vs `NarrowBatch`(kernel 本體在主機)vs `GpuNarrow` | collision/collider_set.mojo、collision/narrow_batch.mojo、collision/gpu_narrow.mojo | 同一分派、同一算術;主機版逐位相同;裝置版呼叫同一函式,差異只來自乘加收縮 | `test_narrow_batch`(2000 對逐位)、`test_gpu_narrow`(裝置 vs 主機,需 GPU) | `bench_gpu_batch`(每對:`pair_manifold` / `run_host` / 裝置) |
| 著色接觸求解:CPU(`ContactScene6.step(cfg.colored)`,串行 / 色內多核)vs GPU(`GpuContactSolver`) | physics/solver6.mojo、physics/contact6.mojo、physics/gpu_contact.mojo | 同一排程(色內 Jacobi、色間 Gauss-Seidel)在兩個裝置上的實作;GPU kernel 呼叫同一個 `QuatBody6` 的方法。parity 非逐位:乘加收縮不同,且箱堆接觸裁剪是離散分支(系統對 1e-7 擾動混沌),故以 CPU 自身擾動發散為界 | `test_gpu_contact`(四場景 GPU−CPU ≤ 2× CPU 自身發散 + 靜止狀態 by action + 接觸數 / island 數相同;單體無接觸;拒絕關節) | `bench_gpu_contact`(N=64..4096:CPU 串行 / 多核 / GPU 整幀,GPU 拆 上傳 / 計算 / 下載 / CPU 簿記) |

### 2.9 動畫圖節點(Phase 17.6,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 混合節點家族:1-D 空間 / 2-D gradient band / 遮罩層 / 加法(× 混合模式 LINEAR / DLB / GEODESIC) | procedural/anim_graph.mojo、procedural/anim.mojo(`blend_bone`) | 每個節點是姿勢的凸組合;邊界權重為投影(恰回傳某一輸入)——節點家族在頂點上的限制都是恆等 | `test_anim_graph`(樣本點上 = 該 clip 逐位、遮罩 0/1、加法權重 0;2-D 權重非負且和為 1;NaN clip 權重 0 不外溢) | `bench_anim_graph`(骨數 16/64/256 × 節點組合 × DLB/geodesic) |

### 2.10 角色 IK(Phase 17.3,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 兩段鏈 IK:解析(`two_bone`)vs 迭代(`fabrik`) | procedural/ik.mojo | 同一「末端到目標且保骨長」映射的閉式與不動點迭代兩實作;選哪個膝位置由 pole(解析)或起始姿勢(迭代)決定,末端與骨長相同 | `test_ik`(末端相同、骨長保持;極端:不可達、目標在根、pole 共線、零長骨、NaN) | `bench_ik`(解析 vs FABRIK 同腿;FABRIK 4/16/64 關節) |

### 2.11 主動布娃娃驅動(Phase 17.2,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 關節驅動:無驅動 vs `AngularDrive`(強度 0..1) | physics/joints6.mojo、physics/solver6.mojo、gameplay/ragdoll.mojo | 驅動器是疊加在關節約束上的軟態射;力矩上限為 0 時為恆等(零衝量),逐骨權重 0/1 在姿態混合上是投影 | `test_ragdoll`(零上限 == 無驅動逐位;混合權重 0 == 動畫、1 == 物理) | `bench_ragdoll`(N 條腿,驅動 vs 僅關節) |

### 2.12 接觸修改與關節斷裂(Phase 17.26 / 17.29,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 接觸是否生效 / 如何作用:靜態過濾(`set_filter`)vs 動態規則(`ContactRule`) | physics/contact6.mojo、physics/solver6.mojo | 同一「接觸謂詞」的兩層;不匹配任何接觸的規則(與零速輸送帶)是恆等 | `test_contact_rules`(不匹配規則 == 無規則逐位) | `bench_contact_rules`(無規則 / 全匹配 / 8 條不匹配) |
| 關節負載估計:最後子步 vs 逐子步峰值 | physics/joints6.mojo(`sample_loads`、`check_breaks`) | 同一負載量的兩個取樣;穩態一致(m·g),衝擊時只有峰值取樣看得到 | `test_joint_break`(懸掛質量 = m·g;扭轉 hinge 只在峰值取樣下斷) | `bench_contact_rules`(有 / 無閾值) |
| 接觸 / 關節的整步衝量估計:`IMPULSE_LAST_SUBSTEP`(末子步 × 子步數)vs `IMPULSE_SUBSTEP_SUM`(逐子步加總)(`SolverConfig.impulse_estimator`) | physics/contact6.mojo(`accumulate_step_impulse`)、physics/solver6.mojo(`_report_substep`、`_emit_events`、`contacts_of`、`joint_reaction`)、physics/solver_config.mojo | 同一「整步衝量」量的兩個估計;穩態時兩者是同一個數(每子步衝量相同),衝擊時末子步看不到已被前面子步吸收的部分 | `test_impact_report`(靜置疊塔兩估計都讀 3 m g;5 m/s 落球:加總 5.1633 = m v + m g dt,末子步 0.1633;serial == island 平行逐位) | `bench_impact_report`(N = 256 / 1024 靜置接觸;交錯 A/B 比 1.003,未分辨) |

### 2.13 力場、浮力、繩索、地形變形(Phase 17.27 / 17.28 / 17.41 / 17.30,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 風速來源:常數 vs `WindGrid` 取樣 | physics/fields.mojo | 常數場是網格取樣態射的常數截面;三線性插值對常數網格是恆等 | `test_fields`(常數網格 == 常數風逐位) | `bench_fields` |
| 浸沒體積:閉式(軸對齊盒、球)vs 中點積分 | physics/fields.mojo | 同一體積泛函的精確與數值求積 | `test_fields`(11 水位差 < V/16) | `bench_fields`(8³ / 16³ vs 球閉式) |
| 繩索:XPBD 1D 鏈 vs 距離關節剛體鏈 | physics/rope.mojo、physics/joints6.mojo | 同一懸鏈線的兩個離散化 | `test_rope`(兩者與解析下垂 5% 內) | `bench_rope` |
| 高度場邊界:區塊摘要增量 vs 全表重掃 | collision/trimesh.mojo、collision/collider_set.mojo | 同一 min / max 歸約的兩種結合律分組(max 的結合律 ⇒ 結果逐位相同) | `test_terrain_deform`(每次編輯 AABB 逐位相同) | `bench_terrain_deform` |

### 2.14 物理 LOD 與決定論回放(Phase 17.31 / 17.39,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 求解品質:全品質 vs LOD(凍結 / iters / substeps) | physics/solver6.mojo(`freeze`)、physics/lod.mojo | 同一不動點迭代在不同 iters / substeps 下的實例;凍結 = 動作型別的暫時投影到 STATIC,解凍是其逆 | `test_lod`(全覆蓋 LOD + 天花板預算 == 原解算器逐位;解凍後速度逐位相同) | `bench_lod`(iters 1–8 成本 vs 誤差;凍結一半) |
| 回放:全程重跑 vs 快照 + 短重跑 | gameplay/replay.mojo | `sim_tick` 的 n 次合成;快照是中間狀態的忠實表示,故從任一快照續合成等於從頭合成 | `test_replay`(8 個目標 tick 逐位相同;分歧定位) | `bench_replay`(尋位延遲 vs 快照間隔) |

### 2.15 存檔(Phase 17.40,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 保存路徑:schema 存檔(選擇性、跨版本)vs 決定論全狀態快照 | gameplay/save.mojo、physics/serialize.mojo | 存檔是快照的投影(只保留選定欄位);在投影涵蓋的欄位上兩條「存 → 讀」路徑相等 | `test_save`(涵蓋欄位逐位相同;V1 → V2 按名稱) | `bench_save`(位元組與時間,64 / 1024 體) |

### 2.16 LBM 風洞收尾與 SPH 邊界(Phase 17.42,2026-09-29)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 固體邊界:半程 vs Bouzidi 插值 bounce-back | fluid/lbm.mojo | 插值族在 q = ½ 的截面即半程 | `test_lbm_bounce`(盒狀固體逐位相同;球的次格敏感度) | `bench_lbm_gpu`(CPU 每步成本) |
| 測力:動量交換 vs 控制面動量通量 | fluid/lbm.mojo | 同一動量平衡的邊界形式與體積形式 | `test_lbm_bounce`(1.5% 內) | `bench_lbm_gpu` |
| 裝置:CPU `Lbm` vs `LbmGpu` | fluid/lbm_gpu.mojo | 同一 stencil 的兩個裝置實作 | `test_lbm_gpu`(3.6e-7;通道逐位) | `bench_lbm_gpu`(MLUPS) |
| SPH 牆面:夾回 vs 邊界粒子 | physics/sph.mojo | `sph_step` 是 `sph_step_boundary` 在空邊界上的限制 | `test_sph_boundary`(空 / 核外邊界逐位相同) | — |

### 2.17 破壞 / 破碎(Phase 17.5,2026-10-08)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 凸分解演算法:階層軸平面切分(`SplitDecomposer`)vs 體素 k-means(`ClusterDecomposer`),同在 `ConvexDecomposer` trait 後 | geometry/convex_decomp.mojo | 兩者都是「體素集合 → 凸覆蓋」的函子,共同的可觀察定律是覆蓋(每個體素在某個凸塊內)與 narrowphase 一致(GJK / `hull_manifold` 對非擦邊探針給相同的命中 / 未命中);差別只在冗餘(excess)與成本 | `test_convex_decomp`(覆蓋 ≥ 0.999、excess ≤ 35 %、兩者體積差 ≤ 25 %、L / U 板 81 + 41 個非擦邊探針逐一一致、`hull_manifold` 對同一探針一致) | `bench_fracture`(L / U 板:零件數、excess、時間) |

### 2.18 載具輪胎接觸(Phase 17.4,2026-10-09)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 輪-路接觸:單射線(`RayWheel`)vs 球掃(`SphereWheel`)vs 膠囊掃(`CapsuleWheel`),同在 `WheelCast` trait 後 | gameplay/vehicle_wheel.mojo | 三者都是「懸吊座 + 方向 → 輪心高度 / 接觸點 / 法向」的函子;共同的可觀察定律是在**平面路面**(平地、20° 斜坡、heightfield)上給相同的輪心距離、接觸點與法向(射線的輪心距離以 `t − R/cos` 修正坡度,所以與球掃在平面上精確相同);差別只在路面於一個輪半徑內**非平面**處——路緣、窄坑——掃描看得到邊緣,射線只看到安裝點正下方,測試把這個差異當作被斷言的行為而非容差 | `test_vehicle_wheel`(133:三變體平地 / 斜坡解析 / heightfield / 動態體 / 濾除 / 路緣差異 / 窄坑 / 牆邊回退 / 極端);`test_vehicle`(整車同一路徑:球掃 / 膠囊掃與射線在 1 % 內) | `bench_vehicle`(N 車 × 子步,三變體) |

### 2.19 導航尋路與動態挖洞(Phase 17.14,2026-10-11)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 尋路:多邊形 A* + funnel(+ 可見性平滑)(`PolyFunnel`)vs 8 連通 span A*(`GridAStar`)vs 每目標一張 Dijkstra 積分場(`FlowFieldPath`)vs tile 階層 HPA* + 遮罩 funnel(`HierFunnel`),同在 `PathFinder` trait 後 | nav/path.mojo、nav/hpa.mojo | 三者都是「(起點, 終點) → 可走折線」的函子,在同一張可走圖(含 off-mesh link 邊)上;可觀察定律是可達性相同、每段行走線段通過 `NavMesh.raycast`、`GridAStar` 與 `FlowFieldPath` 長度相同(同一圖上的兩個精確最短路),funnel(任意角)與 octile 長度落在寫明的經驗界內 | `test_nav_parity`(400 個種子查詢,含不可達、off-mesh、挖洞後重查);`test_nav`(繞牆、坡道、台階、低天花板、洞、off-mesh) | `bench_nav`(同 200 查詢三變體:每查詢成本、展開節點、平均長度;5000 agent 同目標:逐 agent funnel vs 一張流場;128 m 迷宮長查詢:平面 vs HPA*) |
| 群眾避讓:`Orca`(RVO2 半平面 + 增量 2D LP 逐行移植)vs `SampledRvo`(取樣式互惠速度障礙)vs `SocialForce`(Helbing 指數斥力),同在 `Avoidance` trait 後,由 `Crowd[A]` 驅動 | nav/crowd.mojo | 三者都是「(鄰居狀態, 偏好速度) → 新速度」的函子;可觀察定律是同場景(對心交換、走廊對衝、單門瓶頸、重疊出生、off-mesh 跳躍)全員到達、不離開 navmesh、兩次執行逐位相同;重疊深度是被量測的差異(開闊地 ORCA 在 2 % 半徑內,牆邊因 navmesh 滑動破壞互惠而放寬到 15 %) | `test_crowd`(52) | `bench_crowd`(N = 64 / 256 / 1024:每 agent-tick 成本、到達率、平均到達時間、最深重疊、重新規劃數) |
| 3D 體積尋路:稀疏體素八叉樹葉上的 A*(`SvoAStar`,portal 成本模型)vs 稠密 26 連通體素 A*(`SmoothedVoxelAStar`),同在 `VolumeFinder` trait 後,兩者都接同一個視線平滑 | nav/volume.mojo | 兩者都是「(起點, 終點) → 自由空間折線」的函子,在同一張膨脹後的佔據格上;定律是可達性相同(八叉樹自由葉的鄰接 = 自由體素的面連通)、每段通過 `line_of_sight`、平滑後長度在 15 % 內 | `test_nav_volume`(60 個種子查詢 + 窗戶進入 / 窄窗 / 牆內目標 / 空體積) | `bench_nav`(體積表:建樹、葉數、兩變體每查詢成本與展開節點) |
| 動態障礙:增量 `update`(只重算變動窗的 blocked / 侵蝕、只重建被觸及的 tile)vs `rebuild_all` vs 重新烘焙 | nav/navmesh.mojo、nav/heightfield.mojo(`erode_window`) | 同一「障礙集合 → navmesh」映射的增量與全量實作;窗內侵蝕的正確性由 chamfer 最短路的單調性保證(見 `erode_window` 註解),多邊形與連結逐位相同 | `test_nav`(堵住缺口 == 全量重建;移除後 == 原烘焙)、`test_nav_world`(12 次隨機增刪,每步 == 全量重建) | `bench_nav`(動態障礙表) |

### 2.20 AI 決策(Phase 17.15,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 決策:behavior tree(`BtDecider`)vs 守衛式 FSM(`FsmDecider`,`procedural.fsm`)vs utility(`UtilityDecider`)vs GOAP 規劃(`GoapDecider`),同在 `Decider` trait 後 | ai/decision.mojo、ai/bt.mojo、ai/utility.mojo、ai/planner.mojo | 四者都是「黑板 → 動作」的函子;可觀察定律是對同一份規則清單(巡邏 / 追擊 / 攻擊 / 搜索 / 逃跑)每個輸入給相同動作 —— 「行為等價」由規則清單本身當 oracle 定義,而不是四者互比 | `test_ai_decision`(600 tick 劇本 + 2000 個種子隨機黑板,四者皆 = 規則) | `bench_ai`(每次決策成本;GOAP 規劃隨動作數;BT tick 隨樹大小) |

### 2.21 分級模擬(Phase 17.85,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 分級策略:`DistanceTiers` vs `CausalReach` vs `RoundRobin` vs `BudgetTiers`,同在 `TierPolicy` trait 後;由 `ContactScene6` 的 tier 表(逐 tier 的 iters / substeps / period)逐 island 套用 | gameplay/tiers.mojo、physics/solver6.mojo(`_step_tiered`) | 四者都是「(場景, 觀察者集合, step) → 每 body 的 tier」的函子;單位元是全 0 計畫(tier 0 = 該步自身設定),它與不分級的步進**逐位相同**(自然性方格的錨點);距離與因果可達一致的場景上 `DistanceTiers` 與 `CausalReach` 給同一計畫、同一世界 | `test_tiers_parity`(QuatBody6 × BVH / 持久 DBVH、ScrewBody6;`Runtime.advance_tiered` 全 0 == `advance`;`TieredScheduler` period 1 == 內層)、`test_tiers`(遲滯不抖動、RoundRobin 每週期每島恰一次、catch-up 保時間、因果深度單調、合併取較細、period 0 靜止、回退計數)、`test_system_tiers`(1800 個 awake body:無 pop、速度跳變 ≤ 一個粗步重力、快照 → 還原 → 續跑逐位相同) | `bench_tiers`(n = 1e3 / 1e4,每策略每步成本、解的 island 數、相對全品質的穿透增量) |

這一列取代 §2.14 的「品質參數 seam」說明(該處沒有 trait 支撐)。

### 2.22 網路預測策略(Phase 17.16,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 預測策略:`LockstepPeer` vs `RollbackPeer` vs `SnapshotServer` + `SnapshotClient`,同在 `NetPeer` trait 後,驅動同一個 `NetSim` | gameplay/netcode.mojo | 三者都是「(輸入序列, 有損連線) → 最終世界」的函子;定律是最終世界雜湊 == 離線依序套用同一輸入(延遲、抖動、丟包下逐位成立);差別只在顯示落後幾 tick、CPU(重模擬)與頻寬 | `test_netcode`(3 玩家 240 tick、10 % 丟包,三策略皆 == 離線參考) | `bench_netcode`(延遲 2 / 6 tick:每 frame 時間、位元組、顯示落後、回滾與重模擬數) |

### 2.23 嵌入邊界(Phase 12.1,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 驅動者:C 宿主經 `libludens.so`(系統與接觸訂閱為 C 回呼)vs Mojo 原生在 `EmbedWorld` 上的迴圈 | embed/capi.mojo、embed/world.mojo | C-ABI 是 `EmbedWorld` 操作的忠實函子(每個 `ld_*` 對應一個方法,值經編碼 / 解碼往返不變);定律是同一操作序列在兩邊產生同一世界(存檔雜湊逐位相同) | `test_capi`(13 body、240 tick、C 系統 + C 訂閱者 vs 原生:雜湊、事件數、射線、導航路徑相同) | `bench_capi`(同一步進、逐 body 取狀態、批次姿態、存 / 讀檔:C vs 原生) |

### 2.24 腳本驅動者(Phase 17.21,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 驅動者:Python(`ludens` 套件,ctypes 包 C-ABI,裝在乾淨 venv)vs C 宿主 vs Mojo 原生 `EmbedWorld`;另含 CVar 變更 vs 直接呼叫、hot reload vs 切換函式 | python/ludens/*.py | 三個驅動語言是同一組世界操作的三個表示;定律是同一操作序列產生同一世界(存檔雜湊);CVar 與 hot reload 是「延遲到 tick 邊界的同一操作」,定律是與在該邊界直接操作逐位相同 | `test_python_binding`(雜湊 == 原生 == `test_capi` 的 C 宿主;CVar / hot reload 等式在 client 端檢查) | `bench_python`(步進、單次呼叫、批次姿態、回呼開銷:Python vs 原生) |

### 2.25 座標策略(Phase 17.8,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 座標策略:`AbsoluteF32` vs `RebasedF32`(同在 `CoordStrategy` 後)vs f64 建置變體(`build64/`) | gameplay/large_world.mojo、physics/solver6.mojo(`shift_origin`)、scripts/build_f64.sh | 位移是平移群作用;模擬對平移等變,故「位移後模擬 == 模擬後位移」在 f32 中於 2 的冪格點上逐位成立(原點處 vs 1e6 / 1e7 m 處逐位相同),否則每座標一次捨入;f64 是同一程式在另一個純量體上的實例,小世界差異只來自捨入 | `test_large_world`(遠處 == 原點逐位、位移中途無衝擊、存讀檔續跑、小世界兩策略逐位)、`test_world_f64`(f64 建置、小世界 f32 / f64 一致) | `bench_large_world`(距離 1 m–1e7 m 精度曲線:三種設定;位移與串流成本) |

### 2.26 派發器(Phase 17.75,2026-10-12)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| 派發器:`parallelize` / 串行 / 反序 / 宿主 C 回呼(`Dispatch`,`dispatch_for`) | scheduler/dispatch.mojo、physics/solver6.mojo、physics/contact6.mojo、physics/diffsolver.mojo | 各 fan-out 的項寫不相交狀態,故結果是項集合上的函數、與執行順序與執行緒無關;定律是四種派發的快照位元組相同 | `test_dispatch`(island 與同色 fan-out,四種派發) | 尚無(待補每步派發開銷列) |

### 2.27 凸形表示:點雲 vs support mapping(Phase 17.52,2026-10-13)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `Support3`:點雲 `ConvexPoly[3]` vs 解析 support(`SupportEllipsoid` / `SupportCylinder` / `SupportCapsule` / `SupportBox`),共用 GJK 距離(`support_distance`)與 EPA(`epa3`) | geometry/gjk.mojo、geometry/support.mojo、geometry/gjk_distance.mojo、geometry/epa.mojo | 凸集由 support 函數 h(d) 唯一決定;同一凸集的兩個表示給出同一距離 / 穿透函數。點雲是取樣近似,解析 support 是精確表示:圓柱 16 邊形的距離誤差 r(1 − cos(π/16)) 由解析表示消去 | `test_support3`(200 對隨機點雲:`support_distance` == `convex_distance` 至 1e-5;等軸橢球與球 EPA 深度一致);`test_ellipsoid`(等軸橢球靜止高度 == 球 0.49972457,滾動 2.3941412 == 5/7 g sin θ) | `bench_shapes`(每 body-step:球 / 橢球 / 圓柱 / 盒 / SDF;點到圓柱距離:解析 vs 16 邊形) |

### 2.28 距離場表示:解析 vs 取樣(Phase 17.52,2026-10-13)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| `DistanceField3`:解析 `Sdf3`(基元 + CSG)vs 取樣 `SdfGrid`(三線性格點);`sphere_trace`、`SdfGrid.from_field` 對兩者共用 | geometry/distance_field.mojo、geometry/sdf3.mojo、geometry/sdf_grid.mojo、collision/world_query.mojo | 同一距離函數的兩個表示;取樣是解析的離散化(誤差 ≤ 一格),節點上相等 | `test_distance_field`(射線 t 兩者 1e-3 內;節點值 `from_field(Sdf3.plane)` == 手填,靜止高度逐位相同) | `bench_shapes`(盒在 SDF 上每 body-step) |

### 2.29 多部件剛體:單 body 複合 vs 焊接多 body(Phase 17.44,2026-10-13)

| Seam | 檔案 | 範疇論解讀 | 定律測試 | Benchmark |
|---|---|---|---|---|
| (a) `add_compound`(一個 body、N 個凸子形狀)vs (b) N 個 body + `JOINT_WELD`(17.5)vs (c) 單一子形狀退化為一般形狀 | collision/collider_set.mojo(`CompoundSpec`、`kid_*`、`shape_pair`)、collision/contact_gen.mojo(`try_compound_pair`)、physics/mass_props.mojo、physics/solver6.mojo | 同一剛性物體的三個表示;(a)(c) 是同一接觸分派(`ShapeDesc` 對 `ShapeDesc`)在子形狀上的展開,(a) 與 (b) 只差焊接殘差 | `test_compound`(單一子形狀 == 一般盒逐位;兩半盒對整盒在穿透 slop 內;brute == BVH 逐位;質量 / 質心 / 主慣量對手算張量) | `bench_compound`(N = 2–64:複合 44–1881 µs/步,焊接 77–2616 µs/步) |

## 3. SE(3) 的三個表示函子(GA 層)

剛體運動群 SE(3) 是單對象範疇(群 = 只有一個對象的 groupoid)。三個「表示」
各是一個忠實函子,把抽象運動送到可計算的載體:

```
           R_motor(8f 偶次子代數)
  SE(3) ──R_dq(8f 對偶四元數)──▶  (作用於 ℝ³ 的具體變換)
           R_mat(16f 齊次矩陣)
```

- **群律**(結合律/單位元/逆)—— `test_laws.mojo` 以「作用等價」逐點檢查
  (motor 與 −motor 是同一運動,故不比係數比作用)。
- **函子律** `F(m₁·m₂) = F(m₁)·F(m₂)` —— `to_mat4`、`DualQuat.from_motor`
  各自保持合成(`test_laws.mojo`)。
- **自然同構** —— 三個表示對每個點的作用一致(`test_motor_parity` 285 檢查:
  motor ≡ quat+t ≡ mat4 ≡ dq;`to_motor`/`from_motor` 是互逆的自然變換)。
- **Lie 對應** —— `exp/log`(geometry/galie.mojo)是李代數(bivector 空間)
  與李群(motor 流形)之間的局部同構;`geodesic` 是單參數子群的軌道。
  `exp(log(M)) = M` 與「1 大步 = 10 小步」(exact helix)由
  `test_motor_parity`/`test_motor_transform` 檢查。

## 4. 為什麼值得:定律 = 免費的重構保險

- 換 backend、換 solver、換傳播策略、換剛體表示 —— 每一種「換」都有一個已
  機械化的交換方格。破壞方格的變更會被測試立刻抓住。
- 新表示(如未來的 CGA 剛體、或 GPU 端矩陣)接入的驗收標準是明確的:提供到
  既有表示的自然變換 + 函子律測試,而非重寫遊戲邏輯。
- `Multivector[p,q,r]` 本身是「簽名 ↦ 代數」的(comptime)函子:同一份積表
  生成器對每個度規簽名給出一個代數,PGA2/PGA3/CGA3 只是它在三個對象上的值。

## 5. 已知的非定律(誠實清單)

- Motor 無法表示縮放 —— `MotorTransform` 只涵蓋剛體子群;含 scale 的層級請
  走矩陣路徑(`Transform`)。兩者的交集(scale=1)上 parity 成立
  (`test_motor_transform`)。
- 浮點下所有「定律」都是 ε-定律(容差 1e-3~1e-4);結合律在極端量級下會退化。
- `apply_point`(sandwich)比手工 DQ/矩陣慢(泛型積的代價)—— 批次點變換應
  `to_mat4()` 後走矩陣或 SIMD 欄(見 `bench_ga` 數據)。
- `CgaSphereNarrowPhase`(G4 已升格進 collision seam)精度與解析路徑 100%
  parity(`test_cga_narrowphase`),但每測約 4×(≈12 vs ≈3 ns;dual 球是 32
  float 的 multivector)。它的價值是統一 formalism,不是速度。
