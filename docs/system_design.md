# SplashMLX 引擎启动参数能效方案（M5 Max / 128GB / Qwen3.8-Flash-Next）

> 作者：高见远（架构师） · 性质：**只读审计**，未修改任何配置、未 kill 进程
> 取证时间：2026-10-06 01:08 CST（mlx-serve 在线运行中获取）
> 所有数字均来自本机实测或 `--help` 原文，未实测处已显式标注「待实测」

---

## 0. TL;DR（先看这 5 条）

| # | 结论 | 级别 |
|---|------|------|
| 1 | **`--ple-gpu` 别开。** 它要常驻的 n-gram 表实测 **29.80 GiB**（`ngram_table.bin` 精确字节数 32,000,153,976），开完常驻约 **118.6 GiB / 128 GiB**，超出引擎 `--max-resident-mem` 自动上限（97.3 GiB）22%，收益只有帮助原文写的「a few %」 | ❌ 别动 |
| 2 | **`--max-mtp-ctx 65536` 是本机收益最大的一项，且无损。** 实测平均 prompt **102,717 tokens**，帮助原文明确警告「长上下文上 MTP 一轮验证可能比它替代的串行步更贵」。当前解码只有 **44.9 tok/s**，长上下文很可能是反噬 | P0 实测 |
| 3 | **升级前先把 Splash 的 `--idle-release` 预设好。** 1.2.1 新增默认 **10 分钟空闲就卸载权重**，这是行为级变更（1.1.0 无此行为），不设会「睡一觉起来首包变慢」 | P0 预设 |
| 4 | **两套引擎别同时跑，或必须显式给 Splash 设 `--max-memory`。** mlx-serve 已占 88.81 GiB，Splash 的 `--max-memory auto` 自认可用 ~107 GiB，两个进程**不互相协调**，必然超售 | P0 设闸 |
| 5 | **大部分「新增参数」现在就能用，不必等升级。** 26.9.6 已经含 `--max-mtp-ctx` / `--os-reserve-gib` / `--reasoning-budget` / `--dspark` / `--decode-attn-quant` 等；26.10.1 **真正新增的只有 4 个**：`--ple-gpu`、`--mlx-gguf`、`--mtp-greedy-tail`、`--prefill-decode-share`（无移除项） | 认知修正 |

---

## 1. 取证摘要（证据链）

| 项目 | 数值 | 来源 |
|------|------|------|
| 机型 | M5 Max / 18 核 / **128 GiB** | `sysctl hw.memsize` |
| 在跑引擎 | mlx-serve **26.9.6** @ 127.0.0.1:11234 | `/opt/homebrew/bin/mlx-serve --version` |
| 在跑模型 | `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` | `GET /v1/models` |
| 模型架构 | **`qwen4_exp`**，`Qwen4ExpForConditionalGeneration`，MoE（512 专家 / top-10 / 48 层） | 模型 `config.json` |
| 层类型 | **36 层 `linear_attention` + 12 层 `full_attention`**（每 4 层一个 full） | `text_config.layer_types` |
| MTP | `mtp_loaded: true` / `mtp_available: true`，1 层 full_attention hybrid head | `GET /v1/models` + `config.json` |
| n-gram 表 | `ngram_table.bin` = **32,000,153,976 B = 29.80 GiB**（4-bit, group 32） | `stat` + `config.json.ngram_table` |
| 权重体积 | **70.13 GiB**（index.json `total_size` = 75,302,793,208） | `model.safetensors.index.json` |
| MLX 常驻 | **88.81 GiB**（`mlx_active_bytes` = 95,364,083,526） | `GET /metrics.json` |
| MLX wired limit | **121.60 GiB**（124,518 MB） | 启动日志 `[mem] MLX buffer-pool cap 8192 MB (was 124518 MB)` |
| n-gram 状态 | `ngram_warm_bytes` = **29.80 GiB**（= 表全尺寸，当前 `--ple-gpu` 关闭） | `GET /metrics.json` |
| ANE | `ane_int8_bytes: 0` / `ane_layers: 0` → 未走神经引擎 | `GET /metrics.json` |

### 1.1 实测工作负载画像（168 次请求累计，来自 `/metrics.json`）

