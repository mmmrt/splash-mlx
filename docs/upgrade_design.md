# SplashMLX 引擎增量升级设计（Splash 1.2.x → 1.7.1 / mlx-serve 26.10.1 → 26.11.3）

> **文档性质**：调研 + 设计。**本文档不修改任何代码**，所有代码位置均为"待改造点"的行号引用。
> **代码基线**：`main.swift` @ git `b7b4286`（3850 行 / 209 KB），本文所有 `main.swift:NNN` 均指该基线。
> **目标版本**：Splash **1.7.1**（2026-11-22）、mlx-serve **26.11.3**（2026-11-20）。
> `mlx-serve 26.11.4` 为 pre-release，本次**不采用**。
> **本机硬件**：MacBook Pro 14" **M5 Max**，18 核 CPU（6E+12P）/ **40 核 GPU** / **614 GB/s** 带宽 / **128 GB** 统一内存 / macOS 26.6.2。
> **在跑负载**：Qwen3.8-Flash-Next iQ-MLX-4.7bpw（≈75 GB 常驻）+ 16 GB prefix cache。
> **证据纪律**：每条事实都标注来源（官方 release notes / docs / 源码文件，或 `main.swift` 行号）。无法核实的一律标 **【待确认】**，不臆造参数名与版本号。

---

## 0. 结论速览（给工程师的 TL;DR）

| # | 结论 | 严重度 |
|---|---|---|
| 1 | **`main.swift:1057` 与 `main.swift:3046` 的默认模型 `incoai/*-Splash` 在 Splash 1.3.1 起彻底不可加载** —— 不改就是"开箱即崩" | **P0 阻断** |
| 2 | **`main.swift:1647` 停机只等 2.0 s 就 SIGKILL**，而 mlx-serve 26.11.3 `--shutdown-persist-secs` 默认 **45 s** 落盘窗口 —— 会截断 SSD 前缀缓存写入 | **P0 数据** |
| 3 | Splash `--max-cache-disk` 默认从 `0`（关）变为 **`auto`**（1.3.2 起）。`main.swift:1068` 的"留空=不传该参数（即关闭 SSD 缓存层）"注释与 `main.swift:2550` 的菜单文案 `Off (default)` **已经与事实相反** | **P0 语义** |
| 4 | Splash 新增 16 个 CLI flag、mlx-serve 新增 22 个，**两引擎都是零删除** —— 现有 `kGatedParams` / `kMlxGatedParams` 全部继续有效，纯增量 | 利好 |
| 5 | mlx-serve **26.11.1 退役了 24+6 个 `MLX_SERVE_*` 调优变量**，但 **SplashMLX 从未设置过其中任何一个**（只用自有 `MLX_SERVE_BIN` 与注入的 `MLX_SERVE_API_KEY`）→ **无需清理代码** | 无动作 |
| 6 | Splash `--reasoning-effort`（新）与 `--default-reasoning-effort`（现有 `main.swift:1222` 在用）**互斥，同传即 `parser.error` 起不来** | **P0 约束** |
| 7 | 本机 128 GB 可跑三个"越级"大模型：Flash-Next 4.7bpw（75 GB）、DeepSeek-V4.1-Flash Pruned192（92 GB）、GLM-5.3-Flash oQ2（110 GB），后两者靠 SSD 流式 | 选型 |

---

# 第一部分 · 版本差异清单

## 1.1 Splash 1.2.1 → 1.7.1

### 1.1.1 权威 flag 差集（源码级）

**取证方法**：直接 diff 两版 `server/serve_options.py` 中 `ServeOption("--…")` 的字面量集合（比文档表更权威 —— 文档表可能滞后）。

- 基线：`https://gh-proxy.com/https://raw.githubusercontent.com/incoai/splash/1.2.1/server/serve_options.py`（21 个 flag）
- 目标：`…/splash/1.7.1/server/serve_options.py`（41 个 flag）

**新增 20 项 / 删除 0 项。** 其中 4 项是 `EngineArgument` 的**内部拼写**（引擎私有 argv，**不是 `splash serve` 的 CLI flag，不可外露**）：`--ane`、`--ane-calibration`、`--idle-sleep`、`--max-image-patches`。

> 依据：`serve_options.py` 中 `ServeOption("--disable-ane", …, engine=EngineArgument("--ane", text=_spelled("off")))`；`--recalibrate-ane` → `EngineArgument("--ane-calibration")`；`--allow-idle-sleep` → `EngineArgument("--idle-sleep")`；`--max-image-pixels` → `EngineArgument("--max-image-patches")`。

**真正可外露的新 CLI flag = 16 个：**

| 新 flag | 引入版本 | 官方默认值 | 官方原文要点（来源） |
|---|---|---|---|
| `--disable-ane` | 1.3.0 | **Off**（即 ANE **默认开**） | "prefill on the GPU alone (default: a dense model's long prompts also use the Neural Engine when that is faster)" — `serve_options.py`；`needs="dense_ffn"` |
| `--recalibrate-ane` | 1.3.0 | Off | "calibrate the Neural Engine's share of long prompts again at this start instead of taking the one this Mac kept"；与 `--disable-ane` **互斥** |
| `--state-format` | 1.3.2 | **`fp32`** | choices `fp32`/`bf16`；"`bf16` halves each one's state"；`needs="recurrent_state"` |
| `--cached-states` | 1.7.0 | **`int8`** | choices `int8`/`exact`；"int8 codes take about a quarter of an fp32 state, and a restored state can differ at near ties; exact keeps `--state-format`'s, so a restore is exact" |
| `--max-cache-disk-writes` | 1.3.2 | **`0`（无限）** | "the most the SSD cache writes a day, e.g. 200G; the state a conversation resumes from and KV pages pass it" |
| `--expert-memory` | 1.4.0 | **`auto`** | `auto`/`SIZE`/`off`。1.6.0 起 auto 为**弹性**："streamed experts grow as memory allows and give memory back when requests or other apps need it" |
| `--ple-memory` | 1.4.0 | **`auto`** | `auto`/`SIZE`/`off`；"a cache of at most the rows of a 128K-token prompt, less where memory is short"；`needs="ple_table"` |
| `--sparse-kv-memory` | 1.4.0 | **`auto`** | "RAM cache of the KV blocks a block-sparse model … reads of requests whose KV is on the SSD, e.g. 1200M; never below its floor"；`needs="sparse_kv"` |
| `--verify-rows` | 1.4.0 | **`auto`** | choices `auto`/`all`；"**auto** … is faster but makes greedy and seeded outputs vary from run to run; **all** … those outputs repeat when a request runs alone with the same cached prefixes" |
| `--activations` | 1.6.1 | **`auto`** | choices `auto`/`bf16`；"On M5 and later Macs, whose GPUs multiply int8 at twice their bf16 rate"；27B MLX 4-bit prefill "about a quarter less time to the first token" |
| `--thinking-token-budget` | 1.3.2 | 无上限（`SPLASH_THINKING_TOKEN_BUDGET`） | "thinking tokens of a thinking request that sets no thinking_token_budget, after which its thinking closes" |
| `--thinking-end-text` | 1.3.2 | 模板自带闭合 | "must end with `</think>` and fit within 64 tokens"（1.3.2 notes）；`MAX_THINKING_END_TOKENS` |
| `--reasoning-effort` | 1.7.0 | 各请求自带（`SPLASH_REASONING_EFFORT`） | "effort of **every** Chat, Responses and Messages request, **whatever the request asks**"；**与 `--default-reasoning-effort` 互斥** |
| `--sampling-default` | 1.7.1 | 家族发布值 | `action="append"`，`NAME=VALUE`，如 `temperature=0.6` |
| `--chat-template-file` | 1.7.0 | 模型自带 | "a Jinja chat template to render every request with … read once at startup" |
| `--max-concurrent-requests` | 1.7.1 | **`4`**（范围 **1..8**） | `DEFAULT_CONCURRENT_REQUESTS = 4` / `MAX_CONCURRENT_REQUESTS = 8`（源码常量）；"a decode step holds a verify block of each (64 rows at four, 128 at eight)" |

**launcher 层另有（定义在 `install/launcher.py`，不在 `serve_options.py`）**：`--model` / `--model-dir` / `--mmproj` / `--revision` / `--draft-model` / `--language-only` / `--offline` / `--port`。其中 **`--model-dir` / `--mmproj` 是 1.5.0 新增**（"serve a GGUF file or MLX directory with `--model-dir`, without contacting the Hub"）。

### 1.1.2 默认值 / 语义变化（**最容易踩坑的部分**）

| 项 | 1.2.1 行为 | 1.7.1 行为 | 官方原文 | 对 SplashMLX 的影响 |
|---|---|---|---|---|
| **`--max-cache-disk`** | `default=0`，help 写 "(default: 0, disabled)" | **`default=None` → `auto`**："a quarter of its free space beyond a floor of 10G (5% of a volume under 200G), at most 32G" | 1.3.2 notes："The SSD prefix cache defaults to `auto`, with a quota up to 32 GiB … `--max-cache-disk 0` turns it off" | `main.swift:1068-1072` 注释块、`main.swift:2550` 菜单 `("", "Off (default)")` **全部过时**。留空现在是"自动开 ≤32 GiB"，不是关 |
| **`--persistent-cache` 前置条件** | help: "needs `--max-cache-disk`" | 1.3.2 起"now works without an explicit disk quota"，但 `check_serve_arguments` 仍在 `max_cache_disk == 0` 时 `parser.error` | 源码：`if args.persistent_cache and args.max_cache_disk == 0: parser.error(...)` | `main.swift:1261-1266` 的 `!maxCacheDisk.isEmpty` 守卫**逻辑上仍安全**（不传=auto≠0），但**过度保守**：现在留空也能开持久缓存 |
| `--max-context` 上限 | help: "up to 256K" | **`1M`**（`MAX_YARN_CONTEXT_TOKENS = 1010000`），超原生窗口自动 YaRN | 1.4.0："All three families support static YaRN beyond their native 262,144-token window" | `main.swift:2538` 菜单最大档只到 `256K`，缺 `512K`/`1M` |
| `--idle-release` | 默认 10m | **默认仍 10m**（未变） | `serve_options.py` help "(default: 10m)" | `main.swift:1095` 与菜单文案正确，无需改 |
| `--decode-share` | 默认 0.5 | **默认仍 0.5**（未变） | 同上 | 无需改 |
| Metal 自动预算 | working set − margin | 追加 **"at most nine tenths of the Mac's memory"**；1.7.1 明确"The automatic Metal budget leaves 10% of system memory unwired" | `docs/server.md` §Memory and context；1.7.1 notes | `main.swift:2532` 菜单写死 `auto (≈107 GB, M5 Max limit)` —— 128 GB × 0.9 = **115.2 GB 上界**，但实际取 working set − margin 的较小者，**该文案属估算，应改为不写死数字** |
| `--host` | `127.0.0.1` | 同，**新增 `unix:PATH`** 形式 | 1.7.0："Serve over a UNIX socket with `--host unix:PATH`" | 可选增强，非必需 |
| CLI 缩写 | argparse 默认允许 `--max-mem` | **1.5.0 起 `allow_abbrev=False`** | 1.5.0 Upgrade："abbreviations such as `--max-mem` are no longer accepted" | SplashMLX 一直传全称（`main.swift:1199-1270`），**无影响** |
| `/status` schema | schema 5 | **schema 8**（1.6.0 删了两个字段） | 1.6.0 Upgrade："**`/status` is schema 8.** Two fields were removed." | `main.swift:1469` 注释仍写 "schema 5"，**注释过时**；需复核解析代码是否读了被删字段 |

