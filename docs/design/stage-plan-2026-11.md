# 階段規劃(2026-11-01):未竟事項總表、GPU 層、wasm 平台、音訊 / 視訊

目的:把 ROADMAP 中所有未完成的子句整理到同一張表,並為三個新方向排出順序:
(1) GPU 項目由「延後」改為「開始規劃」;(2) 平台交付形態以 wasm 為跨平台通用目標;
(3) 音訊與視訊的方案選項(待與使用者討論後定案)。

依據:`docs/ROADMAP.md`(子系統表、剩餘順序、編號索引)、`docs/design/stage-triage-2026-10-27.md`
(含 2026-10-28 第二輪)。本文件不改程式碼。

## 0. 本輪實測的前提(2026-11-01)

| 事實 | 證據 |
|---|---|
| 本機有 NVIDIA GPU,`has_accelerator()` 為 True | `nvidia-smi -L` → `NVIDIA GeForce RTX 3060 Laptop GPU`;`pixi run mojo run` 探針印 `has_accelerator True`(Mojo 1.2.0) |
| ROADMAP 第 7 層的延後理由(「`has_accelerator` 在本環境為假」)不適用於本機 | 同上;理由寫於 2026-10-27,當時在無加速器的環境 |
| Mojo 1.2.0 仍無 wasm 後端 | `pixi run mojo build --target-triple wasm32-wasip1` → `No available targets are compatible with triple "wasm32-wasip1"`;`--print-supported-targets` 中 wasm 0 筆 |
| 本機 wasm 工具 | 有 `/usr/bin/llc`(LLVM 18)、`clang`、`node` 22;無 `wasm-ld`、`wasmtime` |

## 1. 未竟事項總表(非 GPU)

標籤沿用 stage-triage:deferred = 有條件才做(條件寫在「觸發條件」);env-blocked = 需要外部環境;
不排 = 使用者決定不安排。doable 列在 2026-10-27 已歸零。

| 條目 | 子句 | 標籤 | 觸發條件 / 阻擋 |
|---|---|---|---|
| 17.19 | 負載相依接觸剛度(已量測,負面結果,opt-in 旗標預設關) | deferred | 有場景需要時 |
| 17.19 | `max_mass_ratio` 預設開啟 | deferred | 改變既有場景行為,屬設計決定 |
| 17.19 | 非堆疊支撐圖分割近似(c) | deferred | 環形支撐場景誤差超出容差 |
| 17.19 | heightfield active-edge | deferred | 地形接觸瑕疵出現時 |
| 17.19 | 凸殼振盪(body 14) | deferred | 需先寫重現場景 |
| 17.19 | 關節力矩進事件 | deferred | 事件消費者需要 |
| 17.19 | 網格窄相逐三角 SAT 成本隔離 | deferred | midphase 已量測;單獨成本未隔離 |
| 17.58 | 黏彈、XPBD-FEM 變體、域壁 μ / skin | deferred | 速率相依固體、約束求解器比較需求 |
| 17.59 | PBF 雙向、柔性體 ↔ 流體 | 不排 | 使用者決定(`157297d`) |
| 17.60 | `LevelSetWater3` 開放邊界;2-D 粒子過衝 +9.1 % 歸因;3-D / 2-D 中間面差距 | 🔶 未歸因 | — |
| 17.61 | 火 / 燃燒 | deferred | 火場景 |
| 17.63 | 點數變化時強制 keyframe | deferred | 點快取的點數會變 |
| 17.63 | NanoVDB | env-blocked | 需參考 `.nvdb` 與規格 |
| 17.66 | (條目本文 ✅,索引標不排) | 不排 | 使用者決定(`157297d`) |
| 17.70 | 完整規則框架元件化;Runtime 擁有 Rules | deferred | 宿主需要 |
| 17.74 | 轎車元件拆分;Runtime 擁有 Vehicle;地形壓痕;懸浮 / RCS;快照軸陣列;多軸卡車;軌道車;零件脫落 | deferred | 各自的消費者 |
| 17.76 | `portability` CI 工作改為阻擋式 | 待辦 | 需連續兩次綠燈 |
| 17.76 | wasm64 / 含指標模組 | 見 §3 | 本輪改列為平台主線 |
| 17.78 | Godot / Unity 實機適配層 | env-blocked | 需裝有宿主引擎的機器 |
| 17.83 | (c) 每步配置次數閘門 | deferred | 宿主或 CI 需要 |
| 17.83 | 基準線檔、夜間牆鐘閘門 | env-blocked | 固定主機 |
| 17.86 | Rope 扭轉;frame-reading 接觸 / 空氣;Greenhill B / C;`rod_from_strand` parity | deferred | 繩索 / 毛髮消費者 |
| 13.9 | 批次多世界步進 | ⏸ | 平台決策(見 §3:wasm 方向可能解開) |
| 17.12 | 場景 / prefab 格式 | 🔶 | 2026-11-02 排程;第一片完成(2026-11-06),檔案格式由 ludens-shell 定義 |
| 17.43 | Undo / redo 交易層 | 🔶 | 2026-11-02 排程;第一片完成(2026-11-06):`EmbedWorld` 物體 |