| 指标 | 数值 |
|------|------|
| 平均 prompt | **102,717 tokens** |
| 平均生成 | 896 tokens |
| 平均 TTFT | **8.36 s** |
| 平均 prefill | 8.34 s |
| 平均 decode | 19.96 s |
| **解码吞吐** | **44.9 tok/s** |
| 前缀缓存命中率 | **161 / 168 = 95.8 %** |
| 前缀缓存供词占比 | 15,861,131 / 17,256,750 = **91.9 %** |

> 画像结论：这是一个「**超长 prompt + 短输出**」的 agentic / RAG 型负载。
> 瓶颈在 **prefill 与长上下文解码**，不在并发。所以调参重心应是
> **① 长上下文下 MTP 是否有效 ② 前缀缓存命中 ③ 内存余量**，而不是队列/并发类参数。

---

## 2. 内存账（逐项推演）

### 2.1 静态账

```
权重 safetensors       70.13 GiB
ngram_table.bin        29.80 GiB   <-- --ple-gpu 要常驻的就是它
────────────────────────────────
磁盘合计               99.93 GiB
```

### 2.2 运行时账（128 GiB 机器）

| 场景 | 常驻 | 余量 | 是否超 `--max-resident-mem` 自动上限 97.28 GiB |
|------|------|------|------|
| **现状**（ple-gpu off） | **88.81 GiB** | **39.19 GiB** | 否 —— 但已用到上限的 **91.3 %** |
| **开 `--ple-gpu`**（+29.80） | **118.62 GiB** | **9.38 GiB** | **是 —— 超 21.3 GiB** |
| 开 `--ple-gpu` + `--os-reserve-gib 8`（默认） | 126.62 GiB | 1.38 GiB | **是，且几乎贴死 128 GiB** |

> `--os-reserve-gib` 默认 = RAM/8 并夹到 2–8 GiB，128 GiB 机器即 **8 GiB**。
> 所以「开 `--ple-gpu` 后还剩 9.38 GiB」实际**只剩 1.38 GiB 可用**——系统级不可用。

### 2.3 `--ple-gpu` 到底会不会真的 +29.8 GiB？（关键不确定点）

**存在两种读法，我无法用只读手段证死，故标注「待实测」，但给出判断依据：**

- **读法 A（增量 ≈ +29.8 GiB，我倾向这个）**
  若权重 70.13 与 n-gram 29.80 都已常驻，`mlx_active_bytes` 应 ≥ 99.93 GiB；
  实测只有 **88.81 GiB**，差 **11.12 GiB**。说明二者**未全部常驻**。
  又因帮助原文写明「off = rows read from the mmapped file on demand」，
  最可能的是 **n-gram 目前按需从 mmap 分页**，故 `ngram_warm_bytes = 29.80 GiB`
  是**表总尺寸（受管范围）**而非当前实际常驻量。→ 开 `--ple-gpu` 会**新增约 29.8 GiB**。

- **读法 B（增量 ≈ 0）**
  若 `ngram_warm_bytes` 就是实际常驻量，则表已在内存里，`--ple-gpu` 只是把它
  从「文件页（可回收）」钉成「GPU 常驻（不可回收）」。→ RAM 增量近 0，
  但**系统会永久失去约 30 GiB 可回收内存**。

> **两种读法都不支持「现在就开」**：
> A 直接超上限；B 虽不超 RAM，但会把 30 GiB 变成不可回收，
> 而此刻**第二个模型（`...-iQ-MLX-4.7bpw`）正在后台下载**（观测时间 01:08 仍在写入 `.incomplete`），
> 下载 + 后续加载都需要可回收页。**结论：默认不开。**

### 2.4 KV cache 结构账（这是本模型最大的"隐藏优势"）

48 层里只有 **12 层是 `full_attention`**，其余 36 层是 `linear_attention`（无 KV 缓存）：

```
每 token KV = 12 层 × 2 KV头 × 256 head_dim × 2(K,V) × 2 B(bf16) = 24,576 B = 24 KiB
```

| 上下文 | 每会话 KV |
|--------|-----------|
| 256K 满上下文 | **6.00 GiB** |
| 实测平均 102,717 tokens | **2.35 GiB** |

→ `prefix-cache-mem 16 GiB` 预算可放 **约 6.8 个**平均长度会话；
若 `--kv-quant 8`（KV 减半）可放 **约 13.6 个**。

> 因为 KV 本来就小，**`--kv-quant` 的"省内存"动机很弱**，
> 它真正的价值是"同样的 16 GiB 能多放一倍会话 → 提高命中率"。
> 但当前命中率已 **95.8 %**，边际收益有限 → 判为 **P2 可选**，不值得为此引入有损量化。

