# CLAUDE.md

ludens-engine:以 Mojo 寫的遊戲引擎核心(ECS、碰撞、6-DOF 剛體、軟體、流體、可微模擬),
以 `Multivector[p,q,r]` 幾何代數為數學基底。無渲染層,無腳本層。

## 工具鏈

- Linux x86-64 + pixi。版本以 `pixi.toml` 為準(目前精確鎖定 `mojo ==1.2.0`、`modular ==26.7.0`);
  ROADMAP 中的 1.0.0 / 1.1.0 / 26.5.0 / 26.6.0 是舊紀錄。升版是刻意變更,需重跑整套 test + benchmark。
- 跨檔 import 只透過 `build/*.mojoc` 預編譯套件解析(原始碼目錄不會被搜尋),
  所以任何 run/test 之前都要先 `pixi run build`。
- GPU host API 在 `max.*`(`max.gpu.host`、`max.algorithm.parallelize`),不在 `std.*`。
  找不到符號時兩個 import root 都要查。
- 沒有 `mojo test` 與 `testing` 模組:每個測試是一般程式,用 `harness.runner.Suite`,
  結尾 `s.finish()` 失敗時回傳非零。

## 指令

```sh
pixi run build             # 依層序預編譯所有套件到 build/(scripts/build_engine.sh)
pixi run test              # arch-check + unit → component → integration → system,遇第一個失敗即停
pixi run test-all          # 再加 stress
pixi run test-unit         # 單一 tier:test-unit / -component / -integration / -system / -stress
pixi run arch-check        # 分層/循環/私有名稱穿透檢查 + 測試 tier 標頭檢查
pixi run arch -- <cmd>     # 架構索引查詢:def NAME / impl TRAIT / uses MOD / deps MOD / raises PKG / check / tiers
pixi run gate              # 變更的總閘門:整套測試 + 摘要 + 與 tests/golden/test_stdout.txt 比對
pixi run gate -- --update-golden   # 接受本次輸出為新 golden
LUDENS_TEST_JOBS=4 pixi run gate   # 同時跑 4 個測試檔(輸出依原順序印出,與循序執行逐位元相同)
pixi run gate -- --selftest        # 測試閘門工具本身(golden、archindex)
pixi run benchmark         # 重跑所有 bench,重新產生 BENCHMARK_REPORT.md
ONLY="bench_x.mojo" pixi run benchmark   # 只重跑列出的 bench,其餘取 build/bench_out/ 快取(需先有一次完整執行)
pixi run repro-probe       # 同 commit 連建兩次,比對 build/*.mojoc 校驗和(17.81)
pixi run icount            # cachegrind 指令數(固定工作量,散佈約 1e-3;--selftest 注入 +10 %)
pixi run fp-probe          # 哪些目標 / 優化因子改變模擬位元(只有 FMA 有無與 -O0;17.76)
pixi run flag-policy       # 浮點旗標政策:工具鏈精確鎖定、x86-64 目標釘死、無 fast-math / -O(ARCHITECTURE §6;17.84)
pixi run capi              # 建 C-ABI 共享庫 build/libludens.so(embed/capi.mojo;凍結清單 embed/abi_v0.txt)
pixi run build-f64         # 以 f64 世界純量建全部套件到 build64/(scripts/build_f64.sh,約 1 分鐘;17.8)
pixi run wheel             # 建 Python wheel build/dist/ludens-*.whl(python/;ctypes 包 C-ABI,內含 Mojo runtime)
pixi run bindings          # 由 embed/ludens.h 產生 bindings/rust/ludens_sys.rs(--check 檢查是否過時;test_capi 以 rustc 編譯並比對雜湊)
pixi run structure         # 由架構索引產生 docs/STRUCTURE.md(--check 檢查是否過時;17.87)
pixi run layers-sync       # CLAUDE.md / ARCHITECTURE.md 的套件分層表對 scripts/arch_layers.toml
pixi run roadmap-status -- --check   # ROADMAP 子系統表的計數對編號索引
pixi run install-hooks     # git config core.hooksPath .githooks(啟用 pre-commit / commit-msg / pre-push)
pixi run hooks-selftest    # hook 規則與文件產生器的 selftest
pixi run examples | experiments | spikes
```

單檔執行(需先 build):

```sh
pixi run mojo run -D ASSERT=all -I build tests/test_vec.mojo
pixi run mojo run -I build examples/06_ga_motor.mojo
```

`run_tests.sh` 以 `-D ASSERT=all` 執行,`debug_assert` 在測試中生效;單檔手動跑時也加上。
GPU 測試與 bench 在無加速器的主機上自動跳過(`has_accelerator`);裝置程式碼以 `pixi run gpu-compile`
(`--target-accelerator sm_86` 建置全部 GPU 測試 / bench,不執行)檢查可編譯。