## 2. GPU 層(第 7 層)規劃

盤點由唯讀子代理完成(未建置、未執行);下列「已核對」者由作者重讀原始碼確認。

### 2.1 盤點時的發現

1. **回歸(2026-11-01 在本機 RTX 3060 實跑確認)**:`pixi run build` 後 `pixi run mojo run -D ASSERT=all -I build tests/test_gpu_contact.mojo` →
   `Unhandled exception caught during execution: GpuContactSolver: max_mass_ratio is not supported (17.19; the device path is deferred to layer 7)`,rc = 1。成因:`382c1c2`(2026-10-25)把 `SolverConfig.max_mass_ratio` 預設改為
   `MASS_RATIO_DEFAULT = 10`(`physics/solver_config.mojo:40`、`:148`);`GpuContactSolver.step` 在 `cfg.max_mass_ratio > 0` 時
   raise(`physics/gpu_contact.mojo:351-352`);`tests/test_gpu_contact.mojo:33` 的 `_cfg()` 與 `benchmarks/bench_gpu_contact.mojo:53,70`
   用預設 `SolverConfig()` 且未歸零。因此在有 GPU 的主機上,`test_gpu_contact` 與 `bench_gpu_contact` 預期會 raise;ROADMAP 記的 22/22 早於該 commit。
   無加速器的 CI / 主機會跳過裝置半段,所以 gate 沒有抓到。
2. `test_gpu_artic` 的裝置半段與 `bench_gpu_batch` 的裝置列從未執行,唯一原因是先前環境沒有加速器。
3. 文件引用的 `gpu_contact.mojo:351-352` 只對應 `max_mass_ratio`;關節 / 驅動 / 軟體 / CCD / 重力區在 `:347`,
   接觸模型變體在 `:349`,輸送帶在 `:367`;「GPU anchor / substep」是 `:414-418` 的註解,不是 raise。
4. `test_vbd_cloth`、`bench_vbd_cloth` 呼叫 `has_accelerator()`,但不在 `scripts/gpu_compile_check.sh` 的檔案清單內。
5. 17.18 的「GPU 批次」沒有具體設計,且相依 ⏸ 的 13.9。

### 2.2 順序

每一步都在本機 RTX 3060(sm_86)上實跑裝置半段;GPU 是單車道資源,一次只跑一個 GPU 工作。