---

## 3. 结论表 —— mlx-serve 侧（在跑引擎）

> 优先级：**P0** = 必做 / 收益最大 · **P1** = 建议 · **P2** = 可选 · **❌** = 别动

| 参数 | 建议值 | 预期收益（业务语言） | 代价与风险 | 优先级 |
|------|--------|----------------------|-----------|--------|
| `--ple-gpu` | **off（保持）** | 帮助原文：prefill/decode **快几个百分点** | **+29.8 GiB 常驻**，超 `--max-resident-mem` 上限 21.3 GiB；或永久损失 30 GiB 可回收内存 | **❌ 别动** |
| `--max-mtp-ctx` | **65536**（先试） | 长上下文解码**可能明显变快**——当前 44.9 tok/s 偏低，很可能 MTP 在 100K+ 上下文是负收益 | **无损**（只是超阈值后不用 MTP，走精确串行解码）；最坏情况是变慢，改回即恢复 | **P0 实测** |
| `--mtp-depth` | **留空（adaptive）** | 引擎 EV 控制器在 **M5 NAX 目标上自适应到 8**（非 M5 为 6），已是最优 | 写死会砍掉自适应；帮助原文说默认即最优 | **❌ 别动** |
| `--mtp-greedy-tail` | **off（保持）** | 帮助原文：它"**Pays with `--mtp-typical`**"，单独开在精确接受下几乎无收益 | 有损（后续草稿走 argmax）；`--mtp-typical` 本身是 opt-in 有损项且未进菜单 | **❌ 别动** |
| `--no-decode-attn-quant` | **保持不传**（用引擎默认） | 帮助原文：对**「ship dense attention」**的模型可省约 25% decode 读宽 | 本模型注意力**已是 4-bit affine 量化**（`quantization.bits=4`），不存在 dense bf16 注意力副本 → **对本模型大概率无效**；显式关也无从关起 | **❌ 别动** |
| `--kv-quant` | **off（保持）** | KV 减半 → 16 GiB 前缀预算可放会话数 6.8 → 13.6 个 | **有损注意力**；KV 本就只占 2.35 GiB/会话，省内存动机弱；命中率已 95.8% | **P2 可选** |
| `--ctx-size` | **262144（保持）** | 模型 `max_position_embeddings` 就是 262144，已是满配 | 降到 128K 可多塞前缀会话，但会截断 >128K 的 prompt（平均已 102,717，风险高） | **❌ 别动** |
| `--prefix-cache-mem` | **16GB（保持）** | 引擎默认仅 2GB，当前 16GB 是命中率 95.8% 的主因之一 | 无（余量 39 GiB 足够） | **✅ 已最优** |
| `--prefix-cache-disk` | **32GB（保持）** | 前缀跨重启保留，不用重算 → 重启后首包不退化 | 占 SSD，本机余 1.5 TiB，无压力 | **✅ 已最优** |
| `--prefix-cache-entries` | **64（保持）** | 与 16 GiB 预算匹配 | 无 | **✅ 已最优** |
| `--max-resident-models` | **1（保持）** | 70 GiB 模型在 128 GiB 上本来就放不下第二个 | 无 | **✅ 已最优** |
| `--idle-evict-secs` | **off（保持）** | 菜单栏 App 要"随时秒回"，驱逐后重载代价远大于省的内存 | 开着会在空闲后丢掉热模型 | **❌ 别动** |
| `--no-vision` | 可考虑开 | 视觉塔（depth 27 / hidden 1152）约 **1–2 GiB**，纯文本负载可省 | **永久失去 vision/video 能力**（`/v1/models` 显示 `input_modalities: text,image,video`） | **P2 可选** |
| `--os-reserve-gib` | **默认（8 GiB）** | 保持系统不被拖死 | 调到 4 可多换 4 GiB 上下文，但失去安全垫 | **❌ 别动** |
| `--skip-mem-preflight` | **off（保持）** | 无 | 帮助原文：**"A genuine over-commit can hard-crash the server"** | **❌ 别动** |
| `--dspark` | **off（保持）** | 无 —— **DeepSeek-V4 专属** | 常驻约 **11 GiB**；本模型是 `qwen4_exp`，**不适用** | **❌ 不适用** |
| `--engine` / `--mlx-gguf` | **不动** | 无 | 帮助原文：**"Engine selector for `.gguf` inputs ONLY. Safetensors models always run on the native MLX engine and ignore this flag."** 本模型是 safetensors | **❌ 不适用** |
| `--lan-share` / `--lan-discover` | **off（保持）** | 零性能收益 | 帮助原文隐私警告：**"Prompts sent to shared models are visible to this machine"** | **❌ 别动** |
| `--reasoning-budget` | 如需可设 8192 | 砍掉超长思考 → 直接省解码时间 | **改变输出**（模型带 `reasoning` 能力）；agent 场景需先确认不依赖长链思考 | **P2 谨慎** |
| `--prefill-decode-share` | **不用管（默认 0 = 关）** | 无 —— 帮助原文：它是**「另一个请求在 prefill 时，解码流能保住的墙钟比例」**，只在**多请求并发**时有意义 | 默认 0（关）。实测 `requests_running/waiting` 均为 0，单用户串行负载调它零收益 | **❌ 别动（且未进菜单）** |
| `--no-prevent-sleep` | **off（保持）** | 无 | 允许空闲睡眠会**中断推理与模型加载** | **❌ 别动** |
| `--api-key-env` | 若要设就设 | 零性能收益；安全收益（argv 进程表全机可读） | 无 | **P2 安全** |