### 1.1.3 破坏性变更（**必须处置**）

**① Splash 包不再加载（1.3.1）** —— 官方原文逐字：

> "Splash packages (`incoai/Qwen3.8-27B-Splash`, `incoai/Qwen3.6-35B-A3B-Splash` and community packages) **no longer load** (#335). The MLX models below load the same weights as the two official packages:
> `splash serve --model mlx-community/Qwen3.8-27B-4bit`
> `splash serve --model mlx-community/Qwen3.6-35B-A3B-4bit`"

**命中代码**：
- `main.swift:1057` — `var model: String = "incoai/Qwen3.8-27B-Splash"`
- `main.swift:3046` — `if list.isEmpty { list = ["incoai/Qwen3.8-27B-Splash", "incoai/Qwen3.6-35B-A3B-Splash"] }`

**② 跨参数互斥（`check_serve_arguments`，源码原文）**：

```python
if args.announce_served_name and not args.served_model_name: parser.error(...)
if args.persistent_cache and args.max_cache_disk == 0:       parser.error(...)
if args.max_cache_disk_writes and args.max_cache_disk == 0:  parser.error(...)
if args.cache_dir is not None and not args.persistent_cache: parser.error(...)
if args.recalibrate_ane and args.disable_ane:                parser.error(...)
if args.reasoning_effort is not None and args.default_reasoning_effort is not None: parser.error(...)
```

> **最危险的一条是最后一条**：现有 `main.swift:1222` 传 `--default-reasoning-effort`。若新增 `--reasoning-effort` 外露且两者同时非空 → **服务直接起不来**。必须在 `splashServeArguments` 里做二选一守卫，不能只靠 `flagAvailable`。

**③ 持久缓存冷启动**：1.3.1（cached state 格式变）、1.4.0（27B/35B MLX 权重布局变）、1.4.1（GGUF 模型身份变）、1.5.0（GGUF + MLX MoE）、1.6.0（GGUF）、1.7.0（1.6.x 缓存）各冷启动一次。**权重不重新下载**。跨 6 个版本升级 → 用户会看到一次 `cached 0`，属预期，需在 UI 说明而非当 bug。

**④ 数值输出变化**：1.5.0（kernel 求和顺序）、1.6.1 + 1.7.1（`--activations auto` 在 M5 上走 INT8）、1.4.0（`--verify-rows auto`）。官方给的"精确性逃生门"：`--activations bf16` + `--disable-ane` + `--verify-rows all` + `--cached-states exact`。

### 1.1.4 性能证据（**本机 M5 Max 40 核相关**）

| 变更 | 官方实测 | 来源 |
|---|---|---|
| ANE FFN 拆分（1.3.0） | **M5 Max，MLX 4-bit，14,096 tokens：TTFT 14.09 s → 12.36 s = 1.14x**；UD-Q4_K_M GGUF：13.74 → 12.24 s = 1.12x | 1.3.0 notes 表格 |
| ANE 社区实测 | M4 Max **40 核 GPU / 128 GB**，Q8_0 GGUF，14,328 tokens：77.6–78.1 s → 40.7–45.9 s = **1.77x 中位** | 1.3.0 notes（PR #260） |
| ANE 代价 | 24 GB M6：auto 上下文 **61,433** vs `--disable-ane` **73,721** tokens | 1.3.0 notes |
| ANE 再加速（1.7.1） | 27B 在 16 核 M5 Pro 上 1K+ prompt **TTFT 再降 6–13%**；M6 冷 2K/8K 降 23% | 1.7.1 notes |
| `--activations auto`（1.6.1 / 1.7.1） | M5+：27B MLX 4-bit prefill **约少 1/4 TTFT**；INT8 KV 上的注意力 32K–64K **首 token 快 4–7%** | `serve_options.py` help + `docs/server.md` |
| 并发 8（1.7.1） | 64 GB M5 Pro，8 客户端 2K prompt，35B **吞吐 +13%**（对比 4 lane）。**默认仍 4** | 1.7.1 notes |
| 权重加载（1.7.1） | **M5 Max 缓存权重加载快至 1.54x** | 1.7.1 notes |
| 跨会话 TTFT（1.7.1） | 共享 system prompt + tools 的新会话 **TTFT 快 2.5–2.9x** | 1.7.1 notes |
| 缓存状态瘦身（1.7.0） | 27B 递归状态 **152.6 MiB → 46.9 MiB**（INT8 存储） | 1.7.0 notes |
| 内存受限服务（1.6.0） | M5 Max 36 GB，Flash-Next Q2_0 @ `--max-memory 18G`：最长流停顿 **300–406 s → 0.92 s** | 1.6.0 notes |

> **散热约束**：14 寸机身满载 90–95 °C 属正常，但持续高并发会触发降频。Splash 自 1.3.1 起 `/status` 与 `/metrics` 上报 thermal state（"making heat-related slowdowns visible"），`main.swift` 已有 `kKpiThermal`（`main.swift:675`）可复用。

---

## 1.2 mlx-serve 26.10.1 → 26.11.3

### 1.2.1 权威 flag 差集（源码级）

**取证方法**：diff 两版 `src/main.zig` 中 `"--flag"` 字面量集合。
> **为什么不看 `docs/cli.md`**：实测该表与源码不一致 —— 表中**缺** `--os-reserve-gib`、`--api-key-env`、`--ple-gpu`、`--max-mtp-ctx`、`--wired-margin-gib` 等；`docs/reference.md` 的 "CLI flags" 汇总行更是过时快照（不含 `--ane` / `--dist` / `--int8-qk`）。**以 `main.zig` 为准**。

- 基线 `src/main.zig` @ 26.10.1：84 个 flag
- 目标 `src/main.zig` @ 26.11.3：106 个 flag

**新增 22 项 / 删除 0 项。**

| 新 flag | 官方默认值 | 官方原文要点（来源：`docs/cli.md` @ 26.11.3 除注明外） |
|---|---|---|
| `--shutdown-persist-secs N` | **`45`** | "On SIGTERM, finish writing the SSD-tier slices not yet on disk for at most N seconds, then exit; 0 disables. **Under launchd, set `ExitTimeOut` above it**" |
| `--ane` | off | "Serve dense qwen3_5 and Qwen3 MLX packs on the Neural Engine **instead of** the GPU, contexts up to 64K … the first load on a Mac compiles its programs (**minutes**, then cached)" |
| `--ane-slots N` | **`1`**（1..4） | "Requests each Neural Engine model runs at once; slots share the weights, each adds its own KV and state" |
| `--int8-qk` | off | "**Lossy**, NAX GPUs (M5-class and later) only: the causal head-dim-256 prefill attention of dense Qwen 3.5/3.6/3.8 … Flat at 8k, **+3% at 32k, +7% at 64k, +14% at 128k** on an M5 Ultra (256 GB)" |
| `--w8a8` / `--no-w8a8` | **M5 级 GPU + ≥64 GiB RAM 上默认 on**，否则 off | 仅**媒体模型**（Image/video/music/3D：Krea、Qwen-Image、FLUX.2 klein、LTX、MiniMax-H3…），**与文本 LLM 无关** |
| `--lm-head-mxfp8` / `--no-lm-head-mxfp8` | **仅量化 Flash Next 包 + 集成 CUDA 上 on** | "other models, bf16 packs, discrete GPUs and **Macs opt in**"；有损，MXFP8 group 32 |
| `--mtp-min-depth N` | **`1`**（1..8） | "lifts the automatic cap if needed" |
| `--mtp-max-depth N` | **auto**（1..8） | "**`--mtp-depth` is the old spelling of this flag**"；源码保留 deprecated 别名并 `log.warn(depth_bounds.deprecated_flag_message)` |
| `--dist pipeline\|tensor` | off | Thunderbolt 5 RDMA 双机。`tensor`："gives each half of every MoE expert (Flash Next; DeepSeek-V4.1 its attention heads too)" |
| `--dist-model PATH` | `--model` | 双机共同服务的模型 |
| `--dist-coordinator IP:PORT` | none | worker 拨入的本机地址 |
| `--dist-device rdma_enX` | none | RDMA 端口（`ibv_devinfo`） |
| `--dist-split N` | by free memory | pipeline 模式下本机保留的层数 |
| `--no-plugins` | off | 外部插件（`~/.mlx-serve/plugins/`）本次运行不加载 |
| `--no-prefix-cache-ram` | off | "Disables module history even with disk configured"（`docs/reference.md`） |
| `--warmup-full` | off | "Compile a model's Metal kernels before it reports ready … **Strongly recommended when benchmarking**" |
| `--llama-mtp-drafts N` | **`2`** | GGUF 带 MTP 头时每轮草稿数；`0` = off |
| `--llama-ubatch N` | libllama 的 **512** | "1024-2048 prefill faster, mostly on MoE, for more scratch memory" |
| `--ablation-profiles DIR` / `--ablation-key-file PATH` | off | 定向消融，二者必须同时给；key 文件需 0600、≥32 字节 |

