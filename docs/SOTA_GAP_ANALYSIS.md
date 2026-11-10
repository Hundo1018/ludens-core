# SOTA 差距分析:ludens-core × 前沿數學 / 前沿物理 / 前沿引擎 / SOTA 引擎

> 2026-07-10。方法:內部全量盤點(~12,900 行 Mojo、44 測試檔、10 benchmark、docs/experiments 全讀)
> + 三路外部研究(2023–2026 文獻與引擎官方文件,出處 URL 全附)。
> 結論先講:**數學核完成度高、且正踩在 PGA 研究前沿上;缺的是引擎外殼 —— 最大且最可補的缺口是
> 角動力學與現代 contact solver,而這個缺口恰好有 GA 原生解法。**
> 補缺排程見 [ROADMAP.md](ROADMAP.md)。

---

## 0. 現況一句話

一個 seam-swappable、parity-tested 的**引擎核心**:5 個 ECS backends、broadphase/narrowphase
全家桶、3 種 contact solver(僅線性)、signature-generic `Multivector[p,q,r]` + motors +
Lie exp/log + GA 前向自動微分 + motor skinning + CGA narrowphase。
**不是**一個能出畫面的遊戲引擎:渲染、GPU、資產/序列化、動畫 runtime、音訊、輸入、網路、
導航、腳本、編輯器全缺。

---

## 1. 軸一:前沿數學研究(PGA/CGA、Lie 理論、GA 軟體、Clifford ML)

### 我們有什麼

| 能力 | 位置 | 狀態 |
|---|---|---|
| Signature-generic Clifford 代數 `Multivector[p,q,r]`(comptime 展開為直線 FMA) | `geometry/multivector.mojo` | 已測(`test_ga_core`) |
| 係數域泛型 `GMV[p,q,r,F]` + `DualReal` 前向自動微分 | `geometry/gmv.mojo`、`geometry/field.mojo` | 已測(`test_gmv_ad`) |
| PGA motors(Motor2/Motor3 ≅ DQ)、閉式 exp/log/geodesic | `geometry/motor.mojo`、`geometry/galie.mojo` | 285 項 parity(`test_motor_parity`) |
| Motor DLB skinning(修 candy-wrapper) | `geometry/skinning.mojo` | 已測 + benchmark |
| CGA(Cl(4,1))incidence:球/平面/null-cone lift | `geometry/cga.mojo` | 已測(`test_cga_plane`) |
| 實驗:AD-IK、CGA meet、Clifford NN、DEC | `experiments/exp_*.mojo` | 自檢式 probe |

### 前沿在哪裡