| 步 | 內容 | 條目 | 規模 | 驗收 |
|---|---|---|---|---|
| G0 | 修 §2.1-1:測試 / bench 的 config 明設 `max_mass_ratio = 0`(或讓 GPU 路徑支援,見 G2);`gpu_compile_check.sh` 補 vbd_cloth | 17.17 / 17.19 | S | `test_gpu_contact` 裝置半段全綠;`pixi run gpu-compile` 含 vbd_cloth |
| G1 | 17.17 收尾:`test_gpu_artic` 裝置半段、`bench_gpu_batch` 裝置列、全部 `test_gpu_*` 在本機跑一輪,結果記入進度註;golden 的裝置段落確認 | 17.17 | S | 各測試摘要行 + bench 數字入 ROADMAP |
| G2 | GPU 接觸路徑補齊 CPU 已有的模式:`max_mass_ratio`、逐子步錨點,再做 17.50 摩擦模型(橢圓錐、靜 / 滾 / 旋摩擦、逐材質柔度、block solver);每個模式加 parity 案例,未移植者維持明確拒絕 | 17.19 / 17.50 | M–L | `test_gpu_contact` 每模式 CPU / GPU 差在容差內 |
| G3 | 平行的獨立軌(彼此不相依,一次一軌):17.42 LBM(剖析:目前 55.6 MLUPS,約為頻寬上限的 1/20;動量交換歸約、LES、插值 bounce-back)· 17.79 GPU 緩衝收縮與上限、裝置位元組計入 `ResourceReport` · 17.80 GPU 時間軌進 trace · 17.53 GPU 射線對真實形狀(球 / 膠囊 / OBB / 凸殼,再到三角網格 BVH) | 17.42 / 17.79 / 17.80 / 17.53 | 各 M | 各自的 parity 測試 + bench 列 |
| G4 | 17.56 任意網格布料 GPU 求解與自碰撞(圖著色或 CSR gather,保持無 atomics 的決定論);6.1 GPU 軟體(沿用 gpu_cloth 的 Jacobi XPBD 結構) | 17.56 / 6.1 | L | CPU / GPU parity + bench |
| G5 | 「GPU 剛體 + CPU 軟體同幀」:先寫軟體 pass 與 GPU 接觸解的排序設計,再放寬 `:347` 的軟體拒絕 | 17.17 | M | 混合場景與全 CPU 路徑在容差內 |
| G6 | 17.62 GPU / 可微連續體(GPU MPM、PBF / SPH、FEM matrix-free CG、常駐裝置狀態、可微布料梯度);17.18 GPU 批次併入此條,待 13.9 決策 | 17.62 / 17.18 | L(大型工作) | 先寫設計筆記 |
| G7 | 17.76 AMD:本機可做編譯檢查(`pixi run gpu-compile -- gfx942`);實跑 AMD / Apple 需要對應硬體 | 17.76 | S(只做編譯檢查) | 編譯通過或拒絕清單 |

wasm 方向(§3)對 GPU 的影響:Mojo 只產生 PTX / AMDGPU,瀏覽器需要 WebGPU / WGSL,GPU kernel 不會自動進到 wasm。
wasm 版本先以 CPU 路徑交付;WebGPU 後端另列,不放進 G0–G7。

## 3. wasm 平台方向

完整設計與實測見 `docs/design/17.89-wasm-platform.md`;PoC 與實測紀錄保存在 `tools/wasm/poc/`。摘要:

- **整套 C-ABI 已能編成 wasm64 並執行**:外接 LLVM 23 的 `opt` / `llc` + `wasm-ld -mwasm64` + 約 150 行 C shim,
  不需等 Modular。模組 1.38 MB(gzip 0.32 MB),node 24 與 wasmtime 50 可跑。
- **位元一致**:wasm64 雜湊 = 原生無 FMA 建置(`4624da7477e83eff`,作者重跑確認);與帶 FMA 的原生建置不同。
- **速度**:1012 體單核,node 24 為原生的 1.5 倍時間,wasmtime 4.2 倍。
- **限制**:wasm32 不可行(要等 Mojo 以 32 位元指標 lower);Safari 未支援 memory64;node 22 不支援 table64。
- **待使用者決定**:浮點政策 —— wasm 自有 golden(建議先做)、參考建置改無 FMA,或引擎自帶 sin / cos 並關閉縮併。
- 分段 W0–W4:`pixi run wasm` 管線 → 引擎端前提(序列派發建置、剔除 GPU / MXCSR)→ CI wasm 閘門 → JS / TS 與 WASI 封裝 → 等上游(wasm32、WebGPU)。