**源码存在但 `docs/cli.md` 未列的"隐藏旋钮"**（`main.zig` 实测，谨慎外露）：
`--wired-margin-gib`（整数 **2..32**）、`--mtp-typical`、`--mtp-tokenv3`、`--mtp-cascade`、`--mtp-head-kv-quant`、`--ssm-checkpoint-max`、`--ssm-checkpoint-stride`、`--config-overrides` / `--hf-overrides`、`--api-key-strict`、`--no-ds4-mtp`、`--ane-prefill` / `--ane-image` / `--ane-video` / `--ane-audio` / `--ane-split`、`--prefill-trace`、`--no-safety`。

### 1.2.2 默认值 / 语义变化

| 项 | 26.10.1 | 26.11.3 | 来源 |
|---|---|---|---|
| **`--prefill-decode-share`** | **`0`**（"Env `MLX_SERVE_PREFILL_DECODE_SHARE`"） | **`0.25`** | 两版 `docs/cli.md` 表格逐字对比 |
| **`--max-resident-mem` auto 语义** | "auto = **80% of the MLX wired limit**" | "auto = **the GPU working-set limit**" | 同上 + `main.zig` 注释："Special string `auto` (or default 0) → the GPU working-set limit" |
| **`--prefix-cache-mem` 默认** | "`2 GB`, or one session at the working context on **qwen4_exp** when larger" | "`2 GB`, or one session at the working context on **hybrid (Qwen3.5+, GLM-5.3-Flash, Nemotron-H, LFM2, Ling), sliding-ring (MiMo) and qwen4_exp** models when larger" | 同上 |
| **`--max-concurrent` 语义** | "Continuous-batch decode parallelism" | "**Sizes the request queue (N + 32 wait before a new one blocks) and caps how many decoders a long prefill admits a newcomer beside**; concurrent requests batch-decode either way"（默认仍 **1**） | 同上 |
| `--mtp` | "on when a head is loaded"（`--mtp` 为 no-op） | "on when a head is loaded (**Metal, CUDA**)；`--mtp` turns it on where it is off by default (**Vulkan**)" | 同上 |
| `--mtp-depth` → `--mtp-max-depth` | `--mtp-depth N` 默认 **`3`**，自适应区间 `[1, N]` | `--mtp-max-depth` 默认 **auto**；`--mtp-depth` 保留为 deprecated 别名（`log.warn`） | 两版 cli.md + `main.zig` |
| `--prefix-cache-entries` | 默认 32（`main.swift:821` 注释） | cli.md 写 **auto** | 【待确认】具体 auto 算法未在 docs 展开 |
| **`X-MLX-Priority: high`** | 无 | 本机（loopback）请求可携 **≤8192 未缓存 token** 插到长 prompt 的 chunk 边界之间；`--prefill-decode-share 0` 会连同该机制一起关掉 | `docs/api.md` §Request priority |
| **MLX 版本** | — | **0.32.5**（26.11.2："mlx-serve moves to MLX 0.32.5"） | 26.11.2 notes |

### 1.2.3 退役的 `MLX_SERVE_*` 环境变量（**任务重点**）

**官方原文（26.11.1 Highlights，逐字）**：

> "**Retired settings.** DiffusionGemma is no longer supported, and many old `MLX_SERVE_*` tuning variables are gone: **what they switched on is now the default**."

官方未给逐个清单，故用**双路 diff 取证**：

**A. `docs/reference.md` 26.10.1 → 26.11.3 移除 24 个：**

```
MLX_SERVE_ANE_BANK_MAX_BYTES   MLX_SERVE_ANE_DUAL          MLX_SERVE_ANE_GDN
MLX_SERVE_ANE_MODE             MLX_SERVE_ANE_SPLIT         MLX_SERVE_DFLASH
MLX_SERVE_DFLASH_DRAFT_HEAD_BITS  MLX_SERVE_DFLASH_QUANT_BITS
MLX_SERVE_DFLASH_SAMPLED_DRAFTS   MLX_SERVE_DFLASH_TRACE    MLX_SERVE_DIFFVAE_
MLX_SERVE_DSPARK_PROFILE       MLX_SERVE_KV_ATTN_VERIFY    MLX_SERVE_MF_DQ_GEMM
MLX_SERVE_MUSIC3_DEPTH_BITS    MLX_SERVE_MUSIC3_DEPTH_KV   MLX_SERVE_MUSIC3_LMHEAD_PRUNE
MLX_SERVE_PREFIX_SSD_FIRST     MLX_SERVE_QWEN_IMAGE_DTYPE  MLX_SERVE_QWEN_IMAGE_FUSED_ROPE
MLX_SERVE_QWEN_IMAGE_KV_CACHE  MLX_SERVE_QWEN_IMAGE_LOW_MEMORY
MLX_SERVE_RESTORE_MOVE         MLX_SERVE_SSD_CHUNK_SHARE
```

**B. `src/main.zig` 26.10.1 → 26.11.3 另移除 6 个（reference.md 未收录的）：**

```
MLX_SERVE_DECODE_ATTN_QUANT_NVFP4_FROM   MLX_SERVE_MTP_ADAPTIVE
MLX_SERVE_MTP_TOKENV3                    MLX_SERVE_MTP_TYPICAL
MLX_SERVE_PREFILL_DECODE_SHARE           MLX_SERVE_ANE_SPLIT（与 A 重叠）
```

> `MLX_SERVE_PREFILL_DECODE_SHARE` 的功能**转为 CLI flag `--prefill-decode-share` 且默认值 0 → 0.25**，这是"功能转为默认"的最典型一例。
> `MLX_SERVE_MTP_ADAPTIVE` / `MTP_TYPICAL` / `MTP_TOKENV3` 的能力转由 `--mtp-min-depth` / `--mtp-max-depth` 自适应控制器与源码内 `--mtp-typical` / `--mtp-tokenv3` 承接。

**仍存活**：`MLX_SERVE_ANE_CACHE_CAP_GB`、`MLX_SERVE_ANE_FORCE`、`MLX_SERVE_SSD_WRITE_THROUGH`、`MLX_SERVE_GGUF_TEST_MODEL`、`MLX_SERVE_URL`、`MLX_SERVE_API_KEY`。
**新增**：`MLX_SERVE_CODEX_MODEL_INSTRUCTIONS`、`MLX_SERVE_DIAG`、`MLX_SERVE_H3_RESIDENT`。

**对 SplashMLX 的影响 → 零。** 取证：

- `main.swift:87` / `main.swift:112` / `main.swift:1615`：只读自有的 `MLX_SERVE_BIN` / `SPLASH_BIN`（定位二进制路径，**不是引擎调优变量**）
- `main.swift:612` / `main.swift:1628-1630`：只注入 `MLX_SERVE_API_KEY`（**仍存活**）
- 全文件搜索无任何上表退役变量

> **结论：无需清理代码。** 但应在设计文档留档，防止后续有人"照旧博客"手动往 `Service.start` 里塞 `MLX_SERVE_PREFIX_SSD_FIRST=1` 之类。

### 1.2.4 其它相关变化

- **26.10.3**：GLM-5.3-Flash / MiMo-V2.6-Flash **专家 SSD 流式** → "run on a **128 GB Mac**: GLM-5.3-Flash keeps its **full million-token context**, writes about **35 tokens a second**, and starts answering a short question in about **2.5 seconds instead of 7**"。
- **26.10.3**：`--ane` 首发（"Chat on the Neural Engine"，text only，首次编译数分钟）。**注意：这与 Splash 的 ANE prefill *拆分* 是两种不同机制** —— mlx-serve 是把整模型搬到 ANE（GPU 空出来），Splash 是 GPU/ANE **分摊 FFN**。
- **26.11.2**：`--dist tensor`，两台 M3 Ultra 上 DSpark **88 vs 56 tok/s（+57%）**；无 DSpark +31%。
- **26.11.2**：`--mlx-gguf` 支持 DeepSeek-V4.1 GGUF 走 MLX 引擎，M5 Ultra 上 prefill **≈3,300 tok/s（2.5x）**。
- **26.11.3**：`--int8-qk` 相关 —— "Decode attention over a quantized KV cache runs on the GPU's matrix units"；外部 quant 插件可服务内置模型（EXL3 移出为独立插件）。
- **26.11.3**：内存准入改为"count the RAM macOS can free instead of refusing early" → `--skip-mem-preflight` 的必要性下降。

---

# 第二部分 · 参数处置方案（核心）

## 2.0 处置原则与判定口径

| 原则 | 判定 | 动作 |
|---|---|---|
| **A · 隐藏** | 不涉日常调整 **且** 官方明确"默认即最优" | 从 Settings 菜单移除外露；**`Config` 字段与 `serveArguments` 拼装能力保留**（手改 `config.json` 仍生效），tag 与门控表条目保留 |
| **B · 改默认** | 基于本机（M5 Max 40 核 / 614 GB/s / 128 GB / 14" 散热）最佳性能应当调整 | 把 `Config` / `MLXConfig` 的字段默认值改为该值，菜单文案同步标注"本机推荐" |
| **C · 保持外露** | 日常会调、或涉及安全/隐私/体感 | 不动 |
| **D · 新增外露** | 新引擎能力且本机有明确收益 | 新增 tag + 门控表条目 + 菜单项 + 拼装分支（四处同步） |

> **官方"默认即最优"的直接依据**（mlx-serve `docs/performance.md` §Tuning，逐字）：
> "**The defaults are already the fast path. If you have plenty of RAM, the fastest configuration is the one you get out of the box.** Every speed-relevant knob is a memory-for-speed trade in one direction or the other."
> 本机 128 GB 属"plenty of RAM"，**这条是原则 A 的总纲**。