---

## 4. 结论表 —— Splash 侧（`Qwen3.6-35B-A3B-Splash`，当前未运行）

| 参数 | 建议值 | 预期收益 | 代价与风险 | 优先级 |
|------|--------|----------|-----------|--------|
| `--idle-release` | **`off`（要秒回）或 `30m`（要省内存）** | 控制"空闲 10 分钟卸载权重"这一 **1.2.1 行为级新默认** | `off` = 常驻不释放（升级前老行为）；`10m` 默认值会让**隔夜首包变很慢** | **P0 预设** |
| `--max-memory` | **显式 `28G`** | 给 Splash 设硬闸，避免与 mlx-serve 互不知情地超售 | 设太小会限制上下文 | **P0 设闸** |
| `--persistent-cache` | **on** | 配合已设的 `--max-cache-disk 32G`，**重启后 SSD 前缀缓存不丢 → 重启首包不退化** | 帮助原文：必须**先有 `--max-cache-disk`**（已满足 32G） | **P1** |
| `--offline` | **on** | 不联系 HF Hub 启动 → 启动更快、断网可用 | 仅对**已下载完成**的模型有效 | **P1** |
| `--kv-format` | **int8（默认）** | 省内存 | `bf16` 更占内存且无必要 | **✅ 保持** |
| `--decode-share` | **0.5（默认）** | 无 —— 该参数只在**多请求并发**时分配 prefill/decode 时间片；单用户串行无效 | 乱调会让 prefill 或 decode 饿死 | **❌ 别动** |
| `--queue-size` / `--request-timeout` | **默认（32 / 无超时）** | 无 —— 单用户负载用不到 | 调小会 503 | **❌ 别动** |
| `--allow-idle-sleep` | **off（保持）** | 无 | 请求进行中允许睡眠 → 中断推理 | **❌ 别动** |
| `--host` | **127.0.0.1（保持）** | 无性能收益 | 0.0.0.0 暴露局域网，须同时设 API Key | **❌ 别动** |
| `--language-only` | 视模型是否多模态 | 跳过视觉准备与加载 → 省内存 | 失去视觉能力 | **P2** |
| `--allowed-origin` / `--max-request-size` | 默认 | 无性能收益 | — | **P2** |

> **⚠️ 菜单可见性**：`main.swift:2091` 处 `if running { menu.addItem(submenuItem("Settings"…)) }` ——
> **Settings 子菜单只在引擎处于运行态时才展开**。
> 所以 Splash 的这些项**必须先启动 Splash 服务才调得到**。

---

## 5. 针对 Qwen3.8-Flash-Next 的「专属 / 不适用」区分

### ✅ 专属（帮助原文或模型 config 点名适用）

| 参数 | 证据 |
|------|------|
| `--ple-gpu` | 帮助原文首句即 **"Qwen3.8-Flash-Next: gather the n-gram table on the GPU"**；模型目录名与 `config.json` 的 `ngram_table`/`ple_embed_dim:2560`/`ple_layer_ids:[2]`/`ngram_size:3`/`ngram_vocab_size_base:20000000` 完全对上 |
| `--mtp` / `--mtp-depth` / `--max-mtp-ctx` | 模型 `text_config.mtp` 存在（hybrid, 1 层 full_attention）；`/v1/models` 报 `mtp_loaded:true, mtp_available:true` |
| `--prefix-cache-*` | 帮助原文点名 **"qwen4_exp"**：`--prefix-cache-mem` 默认会取"one session at the working context on qwen4_exp"；本模型 `model_type` 正是 `qwen4_exp` |