## 4. 音訊與視訊方案(待討論)

邊界前提:ROADMAP「邊界與排除」把音訊與渲染列為**不在本 repo**(架構分離,不是不做),要做就以獨立層 / repo
建在 headless API 之上。下列方案依此切成「核心只出資料」與「宿主層 / 獨立 repo」兩邊。

來源分級:調查以子代理完成(全文在本輪 scratchpad `av_options.md`,未入庫)。授權與平台支援多數已讀官方頁;
B 段的論文出處(modal synthesis、FoleyAutomatic、氣泡聲)來自記憶,**未重新核對**,定案前要補引用。

| 面向 | 建議預設 | 替代方案 | 歸屬 |
|---|---|---|---|
| A. 音訊混音 / 輸出 | miniaudio(public domain / MIT-0,單檔 C,有 Emscripten 後端) | SDL3 audio(zlib;網頁需使用者手勢才能啟動);Web Audio + AudioWorklet(只限瀏覽器)。FMOD / Wwise 為商用授權,網頁支援需審核;OpenAL Soft 為 LGPL,網頁後端未確認;Steam Audio(Apache-2.0)不支援 wasm,可作原生空間音效的後續選項 | 宿主層 |
| B. 模擬驅動的音訊 | 核心只出資料:擴充碰撞事件(法向衝量、切向速度、材質 id、持續接觸旗標)、破碎事件、流體氣泡生成事件 | 另在 harness 側附參考 modal 合成器(Mojo,輸出可逐位重現,可上 golden);或只出事件、合成全交宿主 | 核心(資料)+ 可選參考實作 |
| C. 視訊(媒體) | repo 不帶編解碼器;核心匯出影格 / 回放串流,原生端把影格餵給使用者自備的 ffmpeg,瀏覽器端走 WebCodecs;格式以 AV1 / VP9(WebM)為無專利負擔的預設 | ffmpeg.wasm 僅用 LGPL 核心(避開 x264 等 GPL 建置;需要 COOP / COEP 標頭);播放用 dav1d + libvpx | 宿主層 |
| D. 視覺輸出(渲染) | 獨立 repo 的 three.js(或 Babylon)宿主,讀 SoA 姿態緩衝與既有 `diag/draw.mojo` DrawQueue | wgpu(經 `webgpu.h`;wgpu-native C API 仍在變動,wasm32 路線未確認);只做 debug-draw 檢視器 | 獨立 repo |

### 待使用者決定

1. 「視訊」指影片媒體(錄製 / 回放匯出)、畫面輸出(渲染),還是兩者都要?
2. 模擬音訊只出資料,還是另附參考 modal 合成器並上 golden 測試?
3. 音訊與畫面放在獨立的宿主 repo,是否可以接受?(現行邊界即如此)
4. 瀏覽器優先(Web Audio / WebCodecs / three.js),還是原生優先(miniaudio / ffmpeg / wgpu)?wasm 方向傾向前者。
5. 授權容忍度:只用無專利負擔的編解碼器,還是允許經平台或使用者自備 ffmpeg 使用 H.264?LGPL 可否?

### 使用者的回答(2026-11-01)