> **"隐藏"的实现纪律（重要）**：隐藏 ≠ 删字段。`main.swift:803-1050` / `1052-1271` 的手写 `init(from:)` 逐字段缺键回退机制必须保留，否则老配置会被整体丢弃。隐藏只动 `splashSettingsItems()`（`main.swift:2528`）/ `mlxSettingsItems()`（`main.swift:2671`）里的 `gatedSubmenu` 条目。

## 2.1 Splash 参数处置表

### 2.1.1 现有已外露参数（21 项，`kGatedParams` @ `main.swift:544-572`）

| 参数名 | 引擎 | 当前状态 | 官方默认值 | 建议处置 | 本机建议默认值 | 依据 |
|---|---|---|---|---|---|---|
| `--max-memory` | Splash | 已外露 `main.swift:2532` | Auto（working set − margin，且 ≤90% RAM） | **C 保持外露 + 改文案** | `auto`（不变） | `docs/server.md` §Memory and context。菜单写死的 "≈107 GB" 无官方依据，改为 `auto (engine-planned)` |
| `--max-context` | Splash | 已外露 `main.swift:2538` | Auto（原生 256K） | **D 扩档** | `auto`（不变），档位补 `512K` / `1M` | 1.4.0："All three families support static YaRN … Add `--max-context 1M`"。**注意**：YaRN"changes outputs even on short prompts when enabled"，默认不宜设 1M |
| `--port` | Splash | 已外露 `main.swift:2618` | `SPLASH_PORT` 或 `8000` | **C 保持** | `8000` | `launcher.py` `_add_port` |
| `--max-request-size` | Splash | 已外露 `main.swift:2627` | `128M` | **A 隐藏** | 不传（=128M） | 日常无调整需求；128M 请求体对本地聊天/Agent 绰绰有余。`serve_options.py` `DEFAULT_MAX_REQUEST_BYTES` |
| `--max-image-pixels` | Splash | 已外露 `main.swift:2595` | `4194304` | **A 隐藏** | 不传（=4194304） | 官方："An image's vision scratch grows with its patches … to about 600 MiB at the default"。128 GB 机器无需压图省内存 |
| `--max-cache-disk` | Splash | 已外露 `main.swift:2548` | **`auto`**（1.3.2 起） | **B 改默认 + 必须改文案** | **`auto`**（显式传或留空均可，但**文案必须从 "Off (default)" 改为 "Auto (default, ≤32 GiB)"**，并新增 `0` = Off 档） | 1.3.2 notes；`main.swift:1068-1073` 注释与字段同步更正。**这是当前最严重的文案错误** |
| `--allowed-host` | Splash | 已外露 `main.swift:2623` | 无额外名 | **C 保持** | 空 | 安全相关，局域网访问时需要 |
| `--no-webui` | Splash | 已外露 `main.swift:2626` | Off | **C 保持** | `false` | 用户会用浏览器聊天页 |
| `--default-reasoning-effort` | Splash | 已外露 `main.swift:2575` | 模板默认 | **C 保持**（与新 `--reasoning-effort` **互斥**） | 空 | `main.swift:1222`。官方注释："最影响手感快慢的一项" |
| `--kv-format` | Splash | 已外露 `main.swift:2543` | **`int8`** | **A 隐藏** | 不传（=int8） | `docs/performance.md`：Splash 全精度基准用 bf16，但那是**评测口径**不是性能口径。int8 省一半 KV，128 GB 上配合 `--activations auto` 反而更快（"attention over the INT8 KV cache … 4-7% sooner first tokens at 32K-64K"）。bf16 仅作评测逃生门，手改配置即可 |
| `--draft-model` | Splash | 已外露 `main.swift:2582` | 家族 DFlash2 | **A 隐藏** | 空（自动） | `install/families.py` FAMILIES 已为五族各绑定官方草稿仓库；手动覆盖属排障场景 |
| `--revision` | Splash | 已外露 `main.swift:2586` | 仓库默认分支 | **A 隐藏** | 空 | 日常不 pin commit；排障时手改配置 |
| `--language-only` | Splash | 已外露 `main.swift:2590` | Off | **C 保持** | `false` | 128 GB 不缺视觉塔那点内存，但"纯文本 Agent 省内存换上下文"是真实日常场景（`docs/performance.md`：24 GB M6 上 27B 上下文 53,241 → 81,913） |
| `--host` | Splash | 已外露 `main.swift:2635` | `127.0.0.1` | **C 保持** | `127.0.0.1` | 安全边界。可选补 `unix:PATH` 说明（1.7.0） |
| `--idle-release` | Splash | 已外露 `main.swift:2566` | **`10m`** | **B 改默认** | **`off`** | **本机推理**：菜单栏工具的核心价值是"随时秒回"。75 GB 级模型重新加载即使 1.7.1 快 1.54x 仍是数十秒级；128 GB 内存足以长期驻留。官方 `off` 语义："keeps both, though `POST /v1/memory/release` still frees the weights" —— 保留了手动释放出口 |
| `--decode-share` | Splash | 已外露 `main.swift:2602` | `0.5` | **A 隐藏** | 不传（=0.5） | 官方默认值即平衡点；仅在多客户端长 prompt 场景才需调，属高级排障 |
| `--request-timeout` | Splash | 已外露 `main.swift:2646` | None | **A 隐藏** | 不传（=无超时） | `docs/performance.md`：无超时时"requests wait with no time limit"，配合流式 keepalive（每 2 s）不会挂死客户端。设超时反而可能误杀长 prefill |
| `--queue-size` | Splash | 已外露 `main.swift:2651` | `32` | **A 隐藏** | 不传（=32） | 32 对单人菜单栏 usage 远超需求；真正的并发闸门是新的 `--max-concurrent-requests` |
| `--allowed-origin` | Splash | 已外露 `main.swift:2641` | 无 | **A 隐藏** | 不传 | 仅当把 API 嵌进 webview 才需要；本机纯 CLI/Agent 用法不涉及。安全项，隐藏后默认更严 |
| `--persistent-cache` | Splash | 已外露 `main.swift:2555` | Off | **B 改默认 + 放宽守卫** | **`true`** | **本机推理**：128 GB + 大模型 + 频繁重启切换模型，跨重启保留前缀缓存收益极大（1.7.1 跨会话 TTFT 快 2.5–2.9x）。**守卫需改**：1.3.2 起不再要求显式配额，`main.swift:1261` 的 `!maxCacheDisk.isEmpty` 应改为 `maxCacheDisk != "0"` |
| `--cache-dir` | Splash | 已外露 `main.swift:2560` | `~/Library/Caches/Splash/prefix-cache` | **A 隐藏** | 空（用默认） | 默认路径合理；仅外置盘用户需要，手改配置 |
| `--offline` | Splash | 已外露 `main.swift:2610` | Off | **C 保持** | `false` | 离线/隐私场景的日常开关 |
| `--allow-idle-sleep` | Splash | 已外露 `main.swift:2657` | Off（推理时不休眠） | **C 保持** | `false` | 电源策略，用户日常会切 |

### 2.1.2 Splash 新增参数处置（16 项）