### ❌ 不适用（该模型吃了也没用）

| 参数 | 为什么不适用（原文证据） |
|------|--------------------------|
| `--dspark` | **"Enable DeepSeek-V4 DSpark draft stages"** —— 本模型 `qwen4_exp` |
| `--engine` / `--mlx-gguf` / `--ssd-streaming` / `--no-ds4-mtp` | **"for `.gguf` inputs ONLY. Safetensors models always run on the native MLX engine and ignore this flag."** |
| `--ane-prefill` | **"(qwen3_5-family only; …)"** —— 本模型是 `qwen4_exp`；且实测 `ane_layers: 0`。注意该 flag **未进 App 菜单**（不在 `kMlxGatedParams`），也调不到 |
| `--ssm-checkpoint-stride` / `--ssm-checkpoint-max` | **"Hybrid SSM architectures only (e.g. Qwen3.5/3.6 GDN)"** —— 本模型是 qwen4_exp 的 `linear_attention` 混合。**这两个 flag 未进 App 菜单**，无从设置 |
| `--decode-attn-quant` | 只对 **"models that ship dense attention (e.g. Laguna)"** 有效；本模型注意力**出厂即 4-bit 量化**（`quantization.bits:4, mode:affine`） |
| `--mtp-head-kv-quant` | **"the qwen4 MTP head's own KV"** —— 帮助原文说的是 **qwen4** MTP 头；本模型 `model_type` 为 **qwen4_exp**，且该 flag 未进 App 菜单 —— **待实测** |

---

## 6. 可直接照做的配置清单

> **通用规则**：这些参数都是**进程启动参数**（见 `MLXConfig.serveArguments` / `Config.splashServeArguments`），
> **全部必须重启服务才生效**（菜单改完 → Stop → Start）。
> 菜单路径格式：`Settings → <分组> → <菜单项名> → <选项>`

### 6.1 mlx-serve 侧（当前引擎，升级前后都能做）

| 步骤 | 菜单路径 | 选什么 | 重启 |
|------|----------|--------|------|
| 1 | `Settings → Memory & context → PLE table on GPU  --ple-gpu` | **"Read PLE table from disk (default)"** ← 保持默认，别改 | — |
| 2 | `Settings → Model & decoding → MTP context ceiling  --max-mtp-ctx` | **65536**（先试这一档；跑一轮后再试 32768 对比） | ✅ 必须 |
| 3 | `Settings → Model & decoding → MTP draft depth  --mtp-depth` | **"Adaptive (engine controller, up to 8 on M5)"** ← 保持 | — |
| 4 | `Settings → Model & decoding → MTP greedy tail  --mtp-greedy-tail` | **"Off — exact (default)"** ← 保持 | — |
| 5 | `Settings → Model & decoding → MTP speculative  --mtp` | **"On — pass --mtp (required for MoE models)"** ← 保持（MoE 不显式传就永远开不上） | — |
| 6 | `Settings → Memory & context → KV cache quant  --kv-quant` | **"off (default)"** ← 保持 | — |
| 7 | `Settings → Prefix cache → Prefix cache memory  --prefix-cache-mem` | **16GB** ← 保持（已最优） | — |
| 8 | `Settings → Prefix cache → Prefix cache SSD  --prefix-cache-disk` | **32GB** ← 保持 | — |
| 9 | `Settings → Memory & context → OS free-RAM reserve  --os-reserve-gib` | **"Engine default (RAM/8, clamped 2–8 GB)"** ← 保持 | — |
| 10 | `Settings → Memory & context → Memory preflight  --skip-mem-preflight` | **"Preflight load checks (default)"** ← **必须保持** | — |
| 11 | `Settings → GGUF serving → DSpark stages  --dspark` | **"Off (default)"** ← 保持 | — |
| 12 | `Settings → Serving → LAN share / LAN discover` | **Off** ← 保持 | — |

### 6.2 Splash 侧（**必须先启动 Splash 服务，Settings 才会展开**）