| 問題 | 回答 | 對規劃的影響 |
|---|---|---|
| 1. 「視訊」範圍 | 兩者都要 | 渲染(畫面輸出)與影片錄製 / 匯出都在範圍內 |
| 2. 只出資料或附合成器 | 要有聲音 | 除了核心的音訊事件,還要實際合成並播放(modal 合成器 + 混音輸出) |
| 3. 獨立 repo | 可以 | 音訊與畫面不進本 repo;本 repo 只擴充事件與匯出資料 |
| 4. 瀏覽器或原生 | 瀏覽器優先 | 第一個交付目標是瀏覽器(建在 17.89 的 wasm64 上) |
| 5. 授權 | 可以 | LGPL 可接受;H.264 可經平台或使用者自備 ffmpeg 使用 |

17.90 由 ⏸ 改為 ⬜。綁定目標:使用者提出 `wgpu-mojo`、`miniaudio-mojo`(見 §4.1)。

### 4.1 綁定目標:wgpu-mojo 與 miniaudio-mojo

已讀原始碼確認(唯讀):

- 兩者都以 `std.ffi.OwnedDLHandle` 在執行期載入動態庫,呼叫形式為 `handle.call["符號", 回傳型別](...)`
  (`wgpu-mojo/wgpu/_backend/wgpu_native/loader.mojo:9,178,212`;`miniaudio-mojo/src/miniaudio/_lib.mojo:9,29,39`)。
  wasm 沒有 dlopen,所以兩者都需要第二個後端:編譯期以靜態符號呼叫(LLVM 產生 `declare`),在 wasm 中成為匯入,由瀏覽器端實作。
- wgpu-mojo 的 API 與 `webgpu.h` 一對一(約 186 個 `wgpu*` 名稱,含 wgpu-native 的 `wgpu.h` 擴充,例如 `wgpuDevicePoll`);
  瀏覽器的 WebGPU 正是 `webgpu.h` 的對象,所以 **API 層可以沿用**,但 `wgpu.h` 擴充在瀏覽器不存在。
- wgpu-mojo 在 `RequestAdapter` / `RequestDevice` / `BufferMapAsync` 之後以 `wgpuInstanceProcessEvents` / `wgpuDevicePoll` 迴圈同步等待;
  瀏覽器主執行緒不能阻塞,需要 JSPI / Asyncify,或改成由 `requestAnimationFrame` 驅動的回呼式流程。視窗由 GLFW 改為 canvas。
- miniaudio 的瀏覽器後端(Web Audio / AudioWorklet)以 Emscripten 為前提;不用 Emscripten 時可用 `MA_NO_DEVICE_IO`,
  讓 miniaudio 只做解碼 / 混音 / 空間化,由 JS AudioWorklet 拉 PCM。

實測(Emscripten 能否連結 LLVM 23 產的 wasm64 物件、emdawnwebgpu 的 MEMORY64、miniaudio 的 wasm64 建置)進行中,結果補在此節。

### 4.2 兩個綁定要怎麼改(草案,工具鏈部分待 4.1 實測)

整體形態:第三個 repo(瀏覽器 app / 範本)把 ludens-engine、wgpu-mojo、miniaudio-mojo 三個 Mojo 套件編成**同一份 IR**,
走 17.89 的 retarget → wasm64 → 連結;JS 端只負責提供匯入(瀏覽器 WebGPU、AudioWorklet)與每幀呼叫匯出的 `frame()`。

兩個 repo 共同的改動:

| # | 改動 | 說明 |
|---|---|---|
| C1 | 連結模式改為編譯期選擇 | `-D LINK=dynamic`(現況,`OwnedDLHandle`)/ `-D LINK=static`:`handle.call["sym", R](args)` 改為 `external_call["sym", R](args)`,LLVM 產生 `declare`,在 wasm 中成為匯入。呼叫集中在 loader(wgpu-mojo `loader.mojo`、miniaudio-mojo `_lib.mojo` 與 `_ffi/`),方法簽名不變,本體可由腳本產生 |
| C2 | 原生也跑 static 模式 | 原生建置時直接連結 `libwgpu_native` / miniaudio 物件,既有測試在兩種模式各跑一次(parity),瀏覽器前先在原生 CI 驗證 static 後端 |
| C3 | 回呼的函式指標 | `abi("C")` 函式的位址在 wasm 中是函式表索引,JS 端以表索引呼叫;wgpu-mojo 的 `c_fn_ptr` 讀位址的做法要在 wasm64 驗證 |
| C4 | 平台旗標 | `comptime if is_web:` 剔除瀏覽器沒有的路徑(檔案系統、執行緒、平台擴充) |