| 参数名 | 引擎 | 当前状态 | 官方默认值 | 建议处置 | 本机建议默认值 | 依据 |
|---|---|---|---|---|---|---|
| `--disable-ane` | Splash | 未外露 | **Off**（ANE 开） | **D 新增外露**（反向开关，与现有 `--no-pld` 同风格） | **`false`**（=ANE 保持开） | **1.3.0 官方实测本机同型号：M5 Max MLX 4-bit 14,096 tokens TTFT 1.14x**；M4 Max 40 核 128 GB Q8_0 达 1.77x。1.7.1 再降 6–13%。**默认必须开**。外露理由是它是"精确性逃生门"（W8A8 数值不同于 GPU-only） |
| `--recalibrate-ane` | Splash | 未外露 | Off | **A 隐藏**（建议做成一次性动作按钮而非持久开关） | 不传 | 官方："as after a start beside another client of the Neural Engine"。**与 `--disable-ane` 互斥**（`check_serve_arguments`）。1.7.1 已修"false no-gain result"并"rechecked busy calibrations"，日常无需手动 |
| `--activations` | Splash | 未外露 | **`auto`** | **A 隐藏** | 不传（=auto） | **M5 Max 直接受益**："M5 and later Macs, whose GPUs multiply int8 at twice their bf16 rate"，27B MLX 4-bit prefill 少约 1/4 TTFT。默认已最优；`bf16` 仅评测用（且需配 fresh `--cache-dir`），属手改配置场景 |
| `--verify-rows` | Splash | 未外露 | **`auto`** | **A 隐藏** | 不传（=auto） | 1.4.0：MoE 自适应 verify 带来 **13–38% 解码吞吐**（Flash-Next Q2_0 @ M5 Max）。代价是 greedy 输出跨 run 不稳定；`all` 是评测逃生门，手改配置 |
| `--expert-memory` | Splash | 未外露 | **`auto`** | **A 隐藏** | 不传（=auto） | 1.6.0："**Elastic expert store** … grow as memory allows and give memory back when requests or other apps need it"。128 GB 上 auto 会自适应吃满可用内存，手动固定值反而丧失弹性 |
| `--ple-memory` | Splash | 未外露 | **`auto`** | **A 隐藏** | 不传（=auto） | `docs/server.md` §PLE table streaming："caches from 256 MiB, which no run filled, to 2 GiB **hit as often**, while each GiB more of the expert store makes a 24 GB Mac decode 11-23% faster, so the experts take the rest"。**官方明确说加大 PLE 缓存无收益** |
| `--sparse-kv-memory` | Splash | 未外露 | **`auto`**（=floor） | **A 隐藏** | 不传（=auto） | 仅 Flash-Next 生效（`needs="sparse_kv"`）；auto 保底不低于 floor。属精细排障旋钮 |
| `--state-format` | Splash | 未外露 | **`fp32`** | **A 隐藏** | 不传（=fp32） | bf16  halves state（27B 153→81 MiB），但 1.7.0 的 `--cached-states int8` 已把**缓存**状态压到 46.9 MiB，收益重叠。128 GB 不缺这点内存，保 fp32 计算精度 |
| `--cached-states` | Splash | 未外露 | **`int8`** | **A 隐藏** | 不传（=int8） | 1.7.0：27B 缓存状态 152.6 → **46.9 MiB**，同预算能装更多会话。默认已最优；`exact` 是评测逃生门 |
| `--max-cache-disk-writes` | Splash | 未外露 | **`0`**（无限） | **A 隐藏** | 不传（=无限） | 官方样例是给 256 GB **小盘** Mac 设 `25G`/天护盘。本机盘容量【待确认】；若为 1 TB+ 则无需限写。**建议隐藏但在文档留档**：`docs/performance.md` 实测 M6 上 16 GiB 缓存 30 分钟写 26 GB（≈50 GB/小时），重度用户可自行设 `200G` |
| `--max-concurrent-requests` | Splash | 未外露 | **`4`**（1..8） | **D 新增外露** | **`4`**（保持官方默认，但给出 1/2/4/8 档） | 1.7.1：8 lane 在 64 GB M5 Pro 上 35B 吞吐 +13%，**但官方默认仍 4**。**本机推理：14 寸散热 + 75 GB 常驻模型，8 lane 会显著挤占上下文**（官方："Higher concurrency can reduce available context on Macs with limited memory"；且 8 lane 的 verify block 是 128 行 vs 4 lane 64 行）。**默认保持 4**，外露让用户在多客户端时自行提到 8 |
| `--reasoning-effort` | Splash | 未外露 | 各请求自带 | **A 隐藏（强烈建议不外露）** | 不传 | **与现有 `--default-reasoning-effort` 互斥，同传即 `parser.error` 服务起不来**。语义是"强制覆盖每个请求"，会剥夺客户端控制权，不适合菜单栏工具。若将来要加，必须做二选一守卫 |
| `--thinking-token-budget` | Splash | 未外露 | 无上限 | **D 新增外露**（与 mlx 侧 `--reasoning-budget` 对齐） | 空（不限） | 1.3.2 引入。两引擎菜单对称性：mlx 侧已有 `kTagMlxReasoningBudget`（`main.swift:2799`）。给 4096/8192/16384 档 |
| `--thinking-end-text` | Splash | 未外露 | 模板闭合 | **A 隐藏** | 不传 | 需手工构造以 `</think>` 结尾且 ≤64 token 的文本，属高级调参；模板默认已够用 |
| `--sampling-default` | Splash | 未外露 | 家族发布值（Qwen: temp 1.0 / top_p 0.95 / top_k 20） | **A 隐藏** | 不传 | `install/families.py` `QWEN_SAMPLING` 已给出官方推荐；覆盖它属评测场景 |
| `--chat-template-file` | Splash | 未外露 | 模型自带 | **A 隐藏** | 不传 | 换模板会破坏工具调用格式，风险高收益低 |
| `--model-dir`（launcher，1.5.0） | Splash | 未外露（仅有 `modelDirSplash` 字段 `main.swift:1075` 用于**发现**模型，未传 flag） | None | **D 新增外露**（P2，可选） | 空 | 1.5.0："serve a GGUF file or MLX directory with `--model-dir`, without contacting the Hub"。与 mlx 侧 `modelDir` 对称。**注意与现有"模型目录发现"语义不同**，需区分 |
| `--mmproj`（launcher，1.5.0） | Splash | 未外露 | None | **A 隐藏** | 不传 | 依赖 `--model-dir`，仅本地 GGUF + 独立视觉投影器场景 |

## 2.2 mlx-serve 参数处置表

### 2.2.1 现有已外露参数（31 项，`kMlxGatedParams` @ `main.swift:616-653`）

| 参数名 | 引擎 | 当前状态 | 官方默认值 | 建议处置 | 本机建议默认值 | 依据 |
|---|---|---|---|---|---|---|
| `--port` | mlx | 已外露 `main.swift:2810` | `11234` | **C 保持** | `11234` | cli.md |
| `--host` | mlx | 已外露 `main.swift:2816` | **`0.0.0.0`** | **C 保持（必须继续覆盖）** | **`127.0.0.1`** | cli.md："Defaults are `--host 0.0.0.0 --port 11234`"。`main.swift:809-813` 的覆盖理由完全成立，**不可改** |
| `--ctx-size` | mlx | 已外露 `main.swift:2675` | auto | **C 保持** | 空（auto） | cli.md："auto = computed from GPU memory" |
| `--kv-quant` | mlx | 已外露 `main.swift:2681` | **off** | **C 保持外露，默认不变** | **`off`** | `docs/performance.md`：8-bit "≈−10% decode at 2–4K … −18% at 42K"。**128 GB 上 off 就是最快**。保留外露给"超长上下文换内存"场景 |
| `--prefix-cache-disk` | mlx | 已外露 `main.swift:2734` | off | **B 改默认** | **`32GB`** | cli.md："SSD tier: prefixes survive restarts (**11K-token restart TTFT 5.9 s → 0.7 s**)"。**本机推理**：75 GB 模型 + 频繁重启，8.4x 的 TTFT 改善是本次升级最大的单点收益之一。当前在跑配置已用 16 GB，建议提到 32 GB |
| `--prefix-cache-mem` | mlx | 已外露 `main.swift:2729` | **`2 GB`**，hybrid/sliding-ring/qwen4_exp 上取"一个会话工作上下文"若更大 | **B 改默认** | **`16GB`** | 用户当前实跑即 16 GB。**注意 26.11.3 语义扩展**：Flash-Next(`qwen4_exp`) 本来就会自动抬到会话级，显式 16 GB 是"抬得更高"。菜单文案 "Engine default (2GB)" 需补注 hybrid 例外 |
| `--prefix-cache-entries` | mlx | 已外露 `main.swift:2739` | auto（26.10.1 文档写 32） | **A 隐藏** | 不传 | 与 `-mem` 是同一缓存的两个维度，字节预算已是主控；条数上限属排障。【待确认】auto 的具体算法 |
| `--max-resident-models` | mlx | 已外露 `main.swift:2691` | **`3`** | **B 改默认** | **`1`** | **本机推理**：单个 Flash-Next 就 75 GB，128 GB 装不下第二个大模型。设 1 可避免 LRU 反复驱逐/重载（每次重载数十秒）。小模型用户可手改回 3 |
| `--max-resident-mem` | mlx | 已外露 `main.swift:2686` | auto = **GPU working-set limit**（26.10.1 时为 wired limit 的 80%） | **A 隐藏 + 必须改文案** | 不传（=auto） | **语义已变**，`main.swift:824` 注释（"留空用引擎默认（wired limit 的 80%）"）与 `main.swift:2688` 菜单 "Engine default (80% of wired limit)" **均已过时**。新 auto 更宽松，正是 128 GB 大模型所需，不该手动压小 |
| `--idle-evict-secs` | mlx | 已外露 `main.swift:2744` | off | **A 隐藏** | 不传（=off） | 默认已"永不驱逐"，与本机常驻策略一致。与 `--max-resident-models 1` 配合已足够 |
| `--drafter` | mlx | 已外露 `main.swift:2766` | none（包内 `drafter/` 自动） | **A 隐藏** | 空 | `docs/performance.md`："a model folder can ship its own `drafter/` … the server loads it with the model"。手动指定属排障 |
| `--no-vision` | mlx | 已外露 `main.swift:2770` | off | **C 保持** | `false` | 与 Splash `--language-only` 对称；省内存换上下文的日常场景 |
| `--metrics` | mlx | **强制打开**（`main.swift:1014`），不在菜单 | off | **保持强制打开** | 强制传 | `main.swift:1011-1013` 的理由成立：菜单栏 KPI 全靠它。**不动** |
| `--mtp` / `--no-mtp` | mlx | 已外露 `main.swift:2754`（三态） | **头加载即 on**（Metal/CUDA） | **C 保持外露，简化文案** | **`"on"`**（不变） | `main.swift:840-843` 注释已指出 26.10.1 起 `--mtp` 是 no-op。**26.11.3 进一步区分 Metal/CUDA vs Vulkan** —— Mac 上 auto≡on。菜单文案 "required for MoE models" **已过时**，应改为 "On (engine default on Mac)" |
| `--no-pld` | mlx | 已外露 `main.swift:2761` | on | **C 保持** | `enablePLD = true` | `docs/performance.md`："Large wins on agent loops, code editing and RAG … **Leave on**" |
| `--ple-gpu` | mlx | 已外露 `main.swift:2699` | off | **B 改默认为 false（维持）+ 改文案** | **`false`** | `main.swift:856-859` 实测该表 29.80 GiB 且**计入 resident**。75 GB 权重 + 30 GB 表 = 105 GB，叠加 KV 后逼近上限。**官方 Flash-Next 模型卡明确**："The table **never becomes resident** … decode speed unchanged"。**结论：本机应保持 off**，菜单文案的 "+few% speed" 与模型卡矛盾，应改为 "(+~30 GB resident, negligible speed gain on this pack)" |
| `--mtp-greedy-tail` | mlx | 已外露 `main.swift:2777` | off | **A 隐藏** | `false` | cli.md："pairs with `--mtp-typical`"，而 `--mtp-typical` 是源码隐藏旋钮未外露 → 单独开收益不完整。有损，默认 off 正确 |
| `--mtp-depth` | mlx | 已外露 `main.swift:2782` | 26.10.1: `3`；26.11.3: **deprecated 别名 → `--mtp-max-depth` auto** | **D 改名 + A 隐藏** | 不传（=自适应） | `main.zig`：`if (deprecated) log.warn(depth_bounds.deprecated_flag_message)`。**应迁到 `--mtp-max-depth`**；自适应控制器在 M5 NAX 上最多 8，优于任何固定值 → 隐藏 |
| `--max-mtp-ctx` | mlx | 已外露 `main.swift:2787` | 无上限 | **A 隐藏** | 空 | 长上下文关 MTP 的成本权衡由引擎自适应控制器处理；手动设限属排障 |
| `--no-decode-attn-quant` | mlx | 已外露 `main.swift:2794` | **on**（量化默认开） | **A 隐藏** | `false`（=保持量化开） | `docs/performance.md`："−23% per-token time on models that ship bf16 attention … **quantized checkpoints are unaffected**"。本机跑的是量化包 → **此项对在跑模型无影响**，纯逃生门 |
| `--engine` | mlx | 已外露 `main.swift:2840` | auto | **C 保持** | 空（auto） | GGUF 路由，用户会切 ds4/llama |
| `--mlx-gguf` | mlx | 已外露 `main.swift:2846` | off | **C 保持** | `false` | 26.11.2 起支持 DeepSeek-V4.1 GGUF 走 MLX（**2.5x prefill**），是有真实收益的实验开关，值得保留外露 |
| `--lan-share` | mlx | 已外露 `main.swift:2825` | off | **C 保持** | 空 | 隐私相关，用户主动决定 |
| `--lan-discover` | mlx | 已外露 `main.swift:2830` | off | **C 保持** | `false` | 同上 |
| `--reasoning-budget` | mlx | 已外露 `main.swift:2799` | `-1`（无限） | **C 保持** | 空 | 日常会调思考量 |
| `--no-prevent-sleep` | mlx | 已外露 `main.swift:2717` | off | **C 保持** | `false` | 电源策略，与 Splash 侧对称 |
| `--skip-mem-preflight` | mlx | 已外露 `main.swift:2711` | off | **A 隐藏** | `false` | 26.11.3："Requests and loads **count the RAM macOS can free instead of refusing early**" → 误拒概率大降，这个危险逃生门（"a real over-commit can crash"）不该继续摆在菜单里。手改配置仍可用 |
| `--os-reserve-gib` | mlx | 已外露 `main.swift:2705` | **RAM/8，限 2–8 GB** → 本机 **8 GB** | **A 隐藏** | 不传（=8 GB） | `docs/reference.md` §OS memory reserve："an eighth of RAM, never under 2 GB or over 8 GB"。**128 GB 上默认已是上限 8 GB，正是合适值**。菜单里的 `0`（关）选项危险（"a 16 GB Mac panicked with 14 MB free"），隐藏后更安全 |
| `--dspark` | mlx | 已外露 `main.swift:2852` | off | **C 保持外露，改文案** | **`false`**（依赖模型包） | cli.md 26.11.3："**DeepSeek-V4.1 runs the stages its pack ships unless `--no-mtp`**" → 对 Pruned192 包 DSpark **已默认开**，此 flag 主要用于旧包。菜单 "~11 GB resident" 需注明"仅对不自带 stage 的包" |
| `--api-key-env` | mlx | 已外露（`kTagMlxApiKeyEnv`，`main.swift:1028-1031`） | — | **保持现状** | 优先 env 注入 | `main.swift:612` 常量单一真相，设计正确，**不动** |