## 套件分層

規則:套件只能 import **嚴格較低層**的套件與自身;同層互引禁止;套件內模組循環也禁止。
機器可讀版在 `scripts/arch_layers.toml`,說明在 `docs/ARCHITECTURE.md` §1,兩者須在同一個 commit 內更新。

| 層 | 套件 | 負責 |
|---:|---|---|
| 0 | `diag` | invariant、log、counters、trace、debug-draw、frame arena |
| 1 | `geometry` | 向量/矩陣/四元數、GA(PGA/CGA/DCGA)、AD 係數場、GJK/EPA/SAT/clip/SDF、靜態 BVH |
| 2 | `numerics` `spatial` `procedural` `fluid` `ecs` | 稀疏矩陣與 Krylov、動態空間索引、雜訊、動畫/IK、tween、FSM、LBM、ECS |
| 3 | `scheduler` `collision` `nav` | 系統排程/固定步長迴圈/事件/計時器/RNG;broadphase、narrowphase、manifold、CCD、場景查詢;navmesh 烘焙、尋路 seam、crowd |
| 4 | `physics` `ai` | 所有動力學求解器;AI(blackboard、BT、utility、GOAP / HTN、決策 seam、感知、EQS、轉向 / 群聚、smart objects、影響力圖) |
| 5 | `gameplay` | 角色控制、插值、ragdoll、replay、存檔、`runtime.mojo` |
| 6 | `oop` | 僅供比較 benchmark 用的 OOP 基準引擎 |
| 6 | `embed` | 嵌入邊界(12.1):`EmbedWorld` / `EmbedNav` 與 C-ABI 薄殼 `embed/capi.mojo`(→ `build/libludens.so`,標頭 `embed/ludens.h`) |

- `harness` 只能被 `tests/`、`benchmarks/`、`examples/`、`experiments/` import,引擎套件不得 import。
- 新增套件時要同時改 `scripts/build_engine.sh`(依層序加一行 `pc <pkg>`)與 `arch_layers.toml`。
- 底線開頭的名稱是套件私有;跨套件使用須改為公開名稱,或在 `arch_layers.toml` `[allow_private]` 附理由登記。

## 程式碼規範

- **可替換子系統藏在 trait 後面,編譯期選擇**;每個 seam 要有 parity 測試證明各實作可觀察行為相同
  (例:`test_backend_parity`、`test_scheduler_parity`),以及 `BENCHMARK_REPORT.md` 中的一列量測。
  效能主張要附數字。
- 錯誤處理依錯誤類別(`docs/ARCHITECTURE.md` §2):
  - 程式錯誤/不變式破壞 → `debug_assert`(熱路徑)
  - 公開 API 的非法輸入 → `raise Error(...)`,在邊界驗證一次
  - 環境/資源(無 GPU、檔案讀不到)→ 選擇 backend 的那層 fallback
  - 數值失敗(NaN、發散)→ 求解器在步末隔離該物體並記入 `diag.counters`
  - 容量溢出 → 丟最新一筆並記入 `diag.counters`(例:`LOG_DROPPED`)
- 引擎套件不 `print`;內層迴圈不 raise;`raises` 必須是真的會 raise。
- `match` 比對具名常數要寫 `case == NAME:`;裸 `case NAME:` 是綁定新變數、會比對任何值。同一算式改成 `match` 可能使最後幾位捨入不同
  (`physics/mass_props.mojo` 為此保留 `if/elif`),所以改寫後要看 gate golden。`Defaultable` 結構若沒有手寫 `__init__`,會由欄位逐一預設建構,
  欄位型別必須都是 `Defaultable`。Mojo 1.2.0 無法編譯存放函式型參數的結構體,用 trait + 空結構體(例:`procedural.tween.Interpolator`)。
- 被恢復的數值失敗要有測試:強制注入失敗,斷言模擬繼續且 counter 有變動。
- GPU:每個 process 只用一個 `DeviceContext`(共用 context 的 `*_run_ctx` driver),多個 context 會 hang。

## 測試

- 每個 `tests/test_*.mojo` 第一行必須是 `# tier: <unit|component|integration|system|stress>`,
  否則 runner 直接失敗。tier 由 `pixi run arch -- tiers` 依 import 機械計算
  (規則見 `docs/design/17.0b-test-tiers.md`);手動覆寫須同行寫理由:
  `# tier: unit  (override: ...)`。
- 檔名 `test_stress_*` → stress tier(目前尚無此類檔案)。
- 行為不變的重構必須讓 golden 各段完全不變;新增測試檔會新增段落,確認後用 `--update-golden` 記錄。
- 測試骨架:

```mojo
# tier: unit
from harness.runner import Suite

def main() raises:
    var s = Suite("my_module")
    s.check(cond, "label")
    s.almost(got, want, "label", tol=1e-6)
    s.finish()
```

## Benchmark

- `benchmarks/bench_*.mojo` 是一般程式,stdout 為 markdown 表格。
- 報告的文字在 `scripts/benchmark_report.md.in`;`@bench benchmarks/bench_foo.mojo` 行會被該程式輸出取代。
  新 bench 要在範本加一行 `@bench`,否則不會進報告。
- 不要手改 `BENCHMARK_REPORT.md`,一律 `pixi run benchmark` 重新產生。

## Hook

規則都在 `scripts/hooks.py`(一個檔、有 selftest);`.githooks/*` 與 `.claude/settings.json` 只是呼叫它。

- git hook(`pixi run install-hooks` 啟用,人工 `--no-verify` 可略過一次):
  - `commit-msg`:主旨須為 Conventional Commit(`type(scope): subject`)。
  - `pre-commit`:依暫存檔案選檢查:`.mojo` → `arch check` + tier 標頭;`.md` → `doclint` + `layers-sync`;
    `docs/ROADMAP.md` → 子系統表對索引;`pixi.toml` / `scripts/*.sh` → 浮點旗標政策;新增 `.mojo` → 孤島檢查。
    `docs/STRUCTURE.md` 不再由 commit 產生:每次 push 到 main 時 CI 重新產生並提交回 main;PR 分支不改此檔(避免合併衝突),本地只需 pull
  - `pre-push`:CI 的快速檢查(gate selftest、arch、doclint、layers-sync、roadmap-status、orphans、flag-policy、perf governance、bench-fresh),約 26 秒;
    `CHANGELOG.md` 落後 HEAD 超過 150 個 commit 時只警告。完整 `pixi run gate` 不在 hook 內。
- Claude Code hook(`.claude/settings.json`):
  - PreToolUse 擋:直接編輯產生檔(`BENCHMARK_REPORT.md`、`CHANGELOG.md`、`docs/STRUCTURE.md`、`bindings/` 下的產物、`tests/golden/`);
    Bash 指令中的 `git commit` / `git push` 帶 `--no-verify`;`git add -f` 加入 `build/`、`build64/`、`.pixi/`、`.campaign/`。
    只看實際執行的指令(heredoc 本文與引號內文字不算);這是護欄,不是安全邊界。
  - PostToolUse:編輯 `tests/test_*.mojo` 後檢查第一行 `# tier:`;編輯引擎 `.mojo` 後跑 `arch check`。
- 產生檔不手改:`docs/STRUCTURE.md`(`pixi run structure`)、`CHANGELOG.md`(`pixi run changelog`)、`BENCHMARK_REPORT.md`(`pixi run benchmark`)、
  `bindings/`(`pixi run bindings`)。CI 在 main 的 push 上重新產生並提交 `STRUCTURE.md`;分層表、ROADMAP 子系統表各有一步檢查。

## 文件

- `docs/ARCHITECTURE.md`:分層、錯誤政策、測試架構、archindex(`arch-check` 執行的契約)。
- `docs/STRUCTURE.md`:套件 → 模組 → 公開 struct / trait / 函式簽名的清單,由 `pixi run structure` 產生,不手改。
- `docs/CATEGORY.md`:seam 與 parity 測試的範疇論對應表;新增 seam 時補一列。
- `docs/ROADMAP.md`:原則、邊界、優先序,以及依子系統分組的現況與待辦。編號是永久 ID(程式碼與 commit 引用它),
  不改、不重用;新條目取下一個未用的編號放進對應子系統。完成一項工作時:把進度註(做了什麼、通過的 gate、
  量到的數字、commit)寫進該條目,更新子系統表與編號索引的狀態。
- `docs/ROADMAP_HISTORY.md`:2026-10-11 整理前的路線圖原文(依原 Phase 順序),已完成條目的完整紀錄在這裡。
- `docs/design/`:較大變更先寫設計筆記(檔名用 ROADMAP 編號,例:`17.0i-runtime.md`)。
- `docs/audits/`:架構稽核;ROADMAP 與 commit 以 `audit F11`、`E12` 等編號引用。

## Commit

Conventional Commits,scope 用套件名,附 ROADMAP 編號:

```
feat(physics): ropes and cables (17.41)
fix(collision): ...
docs: progress notes for 17.42
test: ...
```

歷史 commit 多為 `physics: ...` 形式(無 type);新 commit 使用上面的格式。
`build/`、`.pixi/`、`.campaign/` 不提交。