- **PGA 動力學已有完整教科書級公式**:Dorst–De Keninck《May the forque be with you》直接在
  motor/bivector 上寫出 momentum、forque、Euler 方程,免 inertia-tensor 矩陣搬運
  ([PGAdyn](https://bivector.net/PGAdyn.pdf), 2023)。Gunn 的 PGA 框架把 quaternion/DQ/screw
  全部收為子代數,並點名「原生支援自動微分」([arXiv:1901.05873](https://arxiv.org/abs/1901.05873);
  [SIGGRAPH 2019 course](https://arxiv.org/abs/2002.04509))。
- **無矩陣管線已被證明可行**:De Keninck《Look, Ma, No Matrices!》(SIGGRAPH 2024)用純 motor
  跑完整 glTF forward renderer(transform→skin→blend),並收掉 tangent-space 設置成本
  ([專案頁](https://enkimute.github.io/LookMaNoMatrices/);
  [ACM](https://dl.acm.org/doi/abs/10.1145/3641233.3665801))。
- **退化度規的效能紅利**:利用 PGA 的 r=1 null 基向量做更快/更穩的運算
  ([arXiv:2408.13441](https://arxiv.org/abs/2408.13441), 2024)。
- **GA 軟體版圖有空位**:最快的原生 PGA 庫 klein **已封存停止維護**
  ([github](https://github.com/jeremyong/klein));robotics 的 gafro 證明模板化 GA 在 kinematics
  上能贏 Pinocchio/KDL([arXiv:2310.19090](https://arxiv.org/abs/2310.19090);
  [github](https://github.com/idiap/gafro))。教訓一致:**GA 要快只能靠 grade-aware 符號化簡
  codegen**(GAALOP 路線)—— 這正是 Mojo comptime 的主場,本引擎的 comptime 展開已在做對的事。
- **Multivector 已是 ML 基座**:GATr(PGA-multivector transformer,
  [arXiv:2305.18415](https://arxiv.org/abs/2305.18415), NeurIPS 2023)、Clifford Group
  Equivariant NN([arXiv:2305.11141](https://arxiv.org/abs/2305.11141))在 n-body/PDE 代理上
  SOTA —— 有 autodiff 的 GA 引擎可以原生承載 learned physics。
- **Lie-group / variational integrators**:SE(3) 變分積分器 symplectic + 動量守恆,2024–25 有
  碰撞版(LGVCI, [SIAM JADS 2024](https://doi.org/10.1137/24m1647060));screw theory ↔ se(3) ↔
  Featherstone O(n) 的等價已被系統化([arXiv:2306.17415](https://arxiv.org/abs/2306.17415))——
  **Featherstone spatial vectors 本質上就是 motors**,motor 核可以表達 O(n) 關節動力學。
- **穩健性底線**:GA 的 meet/join 優雅,但 watertight 碰撞仍需 Shewchuk 級 exact predicates /
  interval filters 撐底([arXiv:2208.00497](https://arxiv.org/abs/2208.00497))。

### 差距判定

| # | 差距 | 嚴重度 |
|---|---|---|
| M1 | **PGAdyn 動力學未實作**:motor/bivector 只做了 kinematics(`physics/screw.mojo` 有 pose+velocity 積分,無 inertia、無 forque、未接 contact solver) | 高(但也是最大機會) |
| M2 | 自動微分僅 forward-mode 單 dual;無 reverse-mode / batch,離 Warp/Slang 級 AD 有距離 | 中 |
| M3 | 無 exact predicates / interval 穩健層 | 中 |
| M4 | GA codegen 尚未做 grade-aware 符號化簡到「證明贏過手寫解析路徑」的程度(CGA narrowphase 每測 ≈12 vs ≈3 ns,~4×,見 `narrowphase.mojo:174`、`CATEGORY.md`) | 中 |

---

## 2. 軸二:前沿物理研究(2023–2026)

### 前沿在哪裡

- **Sub-stepping 小步定理**:一次 XPBD 迭代 × 多個小步 > 多次迭代 × 大步
  (Macklin《Small Steps》, [mmacklin.com](https://mmacklin.com/smallsteps.pdf))—— 今日所有
  現代 solver 的理論根基。後繼:XPBI([arXiv:2405.11694](https://arxiv.org/html/2405.11694v1))、
  MGPBD 多重網格([arXiv:2505.13390](https://arxiv.org/html/2505.13390v1))。
- **保證無穿透路線**:IPC → ABD([arXiv:2201.10022](https://arxiv.org/pdf/2201.10022))→
  GIPC([arXiv:2308.09400](https://arxiv.org/pdf/2308.09400))→ StiffGIPC(較前代 GPU IPC
  最高 10×,[arXiv:2411.06224](https://arxiv.org/abs/2411.06224))。
- **2024 年的突破是 VBD**:Vertex Block Descent —— 對 implicit-Euler 變分能量做 vertex 級
  Gauss-Seidel,無條件穩定、大規模平行、可用迭代數精準控預算
  ([arXiv:2403.06321](https://arxiv.org/pdf/2403.06321));**AVBD**(SIGGRAPH 2025)擴到剛體、
  硬約束、堆疊([Utah 專案頁](https://graphics.cs.utah.edu/research/projects/avbd/))——
  統一 real-time solver 的最有力候選。
- **MPM 進了遊戲**:EA SEED 的 PB-MPM(SIGGRAPH 2024)任意時步穩定、real-time、開源
  ([ea.com/seed](https://www.ea.com/seed/news/siggraph2024-pbmpm));CK-MPM 加速 grid transfer
  ([arXiv:2412.10399](https://arxiv.org/pdf/2412.10399))。
- **接觸模型**:primal-dual interior-point 摩擦(SIGGRAPH 2024,二次收斂,
  [ACM](https://dl.acm.org/doi/10.1145/3641519.3657485));MuJoCo 的 convex NCP 仍是 robotics
  基準([docs](https://mujoco.readthedocs.io/))。
- **領域已決定性轉向 GPU-first**:VBD、GIPC、PB-MPM、Genesis、Newton 全是 GPU-first 設計。
- **可微模擬成為基線能力**:Warp、Brax(梯度病態問題見
  [arXiv:2506.14186](https://arxiv.org/pdf/2506.14186))、DiffXPBD
  ([arXiv:2301.01396](https://arxiv.org/abs/2301.01396));NVIDIA+DeepMind+Disney 的 **Newton**
  (Warp+OpenUSD,2025)報 humanoid ~70×
  ([NVIDIA blog](https://developer.nvidia.com/blog/announcing-newton-an-open-source-physics-engine-for-robotics-simulation/));
  Genesis 宣稱 43M FPS([報導](https://the-decoder.com/genesis-speeds-up-ai-robot-training-with-simulations-430000x-faster-than-reality/))。

### 差距判定

我們的 XPBD(`physics/solver.mojo`)是正確的起點但停在線性、單步、無 GPU。VBD/AVBD、PB-MPM、
IPC 系全部不在射程內 —— 除非先補齊角動力學與 sub-stepping(見軸四),否則前沿物理研究無從接入。
可微模擬是例外:`GMV[…,DualReal]` 已是入場券,擴充 AD 就能對標。

---

## 3. 軸三:前沿引擎研究(ECS、排程、GPU-driven、效能語言)

### 我們有什麼 vs 前沿

| 主題 | 我們 | 2026 前沿 | 差距 |
|---|---|---|---|
| ECS 儲存 | 5 backends(sparse/archetype/bitset/reactive/naive),parity-proven;archetype `for_each2` 0.31 vs OOP 1.09 ns/op @N=65536(`ECS_VS_OOP_INVESTIGATION.md`) | archetype vs sparse 的取捨已是定論([EG 比較研究](https://diglib.eg.org/items/6e291ae6-e32c-4c21-a89b-021fd9986ede)) | **小** —— 這部分已達水準 |
| ECS relationships | 無(只有 `Parent` component + hierarchy rebuild) | flecs v4 一級公民 relationships + wildcard queries([github](https://github.com/SanderMertens/flecs));Bevy relations 已入 main([bevy 0.16](https://bevy.org/news/bevy-0-16/)) | **中** —— 2026 table stakes |
| Reactive/observers | `reactive_backend.mojo` 雛形(Entitas 式 groups) | Bevy observers(push-based) | 中 |
| 排程 | Sequential + 兩種 actor 排程器 + Serial/Parallel policy(`scheduler/`) | DOTS 式 job graph 自動讀寫依賴 + structural-change command buffer([Unity Entities 1.0](https://docs.unity3d.com)) | 中 |
| GPU-driven rendering | 無 | Nanite visibility buffer、Unity 6 GPU Resident Drawer([blog](https://unity.com/blog/unity-6-features-announcement)) | 大(**刻意不追**,見 ROADMAP) |
| 效能語言定位 | Mojo nightly,comptime GA codegen | Slang 有 first-class autodiff 但僅 shader-scoped([shader-slang.org](https://shader-slang.org));Mojo GPU kernels 與 CUDA/HIP 在 memory-bound 工作負載上大致相當([ORNL, arXiv:2509.21039](https://arxiv.org/abs/2509.21039)) | **機會**:無任何已知 Mojo 遊戲/物理引擎 —— first-mover |

---

## 4. 軸四:SOTA 遊戲/物理引擎(逐能力對照)

基準:Jolt([github](https://github.com/jrouwe/JoltPhysics);
[Guerrilla 架構文](https://www.guerrilla-games.com/read/architecting-jolt-physics-for-horizon-forbidden-west))、
PhysX 5([TGS/GPU docs](https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/GPURigidBodies.html))、
Box2D v3 Soft Step([release](https://box2d.org/posts/2024/08/releasing-box2d-3.0/);
[Solver2D](https://box2d.org/posts/2024/02/solver2d/))、Rapier([rapier.rs](https://rapier.rs/))、
UE Chaos([tech blog](https://www.unrealengine.com/tech-blog/chaos-scene-queries-and-rigid-body-engine-in-ue5))、
Havok 2024.2([blog](https://www.havok.com/blog/havok-2024-2-release-highlights/))。
引擎外殼基準:UE 5.6、Unity 6、Godot 4.6(Jolt 已成預設 3D 物理,
[release](https://godotengine.org/releases/4.6))。

### 「2026 競爭級物理引擎 10 能力」對照表

| # | 能力 | 狀態 | 證據 |
|---|---|---|---|
| 1 | Sub-stepped soft-constraint solver(TGS/Soft-Step/small-steps) | ❌ | `solver.mojo` 有 SI/PBD/XPBD 但單步、線性 |
| 2 | Incremental、parallel broadphase | ❌ | `step.mojo` 每步重建 BruteForce pipeline;BVH 只有 static rebuild |
| 3 | Persistent contact manifolds + CCD | ❌ | `Contact[dim]` 只有 hit/normal/depth,無接觸點(`narrowphase.mojo:29`);EPA 3D 回 zero depth(`epa.mojo:10`);CCD 0 hits |
| 4 | SIMD-first SoA + job system + 決定論 | ⚠️ 半 | SoA/SIMD/seedable RNG/fixed loop 都有;缺 job graph |
| 5 | GPU 加速路徑 | ❌ | 全 CPU |
| 6 | 穩定堆疊 / 高質量比 / 長鏈 | ❌ | 依賴 #1,未實作 |
| 7 | Joints 庫 + islands + sleeping + warm-starting | ❌ | 全部 0 hits |
| 8 | Character controller / vehicle | ❌ | 無 |
| 9 | Soft body / cloth / deformables 雙向耦合 | ❌ | 無 |
| 10 | 可微性 + ML-sim 整合 | ⚠️ 半 | GA forward-AD 已有(`gmv.mojo`+`field.mojo`),未達 rollout 級 |
| — | **角動力學(1–10 的共同前置)** | ❌ | `rigidbody.mojo` docstring 明言 linear-only,angular 因缺接觸點而 deferred;`screw.mojo` 路徑存在但未接 solver |

### 引擎外殼對照(一句話版)

渲染 ❌(僅 `systems/renders` 廢棄 Python pygfx 實驗)、資產/序列化 ❌、動畫 runtime ❌
(skinning 數學已有)、音訊 ❌、輸入 ❌、網路 ❌(但 deterministic RNG + actor model 是 rollback
的地基)、導航 ❌、腳本 ❌、編輯器/debug-draw ❌。

---

## 5. 機會 × 優先矩陣

| | 高衝擊 | 低衝擊 |
|---|---|---|
| **高契合(GA spine 直接受益)** | GA 角動力學(manifold + forque + variational integrator)、sub-stepped soft solver、GA comptime codegen 強化 | CGA curved-primitive 查詢 |
| **低契合(通用工程)** | 持久化 broadphase、joints/islands/sleeping、GPU 路徑(Mojo kernels) | 渲染外殼、資產管線、音訊/輸入 |

**核心判斷**:最大缺口(角動力學 + 現代 solver)與最強差異化(PGA motor 動力學)是**同一件事**。
`rigidbody.mojo` 自己寫著 angular 被 deferred 的原因是「缺接觸點」—— 所以第一張骨牌是
contact manifold,之後 PGAdyn 的 forque 公式直接補上 SOTA 引擎用 inertia tensor 做的事,
且天生免 gimbal/renormalization 問題、天生可微。詳細排程與驗收 gate 見
[ROADMAP.md](ROADMAP.md)。

## 6. 誠實註記(non-goals 的證據)

- CGA 不是效能路線:自家測得 ~4×(≈12 vs ≈3 ns,100% parity),價值是統一形式與交叉驗證
  (`docs/CATEGORY.md`、`collision/narrowphase.mojo:174`);學界同樣定位為 academic/robotics
  ([arXiv:2312.04598](https://arxiv.org/abs/2312.04598))。
- GPU-driven rendering(Nanite 級)成本最高、差異化最低,本輪明確不做;最低限渲染 demo 走
  [wgpu-mojo](https://github.com/Hundo1018/wgpu-mojo)。