### 2.2.2 mlx-serve 新增参数处置（22 项）

| 参数名 | 引擎 | 当前状态 | 官方默认值 | 建议处置 | 本机建议默认值 | 依据 |
|---|---|---|---|---|---|---|
| **`--shutdown-persist-secs`** | mlx | 未外露 | **`45`** | **D 新增（代码级必须处置）** | 不传（=45），**但 `Service.stop()` 必须改** | cli.md："On SIGTERM, finish writing the SSD-tier slices not yet on disk for at most N seconds … Under launchd, set `ExitTimeOut` above it"。**`main.swift:1647` 只等 2.0 s 就 SIGKILL → 截断落盘**。详见 §2.3 |
| `--ane` | mlx | 未外露 | off | **A 隐藏** | 不传（=off） | 把整模型搬 ANE、**text only、≤64K、首次编译数分钟**。本机 40 核 GPU + 614 GB/s 是强项，把 75 GB MoE 搬 ANE 不现实（该 flag 限 dense qwen3_5/Qwen3）。与 Splash 的 ANE **拆分**不是一回事，**不要混淆** |
| `--ane-slots` | mlx | 未外露 | `1`（1..4） | **A 隐藏** | 不传 | 依赖 `--ane`，上一条既隐藏则本条无意义 |
| **`--int8-qk`** | mlx | 未外露 | off | **A 隐藏** | 不传（=off） | **关键判定**：`docs/performance.md` 明确 "**Flash-Next (`qwen4_exp`) switches to its own sparse attention past 2,048 tokens**" → **本机在跑的 Flash-Next 超过 2K 就不走这条路径**，收益仅限 dense Qwen 短 prompt。且**有损**。换 27B dense 长 prompt 时可手改配置启用（128K 时 +14%） |
| `--w8a8` / `--no-w8a8` | mlx | 未外露 | M5+ 且 ≥64 GiB 上 **on** | **A 隐藏（不适用）** | 不传 | cli.md 明确作用域是 **Image/video/music/3D 媒体模型**。SplashMLX 是文本 LLM 菜单栏工具，**完全无关** |
| `--lm-head-mxfp8` / `--no-lm-head-mxfp8` | mlx | 未外露 | 仅量化 Flash Next + 集成 CUDA 上 on | **A 隐藏** | 不传 | cli.md："other models, bf16 packs, discrete GPUs and **Macs opt in**"，且收益数据来自 DGX Spark（~8%）。**Mac 上未经测量**，有损，不宜默认开 |
| `--mtp-min-depth` | mlx | 未外露 | `1` | **A 隐藏** | 不传 | 自适应下界，抬高它只会强迫无效草稿 |
| `--mtp-max-depth` | mlx | 未外露（现有 `--mtp-depth` 待迁移） | **auto**（M5 NAX 最多 8） | **A 隐藏**（承接旧 `mtpDepth` 字段） | 不传（=自适应） | cli.md："every planner choice stays within the bounds"。自适应优于固定值 |
| `--dist` / `--dist-model` / `--dist-coordinator` / `--dist-device` / `--dist-split` | mlx | 未外露 | off | **A 隐藏（全部 5 项）** | 不传 | **需要第二台 Mac + Thunderbolt 5 RDMA 线**。本机单台，硬件前提不满足。官方 +57% 数据来自**两台 M3 Ultra**，与单机 M5 Max 无关 |
| `--no-plugins` | mlx | 未外露 | off | **D 新增外露**（P2） | `false` | 26.11.3 把 EXL3 移为独立插件、量化插件可服务内置模型。**排障价值高**（"a model a refused plugin served names it in its load error"）。若采纳 EXL3 DeepSeek 方案则必需能开关 |
| `--no-prefix-cache-ram` | mlx | 未外露 | off | **A 隐藏** | 不传 | 关掉 RAM 层只留 SSD，与本机"大内存高命中"策略相反 |
| `--warmup-full` | mlx | 未外露 | off | **A 隐藏** | 不传 | cli.md："**Strongly recommended when benchmarking**"，代价是首次加载慢"seconds to a minute"。菜单栏工具要的是**尽早就绪**，26.11.3 已改为"a build's one-time kernel compiles run **while the server is idle** instead of inside your first prompts" → 默认行为已更好 |
| `--llama-mtp-drafts` | mlx | 未外露 | `2` | **A 隐藏** | 不传 | 仅 GGUF + MTP 头路径；默认 2 合理 |
| `--llama-ubatch` | mlx | 未外露 | 512 | **A 隐藏** | 不传 | cli.md："1024-2048 prefill faster, mostly on MoE, **for more scratch memory**"。属 GGUF 精细调参，128 GB 上可试但非日常 |
| `--ablation-profiles` / `--ablation-key-file` | mlx | 未外露 | off | **A 隐藏（2 项）** | 不传 | 定向消融是研究用途，需 0600 密钥文件 + profile 目录，与菜单栏工具定位不符 |
| `--wired-margin-gib`（隐藏旋钮） | mlx | 未外露 | **8**（2..32） | **A 隐藏** | 不传 | `main.zig` 有解析但 cli.md 未列 → 非公开契约，不应外露 |

## 2.3 代码级必须处置的三个风险点

### 风险 1 · 默认模型不可加载（P0）

| 位置 | 现状 | 处置 |
|---|---|---|
| `main.swift:1057` | `var model: String = "incoai/Qwen3.8-27B-Splash"` | 改为 `"mlx-community/Qwen3.8-27B-4bit"`（官方 1.3.1 指定的等权重替代） |
| `main.swift:3046` | 空列表兜底 `["incoai/Qwen3.8-27B-Splash", "incoai/Qwen3.6-35B-A3B-Splash"]` | 改为 `["mlx-community/Qwen3.8-27B-4bit", "mlx-community/Qwen3.6-35B-A3B-4bit"]` |
| `Config.init(from:)` `main.swift:1133` | `model = (try? c.decode(...)) ?? model` | **需加迁移**：老配置里存着 `incoai/*-Splash` 会被原样读出 → 仍然崩。建议在此处做一次映射：`incoai/Qwen3.8-27B-Splash` → `mlx-community/Qwen3.8-27B-4bit`，`incoai/Qwen3.6-35B-A3B-Splash` → `mlx-community/Qwen3.6-35B-A3B-4bit` |

> 依据：1.3.1 notes §Breaking change 逐字给出替代仓库名。`main.swift:3047` 的 `if !list.contains(cfg.model) { list.append(cfg.model) }` 会把坏值再塞回列表，迁移必须发生在 `Config` 解码层。

### 风险 2 · 停机窗口冲突（P0）

```
main.swift:1640  static func stop() -> String {
main.swift:1643      kill(-pid, SIGTERM)
main.swift:1644      kill(pid, SIGTERM)
main.swift:1647      Thread.sleep(forTimeInterval: 2.0)      ← 只等 2 秒
main.swift:1649      kill(-pid, SIGKILL)                      ← 强杀
```

- **mlx-serve 26.11.3**：`--shutdown-persist-secs` 默认 **45 s**，SIGTERM 后要把 SSD 层未落盘的 slice 写完。2 s 强杀 = **前缀缓存被截断**，正好抵消 §2.2.1 里把 `--prefix-cache-disk` 提到 32 GB 的收益。
- **Splash 1.7.1** 也有同类窗口（`docs/server.md`）："it stops its engine with SIGTERM, which gives a persistent cache's newest restore points **up to 6 s** to reach the disk, and **kills an engine still running 15 s later**"。→ **Splash 侧至少需要 15 s**。