| 步骤 | 菜单路径 | 选什么 | 重启 |
|------|----------|--------|------|
| 1 | `Settings → Memory & cache → Idle release  --idle-release` | 要秒回选 **"Never release — keep weights resident"**；要省内存选 **30m**。**别留默认的 10m** | ✅ 必须 |
| 2 | `Settings → Memory & cache → Max memory  --max-memory` | **28G**（显式硬闸，防与 mlx-serve 超售） | ✅ 必须 |
| 3 | `Settings → Memory & cache → Persistent cache  --persistent-cache` | **"Keep SSD cache across restarts"** | ✅ 必须 |
| 4 | `Settings → Memory & cache → Max cache disk  --max-cache-disk` | **32G** ← 保持（`--persistent-cache` 依赖它） | ✅ 必须 |
| 5 | `Settings → Model & decoding → Offline  --offline` | **"Start without contacting HF Hub"**（模型下载完成后开） | ✅ 必须 |
| 6 | `Settings → Model & decoding → Decode share  --decode-share` | **"Engine default (0.5)"** ← 保持 | — |
| 7 | `Settings → Serving & access → Idle sleep  --allow-idle-sleep` | **"Stay awake while requests run (default)"** ← 保持 | — |

### 6.3 升级顺序建议

```
1. 现在（26.9.6）：先做 6.1 的第 2 步 --max-mtp-ctx 65536，并跑一轮实测
   （该 flag 26.9.6 已有，不必等升级）
2. brew upgrade 之前：先启动 Splash → 把 6.2 的第 1、2 步设好再升级
   （防 1.2.1 的 10m 卸载新默认打你个措手不及）
3. brew upgrade 之后：App 的 flagAvailable 会自动放开 26.10.1 新增项
   → **全部保持不动**（理由见第 3 节）。其中 `--prefill-decode-share`
     目前**未被 App 暴露**（`main.swift` 全文零引用），只能手改配置或命令行，
     且对单用户负载零收益，不建议为它做改动
4. 升级后复测 /metrics.json 的 memory_mb 与 ngram_warm_bytes，确认无异常
```

---

## 7. 明确「别动」清单（含原因）

| 项 | 原因（原文级证据） |
|----|-------------------|
| `--ple-gpu` | 常驻 +29.80 GiB → 118.62 GiB，**超 `--max-resident-mem` 自动上限 97.28 GiB**；收益仅「a few %」 |
| `--skip-mem-preflight` | **"A genuine over-commit can hard-crash the server"** |
| `--dspark` | DeepSeek-V4 专属 + 常驻 ~11 GiB；本模型 `qwen4_exp` **不适用** |
| `--engine` / `--mlx-gguf` | **"for `.gguf` inputs ONLY"** —— safetensors 忽略 |
| `--mtp-greedy-tail` | 帮助原文：仅在配 `--mtp-typical`（有损）时才 **"Pays"**，单开无收益且有损 |
| `--mtp-typical` / `--mtp-tokenv3` | **"Opt-in lossy"** 有损；且未进 App 菜单 |
| `--mtp-depth` 写死 | 默认 adaptive 在 M5 NAX 上已能到 8，写死是降级 |
| `--ane-prefill` | **"qwen3_5-family only"**；本模型 `qwen4_exp`（且该 flag 未进菜单） |
| `--ssm-checkpoint-*` | Qwen3.5/3.6 GDN 专属（且未进菜单） |
| `--kv-quant 4/8` | 有损；KV 仅 2.35 GiB/会话，省内存动机弱，命中率已 95.8% |
| `--no-prevent-sleep` / `--allow-idle-sleep` | 会导致推理/加载被睡眠中断 |
| `--lan-share` / `--lan-discover` | 零性能收益 + **"Prompts … are visible to this machine"** 隐私风险 |
| `--ctx-size` 下调 | 平均 prompt 102,717，128K 会截断风险高 |
| `--idle-evict-secs` 开 | 菜单栏 App 要秒回，重载代价 > 省的内存 |
| `--os-reserve-gib 0` | 帮助原文：**"a small Mac under heavy load can freeze or restart"** |
| Splash `--decode-share` 乱调 | 单用户串行负载无效，只会让 prefill/decode 互相饿死 |
| mlx `--prefill-decode-share` | 同类并发公平性旋钮，**默认 0（关）**，单用户负载零收益；且未进 App 菜单 |
| **两套引擎同时跑而不设 `--max-memory`** | 两个进程不协调内存，必超售 |

---

## 8. 待实测项 + 验证协议

> 验证工具：**`curl -s http://127.0.0.1:11234/metrics.json`**
> （App 强制打开了 `--metrics`，见 `main.swift:1004`，所以这个端点一直可用）