wgpu-mojo:

| # | 改動 | 說明 |
|---|---|---|
| W1 | 只用標準 `webgpu.h` | `wgpu.h` 擴充(`wgpuDevicePoll` 等)在瀏覽器不存在,以 C4 隔開 |
| W2 | 非同步改為不阻塞 | `RequestAdapter` / `RequestDevice` / `BufferMapAsync` 後的輪詢迴圈在瀏覽器主執行緒不可行。兩條路:(a) JSPI / Asyncify 讓現有寫法照用;(b) 改成回呼設旗標、由 JS `requestAnimationFrame` 呼叫 `frame()` 推進的狀態機。建議 (b),不依賴 JSPI 的瀏覽器支援 |
| W3 | Surface 改為 canvas | `RenderCanvas` 加 web 變體:surface 來源改為 HTML canvas 選擇器(emdawnwebgpu 的 `WGPUEmscriptenSurfaceSourceCanvasHTMLSelector`);GLFW 視窗與輸入改由 JS / DOM 提供 |
| W4 | 渲染迴圈反轉 | 原生的 `while` 迴圈改為匯出 `frame(dt)`,由瀏覽器每幀呼叫 |
| W5 | 錄影 | 錄製 / 匯出在 JS 端:canvas → WebCodecs `VideoEncoder`(或 `MediaRecorder`);原生端把影格交給 ffmpeg |

WGSL 著色器不必改,瀏覽器原生支援。

miniaudio-mojo:

| # | 改動 | 說明 |
|---|---|---|
| M1 | C shim 靜態編入 | `miniaudio_shim.c` 與 miniaudio 編成 wasm 物件,與 Mojo IR 一起連結,不再產生 `.so` |
| M2 | 輸出裝置 | 建議 `MA_NO_DEVICE_IO`:`ma_engine` 以 noDevice 模式,Mojo 每幀呼叫讀取 PCM(既有的離線渲染路徑 `src/miniaudio/device.mojo:281`),寫入 SharedArrayBuffer 環形緩衝(`ring_buffer.mojo`),由約 50 行的 JS AudioWorklet 播放。替代:miniaudio 自帶的 Web Audio 後端(需 Emscripten 的 `-sAUDIO_WORKLET -sWASM_WORKERS`) |
| M3 | 檔案 | 瀏覽器沒有檔案系統:解碼改走記憶體(`ma_decoder_init_memory`),位元組由 JS `fetch` 取得 |
| M4 | 執行緒 | resource manager 改為無執行緒模式,工作由 `frame()` 內手動處理 |
| M5 | 物理聲音 | ludens 的接觸 / 破碎 / 氣泡事件 → modal 合成器(Mojo,寫成 miniaudio 的自訂 data source / node)→ `ma_engine` 混音與空間化 |

已開的上游 issue(2026-11-01):wgpu-mojo [#13 static link mode](https://github.com/Hundo1018/wgpu-mojo/issues/13)(C1–C3)、
[#14 browser target](https://github.com/Hundo1018/wgpu-mojo/issues/14)(W1–W5);miniaudio-mojo [#2 static link mode](https://github.com/Hundo1018/miniaudio-mojo/issues/2)(C1–C3、M1)、
[#3 browser target](https://github.com/Hundo1018/miniaudio-mojo/issues/3)(M2–M5)。

瀏覽器需要的部署條件:memory64(Chrome / Edge 133+、Firefox 134+;Safari 未支援);SharedArrayBuffer 需要 COOP / COEP 標頭。