**建议处置（设计层，供工程师实现）**：
1. 等待时间按引擎分档：Splash ≥ **16 s**（覆盖其 15 s 内部强杀），mlx-serve ≥ **46 s**（覆盖 45 s 落盘）。
2. 改为**轮询 `isAlive(pid)` 提前退出**而非死等，避免正常情况下也卡 46 s。
3. 若用户在 mlx 侧显式设了 `--shutdown-persist-secs N`，等待上限应跟随该值（单一真相：从 `cfg.mlx` 读）。
4. `Thread.sleep` 阻塞主线程会让菜单栏卡死 —— 建议改为后台队列 + 菜单显示"正在停止…"。（现状已是阻塞，属既有问题，本次一并处置）

### 风险 3 · `--reasoning-effort` 互斥（P0，仅当决定外露时）

本设计**建议隐藏 `--reasoning-effort`**（§2.1.2），从根上规避。若工程师/产品坚持外露，则 `splashServeArguments`（`main.swift:1199`）必须加：

```
// 二者互斥（check_serve_arguments），只能传一个
if !reasoningEffort.isEmpty { 传 --reasoning-effort }
else if !defaultReasoningEffort.isEmpty { 传 --default-reasoning-effort }
```

并且菜单侧两项要联动置灰（不能只靠 `flagAvailable`，因为两个 flag 引擎都认识）。

## 2.4 处置汇总统计

| 引擎 | 保持外露 | 隐藏 | 改默认 | 新增外露 |
|---|---|---|---|---|
| Splash（21 现有 + 16 新 = 37） | 9 | 22 | 3（`max-cache-disk` 文案 / `idle-release=off` / `persistent-cache=true`） | 3（`--disable-ane` / `--max-concurrent-requests` / `--thinking-token-budget`）+ 1 可选（`--model-dir`） |
| mlx-serve（31 现有 + 22 新 = 53） | 13 | 33 | 3（`prefix-cache-disk=32GB` / `prefix-cache-mem=16GB` / `max-resident-models=1`） | 1（`--no-plugins`）+ 1 代码级（`--shutdown-persist-secs` 停机窗口） |

> 隐藏项**全部保留** `Config` 字段、tag 常量、`kGatedParams`/`kMlxGatedParams` 条目与 `serveArguments` 拼装分支 —— 只从 `splashSettingsItems()` / `mlxSettingsItems()` 摘掉菜单项。这样手改 `config.json` 仍生效，且老配置解码不破。

---

# 第三部分 · 推荐模型清单（128 GB / M5 Max）

## 3.0 官方分级依据

**mlx-serve README §What can my Mac run?**（逐字）：