| # | 待实测 | 怎么测（只读，不改配置） |
|---|--------|--------------------------|
| 1 | `--ple-gpu` 的真实增量 | 开之前记 `memory_mb` / `mlx_active_bytes` / `ngram_warm_bytes`；开并重启后再记同一组。**若 `mlx_active_bytes` 涨约 29.8 GiB → 读法 A 成立，立即关掉** |
| 2 | `--max-mtp-ctx 65536` 是否真提速 | 改前后各跑同一批代表性请求，对比 `decode_time_seconds.sum / generation_tokens_total` 得出的 **tok/s**（当前基线 44.9）。再试 32768 取最优 |
| 3 | 每 token KV 精确字节 | 打满一个长会话后读 `mlx_cache_bytes`，除以该会话 token 数。我按结构算得 **24 KiB/token**，但 `indexer_*` 是否额外占 KV 存疑 |
| 4 | `--decode-attn-quant` 对本模型是否生效 | 传 `--no-decode-attn-quant` 前后对比 tok/s 与 `mlx_active_bytes`。若无变化 → 确认对 4-bit 出厂模型无效 |
| 5 | `--no-vision` 实省多少 | 开关前后对比 `memory_mb` 差值 |
| 6 | Splash `--max-memory` 合理值 | 启动 Splash 后实测其常驻，再定 24G/28G/32G |

---

## 9. Anything UNCLEAR（假设与存疑）

1. **`--ple-gpu` 增量到底是 +29.8 GiB 还是 ≈0**——只读手段无法证死（见 2.3）。
   已按**最坏情况（+29.8）**给出建议，因此结论偏保守；若实测证明是读法 B，
   该项可从「❌ 别动」上调为「P2 可选」，但**仍不建议在第二个模型下载期间开**。
2. **`memory_mb` 的单位**（94791）——若按 MiB 是 92.57 GiB，按十进制 MB 是 88.28 GiB。
   它与 `mlx_active_bytes`（88.81 GiB）差 0.6 %，**我按二者同源、取 88.81 GiB 作为主口径**；
   主理人实测的 91.3 GB 与之一致（略高，因含进程非 MLX 开销）。
3. **`vm_stat` 与进程常驻量对不上**：`vm_stat` 显示 wired 仅 5.12 GiB、active 39.16 GiB，
   与 88.81 GiB 的 MLX 常驻不一致。推测大部分是**文件页 mmap（可回收）而非 wired**，
   即「系统不可回收」这一前提可能不完全成立——但这需要 `footprint`/`ps` 取证，
   当前沙箱禁用了 `ps`，**标注存疑**。
4. **`indexer_*` 是否额外占用 KV**——`config.json` 有 `indexer_kv_heads:1 / indexer_head_dim:128 / indexer_budget:2048`，
   我未把它计入每 token KV，故 24 KiB/token 是**下限**。
5. **第二个模型 `...-iQ-MLX-4.7bpw` 正在下载**（观测时 01:08 仍在写 `.incomplete`）。
   它下载完若要加载，将在 128 GiB 上直接冲突（权重 70 GiB 级别）。**建议明确它的用途再决定去留。**
6. **`--mtp-head-kv-quant` 是否适用**：帮助原文点名 "qwen4 MTP head"，本模型是 `qwen4_exp`；
   相关性未确认，且该 flag 未进 App 菜单，无从设置。
7. **Splash 侧 `--host` 并非 1.2.1 新增**——任务书把它列为新增项，但实测 **Splash 1.1.0 已有 `--host` 与 `--allowed-host`**
   （`/opt/homebrew/bin/splash serve --help`）。`main.swift:2622` 的注释「1.2.0 起 splash 终于有自己的 --host」
   与事实不符。门控逻辑（`flagAvailable`）不受影响，仅注释需更正。
8. **`--prefill-decode-share` 是本次评审 v1 版的漏项**（由软件工程师独立复验发现，我已用 `comm` 差集复核确认）。
   教训：我 v1 用的是「按候选清单逐条 `grep -c`」，候选清单本身来自任务书，漏了清单外的项；
   正确做法是**对两版 `--help` 做全量差集**。已修正，复核命令见下节。
9. **`main.swift:851` 有一处与本报告结论直接冲突的断言**（详见第 10 节）——它不是我原报告点出的注释问题，
   而是一条**明确宣称「128GB 机器上开着基本无痛」**的判断，与本报告第 2.2 节的内存账推算矛盾。