| Memory | Suggested model |
|---|---|
| 96 GB and up | Qwen3.8-Flash-Next (125B, about 6B active per token) |
| **128 GB** | **Also GLM-5.3-Flash and DeepSeek-V4.1-Flash, their experts streamed from the SSD** |
| 256 GB | Also GLM-5.3-Flash in memory (NVIDIA's FP4 pack) |

**Splash 侧支持范围**（`install/families.py` `FAMILIES`，源码权威）：仅 **5 个家族** —— `Qwen3.8-27B`、`Qwen3.6-35B-A3B`、`Qwen3.5-122B-A10B`（含 Ornith-1.5-122B）、`Qwen3.8-Flash-Next`、`Flint`（`vision=False`）。
> **Splash 不支持 DeepSeek / GLM**。`docs/models.md`："a model of no family Splash serves is told so whatever its tower"。→ **DeepSeek-V4.1 与 GLM-5.3-Flash 只能走 mlx-serve**。

## 3.1 一线推荐（128 GB 可部署，已核实）

| # | 仓库（完整名） | 引擎 | 下载体积 | 常驻估算 | 可部署性 | 选型约束 | 依据 |
|---|---|---|---|---|---|---|---|
| **M1** | `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw` | **mlx-serve** | **107.3 GB**（safetensors 75.3 GB + ngram 表） | **≈75 GB** | ✅ **官方点名 128 GB 推荐** | ✅ **Qwen** | 模型卡逐字："Runs on a 128 GB Mac with about **75 GB resident** … **128 GB Mac (recommended)**"。含 MTP 头 + 视觉塔。n-gram 表 mmap **不 resident** |
| **M2** | `ddalcu/DeepSeek-V4.1-Flash-1017-MLX-Serve-iQ-MLX-Pruned192-2.25bpw` | **mlx-serve ≥26.11.2** | **296 GB**（含 Engram 表 203 GB） | **≈92 GB** | ✅ 可行，**磁盘代价大** | ✅ **DeepSeek** | 模型卡："for a **128 GB Mac** … About **92 GB resident**. Runs on mlx-serve **26.11.2 or later**"。实测 M4 Max 128 GB："loads with 104.8 GB available against 86.7 GB of weights, sizes the **full 1M-token context** … **no swap**"，≈31 tok/s decode / ≈470 tok/s prefill（**Engram 走网络盘**，本地 SSD 更快） |
| **M3** | `TensorFold/GLM-5.3-Flash-MLX-oQ2-MTP` | **mlx-serve** | **110.1 GB** | 【待确认】官方未给 resident 数；按 oQ2 全量权重估算 ≈100 GB，需靠专家 SSD 流式 | ⚠️ **可行但需验证** | ✅ **GLM** | 尺寸经 HF API 核实（33 files，2026-10-01）。26.10.3 官方："GLM-5.3-Flash … run on a **128 GB Mac** … full million-token context, about **35 tok/s**, short-question TTFT **2.5 s**"。**注意** `docs/models.md`："a streaming repack (`expert_streaming`) is **refused by name**" —— 必须用**普通 oQ 包 + per-model `stream_experts` 设置**，不能用声明 `expert_streaming` 的包 |
| **M4** | `TensorFold/GLM-5.3-Flash-MLX-2bit-MTP` | **mlx-serve** | **111.4 GB** | 【待确认】同上 | ⚠️ 同 M3，备选 | ✅ GLM | HF API 核实（37 files，2026-10-01） |

### M2 的重大质量警告（必须写进 UI 或文档）

模型卡逐字：

> "**Pruning is not free.** Half the experts are gone: code, reasoning and tool calls hold up well, chat loses more, and **non-English text degrades badly**."

实测 top-1 分片：agent 87.9% / code 88.2% / tools 92.0% / reasoning 91.9% / chat 79.6% / **multilingual 65.4%**；KLD multilingual **0.809**（3.0bpw 包为 0.117）。

> **对中文用户的直接结论**：这个包**不适合中文日常对话**，只适合英文代码/Agent/工具调用。若中文质量优先，128 GB 上应选 **M1（Flash-Next）** 或 **M3（GLM oQ2）**。

### M1 的质量数据（同尺寸更优）

模型卡：iQ-MLX-4.7bpw vs 未校准 mixed-4-8bit，**同样 75.3 GB**，top-1 全量 88.6% vs 87.9%，**code 96.0% vs 88.0%**，KLD 中位 0.0052 vs 0.0066。
→ **`mixed-4-8bit` 已被官方标注 superseded，不要选它**。

## 3.2 次线：小模型 / 快模型（Splash + mlx-serve 双引擎可选）

| # | 仓库 | 引擎 | 体积（HF API 核实） | 用途 | 依据 |
|---|---|---|---|---|---|
| S1 | `mlx-community/Qwen3.8-27B-4bit` | **Splash ✅ / mlx ✅** | **16.1 GB** | **Splash 新默认模型**（替代失效的 `incoai/Qwen3.8-27B-Splash`） | 1.3.1 notes 官方指定 |
| S2 | `mlx-community/Qwen3.6-35B-A3B-4bit` | Splash ✅ / mlx ✅ | **20.4 GB** | Splash 备选默认；MoE 解码极快 | 1.3.1 notes 官方指定 |
| S3 | `mlx-community/Qwen3.8-27B-8bit` | Splash ✅ / mlx ✅ | **29.5 GB** | 128 GB 上的**高质量 dense** 选择 | 1.3.1 notes 举例；1.3.2 支持 8bit |
| S4 | `mlx-community/Qwen3.6-35B-A3B-8bit` | Splash ✅ / mlx ✅ | **37.7 GB** | 高质量 MoE | HF API 核实 |
| S5 | `ddalcu/Qwen3.8-27B-MLX-Serve-4bit` | **mlx-serve 专用** | **22.1 GB**（HF API） | **MTP 头内置**，mlx 侧 27B 首选 | `docs/models.md` 标 18.2 GB，**与 HF API 的 22.1 GB 不符** → 【待确认】差异原因（可能文档数不含 MTP 头/视觉）。以 HF API 实测为准 |
| S6 | `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M` | Splash ✅ / mlx ✅(llama.cpp) | **16.56 GB**（单文件） | GGUF 路线；Splash 对其有专门优化 | HF API 逐文件核实 |
| S7 | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` | Splash ✅ / mlx ✅ | **22.13 GB** | 同上 | HF API |
| S8 | `unsloth/Qwen3.8-27B-GGUF:UD-Q8_K_XL` | Splash ✅ | **31.46 GB** | 最高质量 GGUF；1.3.2 起支持 `UD-Q8_K_XL` | HF API + 1.3.2 notes |
| S9 | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q8_K_XL` | Splash ✅ | **38.45 GB** | 同上 | HF API |
| S10 | `mlx-community/Qwen3.8-Flash-Next-4bit` | **Splash ✅（1.7.1 起）** | **111.5 GB** | Splash 侧跑 Flash-Next 的 MLX 路线 | 1.7.1 notes："Load Flint and **Qwen3.8-Flash-Next MLX checkpoints**, including Flash-Next vision"。**注意**：111.5 GB 含 n-gram 表张量，Splash 会流式化（`--ple-memory auto`），实际常驻远小于此 —— 【待确认】具体 resident 数官方未给 |

> **S10 的重要提醒**：Splash 的 `--ple-memory` 默认 auto 会把 PLE 表留在 SSD 流式读（`docs/server.md`："the table stays in its GGUF on the SSD … the weights shrink by the stored table size"），所以 111.5 GB 下载 ≠ 111.5 GB 常驻。但**官方未给 Splash 侧 Flash-Next MLX 的 resident 实测值**，标【待确认】，建议工程师实测后再决定是否列入菜单推荐。

## 3.3 明确排除（128 GB 不可行或不推荐）

| 仓库 | 体积 / 常驻 | 排除理由（官方原文） |
|---|---|---|
| `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-8bit` | 195 GB 下载 / **137 GB resident** | 模型卡："use it if **more than 128 GB**" |
| `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-3.3bpw` | 86 GB / **52 GB resident** | 可跑但为 **64 GB Mac** 档位；128 GB 上应选 4.7bpw（质量更好） |
| `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` | 107 GB / 75 GB | 模型卡："**superseded by iQ-MLX-4.7bpw** (same size, closer to bf16)" |
| `ddalcu/DeepSeek-V4.1-Flash-1017-MLX-Serve-iQ-MLX-3.0bpw` | **427.3 GB** / **209 GB resident** | 模型卡："**256 GB Mac**" |
| `ddalcu/DeepSeek-V4.1-Flash-1017-MLX-Serve-Lossless` | 477 GB / **288 GB resident** | 模型卡："**512 GB Mac**, or as a reference" |
| `Jundot/GLM-5.3-Flash-oQ4e-mtp` | **186.4 GB**（173.6 GiB，4.641 bpw） | 全量常驻远超 128 GB。2026-11-19 用 oMLX 0.8.0 重量化。**除非靠专家流式，否则不可行**；官方 128 GB 说法针对的是流式路径，oQ4 包能否流式【待确认】 |
| `TensorFold/GLM-5.3-Flash-MLX-oQ4-MTP` | **185.8 GB** | 同上 |
| `nvidia/GLM-5.3-Flash-FP4-Local` | **177.5 GB**（≈175 GiB） | `docs/models.md` 逐字："about 175 GiB: a **256 GB Mac**" |
| `mlx-community/DeepSeek-V4.1-Flash-1017-oQ2e-mtp` | **313.3 GB** | 体积过大；oQ2e 是**全 384 专家** 2-bit，非 pruned |
| `mlx-community/DeepSeek-V4.1-Flash-1017-oQ2.5e-mtp` | **342.7 GB** | 同上 |
| `incoai/Qwen3.8-27B-Splash`、`incoai/Qwen3.6-35B-A3B-Splash` | — | **1.3.1 起彻底不加载** |

## 3.4 备选方案：EXL3 流式 DeepSeek（高质量但磁盘代价极大）

`OpensourceWTF/DeepSeek-V4.1-Flash-1017-streaming-repack-exl3` —— **分支即档位**，`main` 只有卡片（HF API 返回 8 files / 0 GB 权重，已核实）。

| 分支 | 体积 | 服务方式 | 备注 |
|---|---|---|---|
| **`2.81bpw`** | **408.2 GB** | `turboexl3_ds41` 插件 | **官方推荐分支**（"`2.81bpw` is our pack and the one we recommend"） |
| `2.68bpw` | 395.4 GB | 同上（fractional layers） | turboderp 量化 |
| `2.25bpw` | 361.5 GB | 同上 | turboderp |
| `1.68bpw` | 326.7 GB | 同上 | turboderp，质量最低 |
| `2.9bpw` | 417.8 GB | **`mlx-stream` 插件**（不同插件） | Mia-AiLab 量化 |

**可行性**：模型卡逐字 —— "In every pack the **trunk loads once**, and the routed experts and the Engram tables are **read from SSD as they are needed**, so a Mac with **128 GB can serve the model**。**The turboexl3_ds41 plugin … needs an M5-class GPU**"。

→ **本机 M5 Max 满足 GPU 要求**。但：
1. **磁盘 408 GB**（M2 为 296 GB），且需内置 SSD（模型卡对 M2 明确要求 "Keep the model on the Mac's internal SSD"）。
2. 需装**外部插件**，26.11.2 起插件与引擎版本绑定（"Outside plugins built for 26.11.1 now show **Needs rebuild**"）→ 升级维护成本高。
3. 相比 M2 的优势是**保留全部 384 专家**（无 pruning 质量损失，中文不会崩）。

**建议**：列为**可选高级方案**，若用户磁盘 ≥1 TB 且重视中文质量，可优先于 M2。这也是 §2.2.2 建议外露 `--no-plugins` 的原因（插件排障需要）。
**下载命令**（模型卡原文）：`hf download OpensourceWTF/DeepSeek-V4.1-Flash-1017-streaming-repack-exl3 --revision 2.81bpw --local-dir <dir>`

## 3.5 性能参考（官方实测，注意机型差异）

**mlx-serve v26.11.3，M5 Ultra 256 GB，code prompt，投机解码开**（README）：

| 模型 | tok/s |
|---|---|
| Qwen3.6 35B-A3B 4-bit | 439 |
| Qwen3.8 27B 4-bit | 244 |
| Gemma 4 E4B 4-bit | 197 |
| Gemma 4 26B-A4B 4-bit | 184 |
| **Qwen3.8-Flash-Next 4.7 bits** | **168** |

> **本机换算提醒**：M5 **Ultra** 带宽约 1.1 TB/s 级，本机 M5 **Max** 为 **614 GB/s**。解码是带宽瓶颈 → **本机 Flash-Next 预期约 90–110 tok/s 量级**（按比例外推，**非官方数据，标【待确认】**，需工程师实测）。
> M2 模型卡自己也提示："These numbers are from a 256 GB Mac; on a **128 GB Mac (lower memory bandwidth on most models) expect less**"。

---

# 第四部分 · 待确认清单（不臆造）

| # | 待确认项 | 为什么没确认 | 建议核实方式 |
|---|---|---|---|
| U1 | Splash 侧 `mlx-community/Qwen3.8-Flash-Next-4bit` 的实际 resident | 官方只给 GGUF 侧数据；MLX 包 1.7.1 才支持 | 实跑 `splash serve` 看 `/status.memory_plan` |
| U2 | GLM-5.3-Flash oQ2 包（M3/M4）的 resident 与是否需 `stream_experts` | 26.10.3 只给"128 GB 可跑"结论，未给逐包 resident | 实跑 + 看 `docs/models.md` 的 per-model 设置说明 |
| U3 | `Jundot/GLM-5.3-Flash-oQ4e-mtp`（186 GB）能否靠流式在 128 GB 跑 | 官方 128 GB 说法未点名具体包 | 同上 |
| U4 | `ddalcu/Qwen3.8-27B-MLX-Serve-4bit` 18.2 GB（docs）vs 22.1 GB（HF API） | 两个官方来源不一致 | 以 HF API 为准；差异可能是 MTP 头/视觉塔计入口径 |
| U5 | mlx-serve `--prefix-cache-entries` 的 auto 算法 | 26.11.3 cli.md 只写 "auto"，未展开 | 读 `src/server` 相关源码或实测 |
| U6 | 本机内置 SSD 剩余容量 | 未采集 | `df -h /` —— 直接决定 M2（296 GB）/ EXL3（408 GB）能否落地 |
| U7 | 本机 Flash-Next 实测 tok/s | README 数据来自 M5 Ultra | 升级后用 `llmprobe` 或菜单栏 KPI 实测 |
| U8 | `main.swift:1469` 附近 `/status` 解析是否读了 schema 8 删除的两个字段 | 1.6.0 只说"Two fields were removed"，未给字段名 | 对比 1.2.1 与 1.7.1 的 `/status` 实际响应 |
| U9 | `--max-cache-disk-writes` 是否需要设限 | 取决于 U6 磁盘容量与写入量 | 观察 `/status` 的 hourly/daily write totals（1.7.0 新增） |

---

# 附录 A · 证据来源索引

| 类别 | 来源 |
|---|---|
| Splash release notes | GitHub API `repos/incoai/splash/releases` → 1.3.0 / 1.3.1 / 1.3.2 / 1.4.0 / 1.4.1 / 1.5.0 / 1.6.0 / 1.6.1 / 1.7.0 / **1.7.1** 全文 |
| Splash flag 权威 | `server/serve_options.py` @ `1.2.1` 与 `1.7.1`（`ServeOption` 定义 + `check_serve_arguments` + 常量） |
| Splash launcher flag | `install/launcher.py` @ 1.7.1 |
| Splash 家族 | `install/families.py` @ 1.7.1（`FAMILIES` 五族 + `QWEN_SAMPLING`） |
| Splash 文档 | `docs/server.md`（Server options 完整默认值表、Memory and context、PLE table streaming、Streamed experts、KV on the SSD）、`docs/models.md`、`docs/performance.md` @ 1.7.1 |
| mlx-serve release notes | GitHub API `repos/ddalcu/mlx-serve/releases` → 26.10.2 / 26.10.3 / 26.11.1 / 26.11.2 / **26.11.3** |
| mlx-serve flag 权威 | `src/main.zig` @ `26.10.1` 与 `26.11.3`（字面量差集 + 解析分支 + 默认值） |
| mlx-serve 文档 | `docs/cli.md`（两版对比）、`docs/reference.md`（两版 env 差集）、`docs/performance.md`、`docs/models.md`、`docs/faq.md`、`docs/api.md`、`README.md` @ 26.11.3 |
| 模型尺寸 | `hf-mirror.com/api/models/<repo>?blobs=true` 逐文件字节求和（huggingface.co 直连返回非 JSON，改用镜像） |
| 模型卡 | `ddalcu/Qwen3.8-Flash-Next-…-4.7bpw`、`ddalcu/DeepSeek-V4.1-…-Pruned192-2.25bpw`、`OpensourceWTF/…-streaming-repack-exl3`、`Jundot/GLM-5.3-Flash-oQ4e-mtp` |
| 代码 | `main.swift` @ git `b7b4286`，行号见正文 |

> **网络备注**：GitHub raw 直连常失败（curl 35 SSL），本次统一走 `https://gh-proxy.com/` 前缀；release notes 走 GitHub API；HF 走 `hf-mirror.com`。所有临时调研文件在任务结束后已清理。