---

## 10. App 侧（`main.swift`）与引擎事实不符清单

> 由架构评审发现 / 经软件工程师独立复验。均**不影响运行**（`flagAvailable` 门控逻辑正确），
> 但会误导维护与用户。按「是否已泄漏到 UI」排序。

### 10.1 新增项差集（复核命令，可复现）

```bash
/opt/homebrew/bin/mlx-serve --help 2>/dev/null \
  | grep -oE '^[[:space:]]+--[a-zA-Z0-9-]+' | sed 's/^[[:space:]]*//' | sort -u > /tmp/old.txt
/tmp/mlx-26101/mlx-serve-macos-arm64/mlx-serve --help 2>/dev/null \
  | grep -oE '^[[:space:]]+--[a-zA-Z0-9-]+' | sed 's/^[[:space:]]*//' | sort -u > /tmp/new.txt
comm -13 /tmp/old.txt /tmp/new.txt   # 新增
comm -23 /tmp/old.txt /tmp/new.txt   # 移除
```

结果：**新增 4 项**（`--mlx-gguf` / `--mtp-greedy-tail` / `--ple-gpu` / `--prefill-decode-share`），**移除 0 项**。
（flag 总数因提取口径不同会有 71→75 或 78→82 的差异，**差值一致**。）

### 10.2 待更正清单

| # | 位置 | 现状 | 问题 | 建议 |
|---|------|------|------|------|
| 1 | `main.swift:2783` | `onLabel: "Enabled — 26.10.1 default (lossy INT8/NVFP4 decode)"` | **用户可见文案**（非注释）。26.9.6 帮助原文同样写 `Default ON`，逐字一致 → 用户按 26.9.6 跑时菜单谎报版本号 | 改为 `"Enabled — engine default (lossy INT8/NVFP4 decode)"` |
| 2 | `main.swift:848` | `// ── mlx-serve 26.10.1 新增（全部走 flagAvailable 门控…）──` | 该块注释罩住 **14 个字段**，其中只有 `pleGpu` / `mtpGreedyTail` / `mlxGguf` 是 26.10.1 新增；**另 11 个 26.9.6 已有**（`mtpDepth`、`maxMtpCtx`、`noDecodeAttnQuant`、`ggufEngine`、`lanShare`、`lanDiscover`、`reasoningBudget`、`noPreventSleep`、`skipMemPreflight`、`osReserveGib`、`dspark`） | 拆成两段：`// ── 26.10.1 新增 ──` 只留 3 个；其余归到 `// ── 26.9.x 已有，同样走门控 ──` |
| 3 | **`main.swift:851`** | `/// 128GB 机器上开着基本无痛，正是这个模型包该吃的优化。` | **与本报告第 2.2 节矛盾**：当前 `mlx_active_bytes` 88.81 GiB，+29.80 → **118.62 GiB**，**超 `--max-resident-mem` 自动上限 97.28 GiB 达 21.3 GiB**。这条断言未见任何实测支撑 | 改为 `/// 代价是 +~30 GB 常驻：在已占用 ~89 GB 的 128GB 机器上会超出 resident cap，启用前必须实测 memory_mb / mlx_active_bytes。` |
| 4 | `main.swift:862` | `/// --no-decode-attn-quant：26.10.1 **默认开启**…` | 同 #1，26.9.6 已默认 ON，非 26.10.1 行为变化 | 改为「26.9.x 起即默认 ON，此处只提供显式关断口」 |
| 5 | `main.swift:634` | 同上的块注释版本 | 同 #4 | 同上 |
| 6 | `main.swift:2622` | `// 1.2.0 起 splash 终于有自己的 --host` | **Splash 1.1.0 已有** `--host` 与 `--allowed-host` | 改为「门控同其它项，1.1.0 起即有」 |
| 7 | `main.swift:2688` | `onLabel: "Keep PLE table on GPU (Qwen3.8-Flash-Next, +few% speed)"` | 未体现 +30 GB 代价 | 保留收益在前、补代价在后：`"Keep PLE table on GPU (+few% speed, but +~30 GB resident)"`（采纳软件工程师的措辞建议） |
| 8 | — | `--prefill-decode-share` | 26.10.1 新增，但 `main.swift` **全文零引用** | 是否纳入 UI 由主理人定；本报告建议**不纳入**（单用户负载零收益，默认即关） |
