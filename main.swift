//  Splash-MLX — macOS 菜单栏常驻控制器，可择一管理 Splash 或 mlx-serve 推理引擎：
//  选中哪个引擎，就显示哪个引擎的菜单，并把启停/参数作用于它。
//  纯 AppKit 实现（无窗口、无 Dock 图标）。
//  服务以独立会话（setsid）子进程方式拉起，菜单栏 App 退出后服务继续运行。
//  登录自启通过 SMAppService 注册本 App 实现（不走 launchd，避开本机 bootstrap 被拒的问题）。

import AppKit
import Foundation
import ServiceManagement

// MARK: - 常量与路径

// MARK: - 引擎二进制探测（不写死位置）

// ==== ENGINE-PATH-RESOLVE-BEGIN ====
/// 探测可执行文件在磁盘上的真实位置，**不假设任何包管理器或固定前缀**。
///
/// 为什么不能写死：brew 可能是 /opt/homebrew（Apple Silicon）或 /usr/local（Intel），
/// 也可能是自定义 prefix（~/homebrew 之类）；mlx-serve 既可能 brew 装，也可能是官方
/// 脚本自解压到 ~/.local；Splash 也可能从源码或 release 包直接跑。
///
/// 还有个隐蔽陷阱：本 App 作为登录项启动时，进程里的 PATH 通常只有
/// `/usr/bin:/bin:/usr/sbin`，**不含 /opt/homebrew/bin**，
/// 所以光扫 PATH 不够，必须额外补一组常见前缀，否则会「明明装了却显示未安装」。
///
/// 查找顺序：环境变量显式指定 → PATH 逐目录扫描 → 常见包管理器前缀（含 brew --prefix 实测值）→ 调用方补充目录。
/// 找不到返回 nil，由调用方决定降级行为。

/// 去重后的候选目录集合（惰性求值，整个进程生命周期只算一次）。
private let kSearchDirs: [String] = {
    var dirs: [String] = []
    func add(_ d: String) { if !d.isEmpty && !dirs.contains(d) { dirs.append(d) } }

    // 1) App 自身环境的 PATH（交互启动时带 shell 的完整 PATH，是最权威的信号）
    for p in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") { add(String(p)) }
    // 2) 常见包管理器前缀兜底（登录项场景的 PATH 很短，必须补）
    for p in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
              "/opt/pkg/bin", "/sw/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] { add(p) }
    // 3) 自定义 Homebrew prefix：直接问一次 brew，拿它自己承认的位置
    if let hp = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] { add(hp + "/bin") }
    for brew in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where FileManager.default.isExecutableFile(atPath: brew) {
        let r = run(brew, ["--prefix"])
        if r.status == 0 {
            let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.fileExists(atPath: p + "/bin") { add(p + "/bin") }
        }
        break
    }
    return dirs
}()

/// 路径是否指向「可执行的**普通文件**」。
/// 加固点一：目录带执行位是合法的，若只用 isExecutableFile 判断，
/// PATH 里一个同名的目录就会把真正的引擎顶掉，所以必须排除目录。
/// 加固点二：软链还要核实它指向的本体确实存在且可执行（半卸载留下的悬空软链会骗过 existance 检查）。
private func isRegularExecutable(_ path: String) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
    guard fm.isExecutableFile(atPath: path) else { return false }
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return fm.fileExists(atPath: real) && fm.isExecutableFile(atPath: real)
}

/// 在给定目录里收集**全部**同名可执行候选（按软链解析后的真实路径去重）。
private func candidateBinaries(_ name: String, in dirs: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for d in dirs {
        let p = (d as NSString).appendingPathComponent(name)
        guard isRegularExecutable(p) else { continue }
        let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        if seen.insert(real).inserted { out.append(p) }
    }
    return out
}

/// 探测引擎二进制：**不假设任何安装位置**，并且优先挑真正跑得起来的那个。
///
/// 顺序：环境变量显式指定 → 逐目录扫描收集全部候选 → 逐个跑 `--version` 验证（最多 3 个）。
/// 加固点三：PATH 里可能躺着同名残骸（半卸载的软链、别的项目放的同名脚本），
/// 只取第一个命中会挑到不能用的那个，所以多验证一步。
/// 验证全部失败时退回第一个命中，仍由上层按「未安装」处理，不改变既有行为。
///
/// - Parameters:
///   - name: 可执行文件名，如 `mlx-serve`
///   - envOverride: 允许用户强制指定的环境变量名，如 `MLX_SERVE_BIN`（可给绝对路径或裸命令名）
///   - extraDirs: 调用方补充的目录（如 mlx-serve 的自解压位置）
private func resolveEngineBinary(_ name: String, envOverride: String, extraDirs: [String] = []) -> String? {
    if let v = ProcessInfo.processInfo.environment[envOverride], !v.isEmpty {
        if v.contains("/") {
            if isRegularExecutable(v) { return v }
        } else if let hit = candidateBinaries(v, in: kSearchDirs).first {
            return hit
        }
    }
    var hits = candidateBinaries(name, in: kSearchDirs)
    hits.append(contentsOf: candidateBinaries(name, in: extraDirs))
    guard !hits.isEmpty else { return nil }
    for h in hits.prefix(3) where run(h, ["--version"]).status == 0 { return h }
    return hits.first
}

/// Splash 的位置：**任意位置**探测。结果按进程缓存，避免每次访问都重复 spawn 校验。
/// 实在找不到时仍退回旧常量，让上层按「未安装」处理，不改变既有行为。
private let kSplashBinResolved: String? = resolveEngineBinary("splash", envOverride: "SPLASH_BIN")
private var kSplashBin: String { kSplashBinResolved ?? "/opt/homebrew/bin/splash" }

/// mlx-serve 的位置：**任意位置**探测（brew 任意 prefix / 官方脚本自解压 / 用户自定义目录）。
/// extraDirs 保留自解压的历史位置，结果按进程缓存。
/// 找不到时退回一个不存在的路径，让上层按「未安装」处理，不改变既有行为。
private let kMlxBinResolved: String? = resolveEngineBinary("mlx-serve", envOverride: "MLX_SERVE_BIN",
    extraDirs: [homeURL().path + "/.local/lib/mlx-serve", homeURL().path + "/.local/bin"])
private var kMlxBin: String { kMlxBinResolved ?? (homeURL().path + "/.local/lib/mlx-serve/mlx-serve") }

/// 引擎进程的 PATH：把它自己所在目录放最前，再接全部探测目录。
/// 这样无论引擎装在哪个 prefix，它自己拉起的子进程都能找到同伴（splash 的 python 尤其依赖这个）。
private var engineLaunchPath: String {
    let binDir = (engineBin as NSString).deletingLastPathComponent
    return ([binDir] + kSearchDirs).joined(separator: ":")
}
// ==== ENGINE-PATH-RESOLVE-END ====

/// 当前选中的推理引擎。和 activePort 一样是运行期状态：
/// App 启动和 CLI 入口统一先 syncEngine(cfg.engine)，让下面所有静态方法
/// （二进制路径 / 参数探测 / 健康检查端点）都作用于正确的引擎。
enum Engine: String, Codable, CaseIterable {
    case splash
    case mlx

    var displayName: String {
        switch self {
        case .splash: return "Splash"
        case .mlx:    return "MLX Serve"
        }
    }

    var defaultPort: String {
        switch self {
        case .splash: return "8000"
        case .mlx:    return "11234"
        }
    }

    /// 健康检查端点。Splash 是 `/status`，mlx-serve 是 `/health`。
    var healthPath: String {
        switch self {
        case .splash: return "/status"
        case .mlx:    return "/health"
        }
    }

    /// 能力探测要跑的命令。Splash 的 serve 参数在 `serve --help` 里；
    /// mlx-serve 的 flag 全在顶层 `--help` 里（`serve` 只是子命令）。
    var helpArguments: [String] {
        switch self {
        case .splash: return ["serve", "--help"]
        case .mlx:    return ["--help"]
        }
    }

    /// 已安装版本查询的参数。两者都接受 --version，但输出格式不同：
    /// Splash → "Splash 1.0.1"（取最后一个 token）；mlx-serve → 首行 "mlx-serve 26.9.5"（取第二个）。
    var versionArguments: [String] { ["--version"] }
}

var activeEngine: Engine = .splash


/// 当前引擎的可执行文件
var engineBin: String {
    switch activeEngine {
    case .splash: return kSplashBin
    case .mlx:    return kMlxBin
    }
}

func syncEngine(_ e: Engine) { activeEngine = e }

// Splash 1.0.1 起支持 `--port`，可以有多个实例跑在不同端口上，
// 所以端口不能再是编译期常量。App 启动和 CLI 入口统一先 syncPort(cfg.port)，
// 让下面这些静态方法（lsof / curl / 拼 URL）探到正确的端口。
var activePort: String = "8000"
private var baseURL: String { "http://127.0.0.1:\(activePort)" }

func syncPort(_ p: String) { activePort = p.isEmpty ? activeEngine.defaultPort : p }

/// 把配置里的「引擎 + 该引擎的端口」一起同步到运行期状态。
/// **任何 Service 探测之前都必须调用** —— 否则会用错二进制、探错端口。
func applyConfig(_ cfg: Config) {
    syncEngine(cfg.engine)
    switch cfg.engine {
    case .splash:
        syncPort(cfg.port)
        activeModelDirOverride = cfg.modelDirSplash
    case .mlx:
        syncPort(cfg.mlx.port)
        activeModelDirOverride = cfg.mlx.modelDir
    }
}

// libproc 常量（直接给字面量，避免依赖 C 宏是否被 Swift 桥接）
private let kProcPidTBSDInfo: Int32 = 3   // PROC_PIDTBSDINFO（实测返回 136 = sizeof(proc_bsdinfo)）
// 纯信息行（不可点）的标记，--dump-menu 靠它区分"信息行"和"置灰的功能项"
private let kInfoTag = 99
// 参数子菜单用的 tag。全部具名，并且统一走 AppDelegate.flagForTag 这张
// tag → flag 映射表 —— "菜单置灰 / 拼命令行时过滤 / validateMenuItem 兜底"三处共用一份真相。
// 以前只硬编码了 kTagCacheDisk，因为当时只有它会因"引擎不认识"而置灰；
// 结果是 Max request size / Max image pixels 的值会被静默丢弃、菜单却仍显示可选。
private let kTagMaxMemory      = 1
private let kTagMaxContext     = 2
private let kTagPort           = 3
private let kTagMaxRequestSize = 4
private let kTagMaxImagePixels = 5
private let kTagCacheDisk      = 6
private let kTagAllowedHost    = 7
private let kTagWebUI          = 8
/// Splash 1.0.2 新增：服务级默认思考强度
private let kTagReasoningEffort = 9
/// Splash 1.1.0 新增四项
private let kTagKvFormat       = 31
private let kTagDraftModel     = 32
private let kTagRevision       = 33
private let kTagLanguageOnly   = 34

/// 受引擎能力约束的参数：tag → 引擎上对应的长选项。
///
/// **这是唯一真相来源** —— 菜单置灰（`gatedSubmenu`）、拼命令行时过滤（`Config.serveArguments`）、
/// `validateMenuItem` 兜底、`--engine-flags` 诊断，四处都查这张表。
/// 以前只有 cache-disk 一项做了全链路门控，导致 Max request size / Max image pixels 的配置值
/// 会被静默丢弃而菜单照旧可选；改参数时只改这里就不会再漏。
///
/// 不在表里的两项：
///   - Model：位置参数，永远要传
///   - API Key：通过环境变量 `SPLASH_API_KEY` 注入（`--api-key` 的 default 就是它），
///     环境变量不可能触发 argparse 退出，无需探测
private let kGatedParams: [(tag: Int, flag: String)] = [
    (kTagMaxMemory,      "--max-memory"),
    (kTagMaxContext,     "--max-context"),
    (kTagPort,           "--port"),
    (kTagMaxRequestSize, "--max-request-size"),
    (kTagMaxImagePixels, "--max-image-pixels"),
    (kTagCacheDisk,      "--max-cache-disk"),
    (kTagAllowedHost,    "--allowed-host"),
    (kTagWebUI,          "--no-webui"),
    (kTagReasoningEffort, "--default-reasoning-effort"),
    // Splash 1.1.0 新增：老版本引擎不认识，整组置灰而非传了起不来
    (kTagKvFormat,       "--kv-format"),
    (kTagDraftModel,     "--draft-model"),
    (kTagRevision,       "--revision"),
    (kTagLanguageOnly,   "--language-only"),
]

/// mlx-serve 专属参数。tag 从 11 起编号，和 Splash 的 1–8 严格分开，
/// 这样同一个 tag 不会在两个引擎下含义不同。
private let kTagMlxPort       = 11
private let kTagMlxHost       = 12
private let kTagMlxCtx        = 13
private let kTagMlxKvQuant    = 14
private let kTagMlxPrefixDisk = 15
private let kTagMlxResident   = 16
private let kTagMlxIdle       = 17
private let kTagMlxPrefixMem  = 21
private let kTagMlxPrefixEnt  = 22
private let kTagMlxResidentMem = 23
private let kTagMlxDrafter    = 18
private let kTagMlxVision     = 19
private let kTagMlxMetrics    = 20
private let kTagMlxMTP        = 24
private let kTagMlxPLD        = 25

/// MLX 版的能力约束表。语义和 kGatedParams 完全一致：
/// 引擎 `--help` 里没有这个 flag，整组就置灰、且不拼进命令行。
private let kMlxGatedParams: [(tag: Int, flag: String)] = [
    (kTagMlxPort,       "--port"),
    (kTagMlxHost,       "--host"),
    (kTagMlxCtx,        "--ctx-size"),
    (kTagMlxKvQuant,    "--kv-quant"),
    (kTagMlxPrefixDisk, "--prefix-cache-disk"),
    (kTagMlxPrefixMem,  "--prefix-cache-mem"),
    (kTagMlxPrefixEnt,  "--prefix-cache-entries"),
    (kTagMlxResident,   "--max-resident-models"),
    (kTagMlxResidentMem, "--max-resident-mem"),
    (kTagMlxIdle,       "--idle-evict-secs"),
    (kTagMlxDrafter,    "--drafter"),
    (kTagMlxVision,     "--no-vision"),
    (kTagMlxMetrics,    "--metrics"),
    (kTagMlxMTP,        "--mtp"),
    (kTagMlxPLD,        "--no-pld"),
]

private func flagForTag(_ tag: Int) -> String? {
    (kGatedParams + kMlxGatedParams).first { $0.tag == tag }?.flag
}

/// tag → 该参数依赖的**模型包自带部件**。和 flagForTag 同构，供 validateMenuItem 兜底。
/// 没登记 = 不依赖模型部件（只受引擎能力门控）。
private func capGateForTag(_ tag: Int) -> AppDelegate.ModelCapGate? {
    switch tag {
    case kTagMlxMTP:    return .mtp
    case kTagMlxVision: return .vision
    default:            return nil
    }
}
// sys/proc.h: SIDL=1 SRUN=2 SSLEEP=3 SSTOP=4 SZOMB=5
// 注意 SSTOP 是 4，写成 3(SSLEEP) 会导致暂停永远检测不到
private let kSSTOP: UInt32 = 4

/// 标记需要原地更新的菜单行（见 updateOpenMenuValues）
private let kKpiSpeed = "kpi:speed"
private let kKpiTtft  = "kpi:ttft"

private func homeURL() -> URL { FileManager.default.homeDirectoryForCurrentUser }

private var appSupportDir: URL { homeURL().appendingPathComponent("Library/Application Support/SplashMLX") }
private var configURL:     URL { appSupportDir.appendingPathComponent("config.json") }
private var pidURL:        URL { appSupportDir.appendingPathComponent("splash-mlx.pid") }
private var logOutPath: String { homeURL().appendingPathComponent("Library/Logs/splashmlx.out.log").path }
private var logErrPath: String { homeURL().appendingPathComponent("Library/Logs/splashmlx.err.log").path }

/// 用户手动指定的模型目录（空 = 自动发现）。
/// 下面的路径变量和 Service 一样是全局的、拿不到 AppDelegate 的 cfg，
/// 所以由 applyConfig 统一同步进来。每个引擎各存一个。
var activeModelDirOverride: String = ""

/// 从 splash 二进制反推出它的「程序根」——也就是 install/paths.py 里的 ROOT。
/// 布局是 `<X>/bin/splash` + `<X>/libexec/install/paths.py`，
/// 而 `ROOT = parents[1]` 正好是 `<X>/libexec`。
private func splashRootFromBinary() -> String? {
    let resolved = URL(fileURLWithPath: kSplashBin).resolvingSymlinksInPath().path
    var p = resolved
    for _ in 0..<2 { p = (p as NSString).deletingLastPathComponent }   // <X>/bin/splash → <X>
    for cand in [p + "/libexec", p] where
        FileManager.default.fileExists(atPath: cand + "/release.json") { return cand }
    return nil
}

/// Splash 的模型目录 —— **照抄 install/paths.py 的判定**，不写死：
///     PACKAGED = (ROOT)/release.json 存在？
///     MODELS   = ~/Library/Application Support/Splash/models   if PACKAGED（brew 装）
///              = <ROOT>/install/models                          else（源码/解包跑）
/// brew 安装是 PACKAGED；从源码或 release 包解压运行则完全不同，
/// 所以"每台电脑路径不一样"是真实存在的，必须按引擎自己的规则算。
private var splashModelsDir: URL {
    let userData = homeURL().appendingPathComponent("Library/Application Support/Splash/models")
    guard let root = splashRootFromBinary() else { return userData }   // 问不到就退回 brew 默认
    if FileManager.default.fileExists(atPath: root + "/release.json") { return userData }
    return URL(fileURLWithPath: root).appendingPathComponent("install/models")
}

/// mlx-serve 的模型库。默认 `~/.mlx-serve/models`，但它是 `--model-dir` 可改的，
/// 所以用户能手动覆盖（本机默认目录已软链到 /Users/mrt/Models）。
private var mlxModelsDir: URL {
    if !activeModelDirOverride.isEmpty { return URL(fileURLWithPath: activeModelDirOverride) }
    return homeURL().appendingPathComponent(".mlx-serve/models")
}

/// 当前引擎的模型目录（扫描 + Open models folder 用）
private var engineModelsDir: URL {
    if !activeModelDirOverride.isEmpty { return URL(fileURLWithPath: activeModelDirOverride) }
    switch activeEngine {
    case .splash: return splashModelsDir
    case .mlx:    return mlxModelsDir
    }
}

// ==== MODEL-CAPS-BEGIN ====
/// 模型包**自带**的能力（MTP 投机头 / 视觉塔）。和 `Service.flagAvailable` 是两条独立门控：
/// 引擎认不认某个 flag 问的是引擎 `--help`；模型有没有某个部件问的是**磁盘上的包**。
/// 两者都满足，菜单项才可用 —— 例如 `--mtp` 引擎认识、但模型没带头，开了也白开。
///
/// 探测依据（均在真机上对两种打包风格实测过）：
///   - MTP：① `mtp/weights.safetensors` sidecar（ddalcu 的 Qwen3.6 包）
///           ② 主分片里带 `.mtp.` 的张量（Qwen3.8-Flash-Next 把 MTP 并进主 shard，
///              形如 `language_model.mtp.*`，无 sidecar、config 里也没有 num_nextn_predict_layers）
///   - Vision：① `model-vision.safetensors` 独立文件 ② 主分片里的视觉张量
///              （`model.visual.*` 或 `vision_tower.*` 两种前缀都见过）③ config.json 的 `vision_config`
struct ModelCaps {
    var mtp: Bool = false
    var vision: Bool = false
}
/// 按路径缓存：菜单每次展开都重建，不能每次重读几十 MB 的 index.json。
private var modelCapsCache: [String: ModelCaps] = [:]

private func modelCaps(_ path: String) -> ModelCaps {
    if path.isEmpty { return ModelCaps() }
    if let hit = modelCapsCache[path] { return hit }
    let fm = FileManager.default
    var caps = ModelCaps()

    caps.mtp = fm.fileExists(atPath: (path as NSString).appendingPathComponent("mtp/weights.safetensors"))
    caps.vision = fm.fileExists(atPath: (path as NSString).appendingPathComponent("model-vision.safetensors"))

    // 主分片张量名：只读 index.json 的 key（不碰权重本体），失败就保持已有结论。
    let indexPath = (path as NSString).appendingPathComponent("model.safetensors.index.json")
    if let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let wm = root["weight_map"] as? [String: Any] {
        for k in wm.keys {
            if !caps.mtp, k.hasPrefix("mtp.") || k.contains(".mtp.") { caps.mtp = true }
            if !caps.vision, k.contains(".visual.") || k.hasPrefix("vision_tower.") || k.contains(".vision_tower.") { caps.vision = true }
            if caps.mtp && caps.vision { break }
        }
    }
    // config.json 的 vision_config 是最后一道保险（纯文本模型不会有它）
    if !caps.vision,
       let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).appendingPathComponent("config.json"))),
       let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       cfg["vision_config"] != nil {
        caps.vision = true
    }

    modelCapsCache[path] = caps
    return caps
}

/// 换模型/换引擎/改模型目录后调用，避免拿到上一个包的探测结果
func invalidateModelCapsCache() { modelCapsCache.removeAll() }
// ==== MODEL-CAPS-END ====

/// Splash 真正把模型包落盘的地方（HF 缓存约定）。
/// 顺序：HF_HUB_CACHE → $HF_HOME/hub → ~/.cache/huggingface/hub
private var hfHubDir: URL {
    let env = ProcessInfo.processInfo.environment
    if let h = env["HF_HUB_CACHE"], !h.isEmpty { return URL(fileURLWithPath: h) }
    if let h = env["HF_HOME"], !h.isEmpty {
        return URL(fileURLWithPath: h).appendingPathComponent("hub")
    }
    return homeURL().appendingPathComponent(".cache/huggingface/hub")
}

// MARK: - 配置

/// mlx-serve 的专属设置。
///
/// 和 Splash 的参数几乎不重叠（MLX 有 --kv-quant / --prefix-cache-disk / --drafter，
/// 没有 --max-cache-disk / --max-image-pixels 等），所以按"每引擎一套"分开存，
/// 切引擎时各自带出上次的配置，互不干扰。
struct MLXConfig: Codable {
    /// 模型路径或 `org/repo`。留空 = 不传 --model，走按需加载整个模型库
    var model: String = ""
    var port: String = "11234"
    /// 监听地址。默认只绑本机。
    ///
    /// **不能用引擎默认值**：mlx-serve 的默认是 `0.0.0.0`，它自己的启动日志就会警告
    /// "reachable by every device on the network this Mac is on"。Splash 那边默认是
    /// 127.0.0.1，两个引擎必须一致 —— 否则一换引擎，服务就悄悄暴露到局域网上去了。
    /// 想局域网共享就显式选 0.0.0.0（此时务必同时设 API Key）。
    var host: String = "127.0.0.1"
    var ctxSize: String = ""
    /// KV 缓存量化：off / 4 / 8
    var kvQuant: String = "off"
    /// 前缀缓存落 SSD，如 "10GB"。留空=关闭
    var prefixCacheDisk: String = ""
    /// 前缀缓存的**内存层**字节预算。引擎默认只有 2GB —— 大内存机器加大能显著提高命中率
    var prefixCacheMem: String = ""
    /// 前缀缓存的 LRU 条数上限（引擎默认 32）。和上面那个是同一缓存的两个维度
    var prefixCacheEntries: String = ""
    var maxResidentModels: String = ""
    /// 所有常驻模型的**总**内存上限。留空用引擎默认（wired limit 的 80%）
    var maxResidentMem: String = ""
    var idleEvictSecs: String = ""
    var noVision: Bool = false
    /// 已废弃：--metrics 现在强制打开（运行信息栏依赖它），菜单里不再暴露。
    /// 保留字段只是为了不破坏老配置文件的解码。
    var metrics: Bool = false
    var apiKey: String = ""
    /// Prompt Lookup Decoding（引擎默认开）
    var enablePLD: Bool = true
    /// MTP 投机解码，三态：
    ///   "auto" = 不传 flag，完全交给引擎默认（**MoE 模型引擎默认关 MTP**，dense 默认开）
    ///   "on"   = 显式 `--mtp`（MoE 想开必须这样，引擎不会自己开）
    ///   "off"  = 显式 `--no-mtp`
    /// 默认 "on"：菜单里既然给了这一项，用户的合理预期就是"我选了开，它就开"；
    /// 旧配置的 noMTP=true 会迁移成 "off"，noMTP=false 迁移成 "on"（见 init(from:)）。
    var mtpMode: String = "on"
    /// --drafter：Gemma 4 assistant 或 DFlash block-drafter 的目录
    var drafter: String = ""
    /// 手动指定模型目录（空 = 自动发现）。兜住 --model-dir 指到别处的情况
    var modelDir: String = ""

    init() {}

    /// 同 Config：任一字段缺失都退回默认，不整体丢弃
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model             = (try? c.decode(String.self, forKey: .model)) ?? model
        port              = (try? c.decode(String.self, forKey: .port)) ?? port
        // 空串是早期版本留下的"用引擎默认"，那等于 0.0.0.0 —— 迁移成只绑本机。
        // 光改字段默认值救不了已有配置（它们存的是显式的空串）。
        let rawHost = (try? c.decode(String.self, forKey: .host)) ?? host
        host = rawHost.isEmpty ? "127.0.0.1" : rawHost
        ctxSize           = (try? c.decode(String.self, forKey: .ctxSize)) ?? ctxSize
        kvQuant           = (try? c.decode(String.self, forKey: .kvQuant)) ?? kvQuant
        prefixCacheDisk   = (try? c.decode(String.self, forKey: .prefixCacheDisk)) ?? prefixCacheDisk
        prefixCacheMem    = (try? c.decode(String.self, forKey: .prefixCacheMem)) ?? prefixCacheMem
        prefixCacheEntries = (try? c.decode(String.self, forKey: .prefixCacheEntries)) ?? prefixCacheEntries
        maxResidentModels = (try? c.decode(String.self, forKey: .maxResidentModels)) ?? maxResidentModels
        maxResidentMem    = (try? c.decode(String.self, forKey: .maxResidentMem)) ?? maxResidentMem
        idleEvictSecs     = (try? c.decode(String.self, forKey: .idleEvictSecs)) ?? idleEvictSecs
        noVision          = (try? c.decode(Bool.self, forKey: .noVision)) ?? noVision
        metrics           = (try? c.decode(Bool.self, forKey: .metrics)) ?? metrics
        apiKey            = (try? c.decode(String.self, forKey: .apiKey)) ?? apiKey
        enablePLD         = (try? c.decode(Bool.self, forKey: .enablePLD)) ?? enablePLD
        // 老配置迁移：noMTP（旧版只有负向开关）→ mtpMode 三态。
        // 老配置显式存了 noMTP=true 就尊重它（"off"）；否则一律 "on" ——
        // 因为旧版根本没有"开 MTP"的能力，noMTP=false 只表示"没去关"，不代表用户想关。
        // 用独立的 LegacyKeys 容器读旧键：noMTP 已不是字段，不能进合成 CodingKeys，
        // 否则保存时会把废弃键写回配置文件。
        let lc = try decoder.container(keyedBy: LegacyKeys.self)
        if let legacy = try? lc.decode(Bool.self, forKey: .noMTP) {
            mtpMode = legacy ? "off" : "on"
        }
        mtpMode           = (try? c.decode(String.self, forKey: .mtpMode)) ?? mtpMode
        drafter           = (try? c.decode(String.self, forKey: .drafter)) ?? drafter
        modelDir          = (try? c.decode(String.self, forKey: .modelDir)) ?? modelDir
    }

    /// 已废弃、但老配置文件里仍可能出现的键。只用于**读**，绝不写回。
    private enum LegacyKeys: String, CodingKey {
        case noMTP
    }

    /// 拼出 mlx-serve 的启动参数。
    /// 和 Splash 一样：**每个可选 flag 都先问引擎认不认识**，
    /// 传了不认识的选项会 argparse 直接退出、服务起不来。
    /// 模型为空时用 `serve` 子命令（按需加载整个库），否则用 `--serve` 标志形式。
    /// mlx-serve 的 `--model` 收的是**目录路径**，不是库里的 `org/repo` 短名 ——
    /// 而模型清单给的恰恰是短名（`mlx-serve list` 的输出就是 `org/repo`）。
    /// 直接把短名喂给 `--model`，引擎会当成相对路径去找，启动即 `error: FileNotFound`。
    ///
    /// 所以：绝对路径原样用；短名解析成 `<模型目录>/<org>/<repo>`；
    /// 解析出来的目录不存在就退化成不带 --model 的 `serve`（按需加载），
    /// 这样至少服务能起来，而不是死在启动阶段。
    var resolvedModelPath: String {
        if model.isEmpty { return "" }
        if model.hasPrefix("/") { return model }
        let p = mlxModelsDir.appendingPathComponent(model).path
        return FileManager.default.fileExists(atPath: p) ? p : ""
    }

    var serveArguments: [String] {
        var a: [String] = []
        let path = resolvedModelPath
        if path.isEmpty {
            // 不带 --model：走 `serve` 的按需加载，请求里点名 org/repo 即可
            a = ["serve"]
        } else {
            a = ["--model", path, "--serve"]
        }
        if !port.isEmpty, port != Engine.mlx.defaultPort, Service.flagAvailable("--port") {
            a += ["--port", port]
        }
        if !host.isEmpty, Service.flagAvailable("--host") { a += ["--host", host] }
        if !ctxSize.isEmpty, Service.flagAvailable("--ctx-size") { a += ["--ctx-size", ctxSize] }
        if kvQuant != "off", Service.flagAvailable("--kv-quant") { a += ["--kv-quant", kvQuant] }
        if !prefixCacheDisk.isEmpty, Service.flagAvailable("--prefix-cache-disk") {
            a += ["--prefix-cache-disk", prefixCacheDisk]
        }
        if !prefixCacheMem.isEmpty, Service.flagAvailable("--prefix-cache-mem") {
            a += ["--prefix-cache-mem", prefixCacheMem]
        }
        if !prefixCacheEntries.isEmpty, Service.flagAvailable("--prefix-cache-entries") {
            a += ["--prefix-cache-entries", prefixCacheEntries]
        }
        if !maxResidentModels.isEmpty, Service.flagAvailable("--max-resident-models") {
            a += ["--max-resident-models", maxResidentModels]
        }
        if !maxResidentMem.isEmpty, Service.flagAvailable("--max-resident-mem") {
            a += ["--max-resident-mem", maxResidentMem]
        }
        if !idleEvictSecs.isEmpty, Service.flagAvailable("--idle-evict-secs") {
            a += ["--idle-evict-secs", idleEvictSecs]
        }
        if !drafter.isEmpty, Service.flagAvailable("--drafter") { a += ["--drafter", drafter] }
        if noVision, Service.flagAvailable("--no-vision") { a += ["--no-vision"] }
        // --metrics 强制打开，不出现在菜单里。
        // 原因：菜单的运行信息栏（tok/s、TTFT、内存）全部依赖 metrics 端点，
        // 让用户关掉它只会得到一排 0 —— 那就不是"可选项"，是必需品。
        if Service.flagAvailable("--metrics") { a += ["--metrics"] }
        if !enablePLD, Service.flagAvailable("--no-pld") { a += ["--no-pld"] }
        // MTP 三态：
        //   "on"   显式传 --mtp —— MoE 模型引擎**默认关** MTP，不显式传就永远开不上（旧版缺 --mtp 的根因）
        //   "off"  显式传 --no-mtp
        //   "auto" 不传，完全交给引擎默认（dense 默认开、MoE 默认关）
        // 双重门控：引擎要认识该 flag，且模型包里**真有 MTP 头**，否则静默丢弃 ——
        // 和菜单置灰同一语义，避免传了没用的 flag 或让不认识的 flag 把启动打挂。
        if mtpMode == "on", Service.flagAvailable("--mtp"), modelCaps(path).mtp { a += ["--mtp"] }
        if mtpMode == "off", Service.flagAvailable("--no-mtp") { a += ["--no-mtp"] }
        if !apiKey.isEmpty, Service.flagAvailable("--api-key") { a += ["--api-key", apiKey] }
        return a
    }
}

final class Config: Codable {
    /// 当前选中的引擎。两套配置各自独立保存，切换时带出各自的设置
    var engine: Engine = .splash
    /// mlx-serve 的专属设置（engine == .mlx 时生效）
    var mlx = MLXConfig()
    var model: String = "incoai/Qwen3.8-27B-Splash"
    var maxMemory: String = "auto"
    var maxContext: String = "auto"
    var apiKey: String = ""
    var allowedHost: String = ""
    /// HTTP 端口。Splash 1.0.1 起支持 --port，改这里就能跑多个实例
    var port: String = "8000"
    /// --max-request-size。留空=不传该参数，用 Splash 默认（1.0.1 起为 128M）
    var maxRequestSize: String = ""
    /// --max-image-pixels。留空=不传该参数，用引擎默认（4194304）
    var maxImagePixels: String = ""
    /// --max-cache-disk。留空=不传该参数（即关闭 SSD 缓存层）。
    /// 1.1.0 起为正式特性（1.0.x 及更早不认识，传了会让 argparse 直接退出、
    /// 服务起不来）—— 所以仍走 serveArguments 的 flagAvailable 过滤，老引擎上自动降级为不传。
    /// 实测注意：SSD 层不跨进程重启留存，重启后首次请求仍是 cached 0。
    var maxCacheDisk: String = ""
    /// 手动指定 Splash 的模型目录（空 = 按 install/paths.py 的规则自动判定）
    var modelDirSplash: String = ""
    /// Splash 1.0.2：服务级默认思考强度（空 = 引擎/模型模板的默认）
    var reasoningEffort: String = ""
    /// Splash 1.1.0 新增：--kv-format（int8 / bf16）。留空 = 引擎默认 int8
    var kvFormat: String = ""
    /// Splash 1.1.0 新增：--draft-model，覆盖引擎自动选的 DFlash2 仓库/目录（空 = 自动）
    var draftModel: String = ""
    /// Splash 1.1.0 新增：--revision，模型分支/tag/commit（空 = 仓库默认）
    var revision: String = ""
    /// Splash 1.1.0 新增：--language-only，跳过视觉准备与加载
    var languageOnly: Bool = false
    var noWebUI: Bool = false
    var loginItem: Bool = false
    var autoStartOnLaunch: Bool = false
    /// 菜单栏图标右侧是否显示模型名
    var showModelName: Bool = true
    /// 菜单栏是否显示实时速度（只在有速率时出现，空闲时自动消失）
    var showSpeed: Bool = true

    /// 手写解码：任一字段缺失（老版本配置文件）都退回默认值，不整体丢弃配置
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 引擎选择：老配置文件没有这个字段，退回 splash（保持既有行为不变）
        engine            = (try? c.decode(Engine.self, forKey: .engine)) ?? engine
        mlx               = (try? c.decode(MLXConfig.self, forKey: .mlx)) ?? mlx
        model             = (try? c.decode(String.self, forKey: .model)) ?? model
        maxMemory         = (try? c.decode(String.self, forKey: .maxMemory)) ?? maxMemory
        maxContext        = (try? c.decode(String.self, forKey: .maxContext)) ?? maxContext
        apiKey            = (try? c.decode(String.self, forKey: .apiKey)) ?? apiKey
        allowedHost       = (try? c.decode(String.self, forKey: .allowedHost)) ?? allowedHost
        port              = (try? c.decode(String.self, forKey: .port)) ?? port
        maxRequestSize    = (try? c.decode(String.self, forKey: .maxRequestSize)) ?? maxRequestSize
        maxImagePixels    = (try? c.decode(String.self, forKey: .maxImagePixels)) ?? maxImagePixels
        maxCacheDisk      = (try? c.decode(String.self, forKey: .maxCacheDisk)) ?? maxCacheDisk
        modelDirSplash    = (try? c.decode(String.self, forKey: .modelDirSplash)) ?? modelDirSplash
        reasoningEffort   = (try? c.decode(String.self, forKey: .reasoningEffort)) ?? reasoningEffort
        kvFormat          = (try? c.decode(String.self, forKey: .kvFormat)) ?? kvFormat
        draftModel        = (try? c.decode(String.self, forKey: .draftModel)) ?? draftModel
        revision          = (try? c.decode(String.self, forKey: .revision)) ?? revision
        languageOnly      = (try? c.decode(Bool.self, forKey: .languageOnly)) ?? languageOnly
        noWebUI           = (try? c.decode(Bool.self, forKey: .noWebUI)) ?? noWebUI
        loginItem         = (try? c.decode(Bool.self, forKey: .loginItem)) ?? loginItem
        autoStartOnLaunch = (try? c.decode(Bool.self, forKey: .autoStartOnLaunch)) ?? autoStartOnLaunch
        showModelName     = (try? c.decode(Bool.self, forKey: .showModelName)) ?? showModelName
        showSpeed         = (try? c.decode(Bool.self, forKey: .showSpeed)) ?? showSpeed
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        return Config()
    }

    func save() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: configURL) }
    }

    /// 拼出 `splash serve` 的参数。
    ///
    /// **除了 `--model`，其余每一个 flag 都先问引擎认不认识。** 传一个 argparse 不认识的选项，
    /// splash 会在解析阶段就退出（`unrecognized arguments`），服务根本起不来 ——
    /// 比"参数被忽略"严重得多。典型场景：SSD 缓存层（--max-cache-disk）在 1.1.0 才转正，
    /// 用户在 1.1.0 上把它存进配置，之后回退到 1.0.x 就会踩到。
    ///
    /// 这里必须和 `gatedSubmenu` 的置灰范围**完全一致**：菜单里灰掉的项如果还被拼进命令行，
    /// 就不是"参数失效"而是"服务起不来"了。
    /// 探测失败时 `flagAvailable` 返回 true（fail open），参数照旧传 —— 不能因为问不到引擎
    /// 就把用户存好的配置悄悄丢掉。
    var serveArguments: [String] {
        switch engine {
        case .splash: return splashServeArguments
        case .mlx:    return mlx.serveArguments
        }
    }

    private var splashServeArguments: [String] {
        var a = ["serve", "--model", model]
        if Service.flagAvailable("--max-memory")  { a += ["--max-memory", maxMemory] }
        if Service.flagAvailable("--max-context") { a += ["--max-context", maxContext] }
        // 端口只在非默认时才显式传，这样旧的 Splash（1.0，无此参数）也能照常跑
        if !port.isEmpty && port != "8000", Service.flagAvailable("--port") {
            a += ["--port", port]
        }
        if !maxRequestSize.isEmpty, Service.flagAvailable("--max-request-size") {
            a += ["--max-request-size", maxRequestSize]
        }
        if !maxImagePixels.isEmpty, Service.flagAvailable("--max-image-pixels") {
            a += ["--max-image-pixels", maxImagePixels]
        }
        if !maxCacheDisk.isEmpty, Service.flagAvailable("--max-cache-disk") {
            a += ["--max-cache-disk", maxCacheDisk]
        }
        if !allowedHost.isEmpty, Service.flagAvailable("--allowed-host") {
            a += ["--allowed-host", allowedHost]
        }
        if noWebUI, Service.flagAvailable("--no-webui") { a += ["--no-webui"] }
        // 思考强度：直接决定输出前的思考量，是最影响"手感快慢"的一项
        // （none 基本不思考 → 明显更快）。留空则用引擎/模型模板的默认值。
        if !reasoningEffort.isEmpty, Service.flagAvailable("--default-reasoning-effort") {
            a += ["--default-reasoning-effort", reasoningEffort]
        }
        // ── Splash 1.1.0 新增的四项。同样逐项问引擎认不认识：
        // 老版本 splash 不认识它们，传了会 argparse 直接退出，所以必须过滤。
        if !kvFormat.isEmpty, Service.flagAvailable("--kv-format") {
            a += ["--kv-format", kvFormat]
        }
        if !draftModel.isEmpty, Service.flagAvailable("--draft-model") {
            a += ["--draft-model", draftModel]
        }
        if !revision.isEmpty, Service.flagAvailable("--revision") {
            a += ["--revision", revision]
        }
        if languageOnly, Service.flagAvailable("--language-only") { a += ["--language-only"] }
        return a
    }
}

// MARK: - 工具

@discardableResult
private func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (-1, "", error.localizedDescription) }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

/// 以新会话（setsid）拉起进程：脱离本 App 的进程组，App 退出后仍存活，
/// 且 pgid == pid，便于整组（server.py + engine）一次性 kill。
private func spawnDetached(_ argv: [String], env: [String: String]) -> pid_t? {
    var pid: pid_t = 0

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 1, logOutPath,
                                     O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, logErrPath,
                                     O_WRONLY | O_CREAT | O_APPEND, 0o644)

    let argvPtr = argv.map { strdup($0) } + [nil]
    let envPtr  = env.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]

    let rc = posix_spawn(&pid, argv[0], &actions, &attr, argvPtr, envPtr)
    for p in argvPtr { free(p) }
    for p in envPtr  { free(p) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    return rc == 0 ? pid : nil
}

// MARK: - 服务状态

struct Status {
    var up = false
    var maxContext = 0
    var tps = 0.0
    var accept = 0.0
    var ttftP50 = 0.0
    var memoryPressure = ""
    var residentGB = 0.0
    var deviceName = ""

    // ── mlx-serve 侧多出来的指标（Splash 没有对应项，那边保持默认 0）
    /// /metrics.json 是否拿到了数据。
    /// **服务活着 ≠ 有指标**：mlx-serve 的 metrics 要代理到 model worker，
    /// 模型没加载完时它返回的是纯文本错误，这时菜单必须说"加载中"而不是显示 0。
    var metricsAvailable = false
    var gpuPct = 0.0
    var reqRunning = 0
    var reqWaiting = 0
    /// tps 是「上次实测值」而不是本窗口实测时的年龄（秒）。-1 = 本窗口刚测到，是新鲜的。
    /// mlx-serve 的计数器是累计量，5 秒窗口只能"撞上"生成过程 ——
    /// 实测 900 token 的生成只占 1 个窗口，11 个窗口里 10 个算出来是 0。
    /// 所以必须沿用上次实测值并标明年龄，否则菜单几乎永远显示 0。
    var tpsStaleSeconds: Double = -1
}

/// 进程内 HTTP GET（同步包装 URLSession），返回 (状态, 响应体)。
///
/// 用来替代 `curl` 子进程：**每次轮询 fork+exec 一个 curl 才是开销的大头**
/// （秒级轮询下约 1-3% CPU），而请求本身只是本机 loopback socket，微秒级。
/// 状态码语义与原来的 curl 对齐：HTTP 200 → 0，其余原样返回。
///
/// 注意 `connectionProxyDictionary = [:]`：原来 curl 用 `--noproxy *` 绕过公司代理，
/// 这里必须同样显式禁用，否则 127.0.0.1 的请求可能被代理拦走。
private let kHTTP: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 2
    c.timeoutIntervalForResource = 3
    return URLSession(configuration: c)
}()

private func httpGet(_ url: String, timeout: TimeInterval = 2) -> (status: Int32, out: String) {
    guard let u = URL(string: url) else { return (-1, "") }
    var req = URLRequest(url: u)
    req.timeoutInterval = timeout
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = -1
    var body = ""
    kHTTP.dataTask(with: req) { data, resp, _ in
        if let h = resp as? HTTPURLResponse { code = Int32(h.statusCode) }
        if let d = data { body = String(data: d, encoding: .utf8) ?? "" }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + timeout + 0.5) == .timedOut { return (-1, "") }
    return (code == 200 ? 0 : code, body)
}

/// 读进程累计 CPU 时间（纳秒）。**纯系统调用** —— 不联网、不起进程，
/// 所以可以每秒都做，用来判断引擎忙不忙。
private func cpuNanos(of pid: pid_t) -> UInt64? {
    var info = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.size
    let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
    guard r == Int32(size) else { return nil }
    return info.pti_total_user + info.pti_total_system
}

/// JSONSerialization 给的是 NSNumber，`as? Double` 对整数值不可靠，统一走这里
private func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return nil
}

// MARK: - 服务控制器

enum Service {

    /// 版本探测的两个小缓存：运行中版本按 pid 缓存，已安装版本只查一次
    private static var versionCache: (pid: pid_t, version: String?)?
    private static var installedCache: String?
    private static var installedQueried = false

    static var recordedPID: pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .newlines),
              let p = pid_t(s) else { return nil }
        return p
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// 本 App 托管中（pid 文件有效且进程存活）
    static var managed: Bool {
        guard let p = recordedPID else { return false }
        return isAlive(p)
    }

    /// 是否处于暂停（SIGSTOP 冻结）状态
    /// 走 libproc 直接读 proc_bsdinfo.pbi_status，不 spawn /bin/ps —— 外部命令在受限
    /// 执行环境里可能被程序策略拒绝（实测 ps 会 "operation not permitted"），那样会误判成未暂停。
    static var paused: Bool {
        guard let p = recordedPID, isAlive(p) else { return false }
        var info = proc_bsdinfo()
        let n = proc_pidinfo(p, kProcPidTBSDInfo, 0,
                             &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        if n == Int32(MemoryLayout<proc_bsdinfo>.stride) {
            return info.pbi_status == kSSTOP
        }
        // 极少数情况下 libproc 读不到，退回解析 ps
        let r = run("/bin/ps", ["-o", "stat=", "-p", "\(p)"])
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T")
    }

    /// 暂停：向整个进程组发 SIGSTOP（进程冻结，显存/内存仍占用，但不再吃 CPU）
    static func pause() -> String {
        guard let p = recordedPID, isAlive(p) else { return "no managed process to pause" }
        if paused { return "already paused" }
        kill(-p, SIGSTOP)
        kill(p, SIGSTOP)
        return "paused pid=\(p)"
    }

    /// 继续：SIGCONT
    static func resume() -> String {
        guard let p = recordedPID, isAlive(p) else { return "no managed process to resume" }
        kill(-p, SIGCONT)
        kill(p, SIGCONT)
        return "resumed pid=\(p)"
    }

    /// 占用当前配置端口的 pid 列表
    static func pidsOnPort() -> [pid_t] {
        let r = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(activePort)", "-sTCP:LISTEN", "-t"])
        return r.out.split(separator: "\n").compactMap { pid_t($0) }
    }

    // MARK: 版本探测

    /// 「正在运行」的版本。`/status` 不提供版本字段（schema 5 里只有 schema_version），
    /// 所以从进程可执行文件路径反推：托管进程跑的是
    /// `…/Cellar/splash/<ver>/libexec/python/bin/python3.13`（brew 装）
    /// 或 `…/splash-<ver>-arm64-macos26/…`（release 包解包后手动跑）。
    static func runningVersion() -> String? {
        invalidateCachesIfEngineChanged()
        guard let pid = recordedPID, isAlive(pid) else { return nil }
        if let cached = versionCache, cached.pid == pid { return cached.version }
        let r = run("/usr/sbin/lsof", ["-p", String(pid), "-a", "-d", "txt", "-Fn"])
        var found: String?
        for line in r.out.split(separator: "\n") where line.hasPrefix("n") {
            if let v = versionFromPath(String(line.dropFirst())) { found = v; break }
        }
        versionCache = (pid, found)
        return found
    }

    /// 从可执行文件路径里抽版本号。
    /// 逐个候选扫描而不是只取第一处匹配 —— 因为解包目录常被放在名字里也带 "splash-" 的
    /// 父目录下（如 /tmp/splash-test/v10/splash-1.0-arm64-macos26/…），只取第一处会解析失败。
    static func versionFromPath(_ path: String) -> String? {
        var idx = path.startIndex
        while let r = path.range(of: "/Cellar/splash/", range: idx..<path.endIndex) {
            let v = path[r.upperBound...].prefix { $0 != "/" }
            if v.first?.isNumber == true { return String(v) }
            idx = r.upperBound
        }
        idx = path.startIndex
        while let r = path.range(of: "/splash-", range: idx..<path.endIndex) {
            let v = path[r.upperBound...].prefix { $0.isNumber || $0 == "." }
            if v.contains(where: \.isNumber) { return String(v) }
            idx = r.upperBound
        }
        return nil
    }

    /// 「已安装」的版本（`splash --version` → "Splash 1.0.1"）。
    /// 会拉起一个 Python，耗时约 0.3–1s，所以只查一次然后缓存。
    static func installedVersion() -> String? {
        invalidateCachesIfEngineChanged()
        if installedQueried { return installedCache }
        installedQueried = true
        let r = run(engineBin, activeEngine.versionArguments)
        let raw = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 {
            switch activeEngine {
            case .splash:
                // "Splash 1.0.1" → 取最后一个 token
                if let last = raw.split(separator: " ").last, last.contains(where: \.isNumber) {
                    installedCache = String(last)
                }
            case .mlx:
                // 输出是多行：先有一行 `[mem] …` 调试行，然后是 `mlx-serve 26.9.5`、
                // `mlx 0.32.2`… 直接取"最后一个 token"会拿到 `ds4 unknown` 里的 unknown，
                // 所以定位以 "mlx-serve" 开头的那一行，取第二个 token。
                for line in raw.split(separator: "\n") {
                    let t = line.split(separator: " ")
                    if t.first == "mlx-serve", t.count >= 2 {
                        installedCache = String(t[1]); break
                    }
                }
            }
        }
        return installedCache
    }

    // MARK: 引擎能力探测

    /// 引擎身份指纹 —— 用来判断"引擎被换过了"。
    /// brew 的 bin 是指向 Cellar 版本的符号链接，读字符串即可、不用起进程，
    /// 所以每次建菜单都能安全调用。附上解析后二进制的 mtime，
    /// 兜住"同版本原地重装"这种链接目标不变的情况。
    private static func engineFingerprint() -> String {
        let bin = engineBin
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: bin)) ?? bin
        let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(link)|\(resolved)|\(Int(mtime))"
    }

    private static var cachedFingerprint: String?

    /// 引擎换了（升级 / 降级 / 重装）就让所有探测缓存失效。
    /// 没有这一步，用户装完支持 --max-cache-disk 的引擎还得重启 Splash-MLX
    /// 那一项才会从置灰变可用 —— 而"装上就自动可用"正是这里承诺的行为。
    private static func invalidateCachesIfEngineChanged() {
        let fp = engineFingerprint()
        if cachedFingerprint == fp { return }
        cachedFingerprint = fp
        serveFlagsCache = nil
        installedQueried = false
        installedCache = nil
        versionCache = nil
    }

    /// `splash serve --help` 里出现的所有长选项名（形如 "--max-cache-disk"）。
    /// 只探测一次并缓存 —— 同样要 spawn 一个 Python。
    private static var serveFlagsCache: Set<String>?

    static func serveFlags() -> Set<String> {
        invalidateCachesIfEngineChanged()
        if let c = serveFlagsCache { return c }
        let r = run(engineBin, activeEngine.helpArguments)
        let text = r.out + r.err
        var flags: Set<String> = []
        var i = text.startIndex
        while let rng = text.range(of: "--", range: i..<text.endIndex) {
            let name = text[rng.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            if name.count >= 2 { flags.insert("--" + name) }
            i = rng.upperBound
        }
        serveFlagsCache = flags
        return flags
    }

    /// 引擎是否认识某个可选 flag。
    /// 探测失败（拿到空集，例如 splash 不在 PATH）时返回 true：
    /// 宁可让菜单项保持可用，也不要误判成"不支持"、把用户存好的配置悄悄丢掉。
    /// `serve --help` 不需要模型，所以服务没在跑时也能安全调用。
    static func flagAvailable(_ flag: String) -> Bool {
        let known = serveFlags()
        return known.isEmpty ? true : known.contains(flag)
    }

    /// 探测是否成功（用于区分"引擎确实不支持"和"根本问不到引擎"）
    static var flagsProbed: Bool { !serveFlags().isEmpty }

    static func start(cfg: Config) -> String {
        if managed { return "already running (pid \(recordedPID!))" }
        // 端口已被别人占着时拒绝启动：否则会 spawn 出第二个进程、绑定 8000 失败，
        // pid 文件却被新 pid 覆盖，造成"显示托管中、实际服务是死的"的错乱状态。
        if status().up {
            let who = pidsOnPort().map(String.init).joined(separator: ",")
            return "refusing to start: port \(activePort) is held by an external process (pid \(who)). Stop it first, or use --takeover"
        }
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: logErrPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logOutPath, contents: nil)
        FileManager.default.createFile(atPath: logErrPath, contents: nil)

        // 加固点四：启动前先确认引擎真的可执行，给出人话报错，
        // 而不是让 posix_spawn 失败后抛一句看不懂的 errno。
        guard FileManager.default.isExecutableFile(atPath: engineBin) else {
            let hint = activeEngine == .mlx ? "MLX_SERVE_BIN" : "SPLASH_BIN"
            return "engine not found: 未找到 \(activeEngine.displayName) 的可执行文件"
                 + "（已扫 PATH、常见包管理器前缀与 \(hint)，均无可用二进制）"
        }
        // PATH 由探测结果动态拼出（引擎目录在最前），不再写死 /opt/homebrew，
        // 否则装在其它 prefix 的引擎，其子进程会找不到配套命令。
        var env = ["PATH": engineLaunchPath,
                   "HOME": homeURL().path]
        // Splash 的 `--api-key` 默认值就是 SPLASH_API_KEY 环境变量，所以用环境变量注入；
        // mlx-serve 没有对应环境变量，走 --api-key 标志（已拼进 serveArguments）。
        if activeEngine == .splash, !cfg.apiKey.isEmpty { env["SPLASH_API_KEY"] = cfg.apiKey }

        let argv = [engineBin] + cfg.serveArguments
        guard let pid = spawnDetached(argv, env: env) else {
            return "start failed: posix_spawn returned \(errno)"
        }
        try? String(pid).write(to: pidURL, atomically: true, encoding: .utf8)
        return "started pid=\(pid)"
    }

    static func stop() -> String {
        var killed: [pid_t] = []
        if let pid = recordedPID {
            kill(-pid, SIGTERM)          // 整组：server.py + serve-native engine
            kill(pid, SIGTERM)
            killed.append(pid)
        }
        Thread.sleep(forTimeInterval: 2.0)
        if let pid = recordedPID, isAlive(pid) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        for p in pidsOnPort() where !killed.contains(p) {
            kill(p, SIGTERM)
            killed.append(p)
        }
        Thread.sleep(forTimeInterval: 1.0)
        for p in pidsOnPort() { kill(p, SIGKILL) }
        try? FileManager.default.removeItem(at: pidURL)
        return killed.isEmpty ? "nothing to stop" : "stopped pid=\(killed.map(String.init).joined(separator: ","))"
    }

    static func restart(cfg: Config) -> String {
        _ = stop()
        return start(cfg: cfg)
    }

    /// mlx-serve 的 `generation_tokens_total` 是**累计**值，没有现成的实时速率，
    /// 只能拿相邻两次采样求差。这是唯一需要跨调用保存的状态。
    /// 上一次采样的 (输出 token 累计, 实际解码耗时累计)。
    /// 用**解码耗时**而不是墙上时间做分母 —— 详见 status() 里的说明。
    /// 上一次采样的 (输出token累计, 解码耗时累计, 实时token累计)。
    /// 两个 token 来源各有盲区，需要同时跟踪：见 status() 里的说明。
    private static var lastMLXSample: (t: Date, outTokens: Double, decodeSeconds: Double, live: Double)?
    /// 最近一次真正测到的非零速率。窗口一旦没撞上生成就会返回 0，
    /// 靠它把上一个真实值留住，并在菜单里标出"多久之前测的"。
    private static var lastMLXRate: (value: Double, at: Date)?
    /// 超过这个年龄就不再显示速率（说明确实空闲了）
    /// 生成结束后速率还保留多久（用户指定 2 秒）。
    private static let kMLXRateMaxAge: Double = 2
    /// live 计数的历史采样（约 6 秒窗口）。
    /// `generation_tokens_live` 的更新粒度约 1.6 秒 —— 用 1 秒轮询窗口算差值，
    /// 会一会儿是 0、一会儿一次吞掉一整批（实测显示 273、367，而真实只有 184）。
    /// 所以拿 ~2.5 秒前的采样做基线，跨过它的更新粒度，得到平滑且准确的速率。
    private static var mlxLiveHistory: [(t: Date, v: Double)] = []

    /// 状态探测。已暂停（进程冻结）时直接短路，避免每次轮询都等 curl 超时。
    static func status() -> Status {
        var s = Status()
        if paused { return s }
        if activeEngine == .mlx {
            // 顺序很关键：**先取 /metrics.json**。它能解析出 gauges/counters 就同时证明了
            // "服务活着"和"有数据"，于是这次轮询只需 1 个进程而不是 2 个
            // —— 进程创建才是轮询开销的大头，这一下砍掉一半。
            let m = httpGet(baseURL + "/metrics.json")
            // 这里有两种"没数据"的形态，必须都挡住：
            //   1) 没开 --metrics  → 返回合法 JSON `{"error":"metrics not enabled …"}`
            //   2) 模型没加载完    → 返回纯文本 `upstream connect failed: …`
            // 只看"能不能解析成 JSON"会把第 1 种误判成有数据（解析成功、然后全 0）。
            guard m.status == 0, let md = m.out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
                  obj["gauges"] != nil || obj["counters"] != nil
            else {
                // 拿不到 metrics（模型加载中 / 未开 metrics）：退回 /health 只判存活，
                // 这样"引擎在跑但模型未就绪"仍能被正确识别
                let h = httpGet(baseURL + "/health")
                if h.status == 0, !h.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    s.up = true
                }
                return s
            }
            s.up = true          // metrics 拿到了 —— 服务必然活着
            s.metricsAvailable = true
            let g = (obj["gauges"] as? [String: Any]) ?? [:]
            if let mb = num(g["memory_mb"]) { s.residentGB = mb / 1024.0 }
            if let gp = num(g["gpu_utilization_pct"]) { s.gpuPct = gp }
            if let n = num(g["requests_running"]) { s.reqRunning = Int(n) }
            if let n = num(g["requests_waiting"]) { s.reqWaiting = Int(n) }
            // TTFT：直方图只给 count/sum，取平均。
            // 注意 Splash 报的是 p50、这里算的是均值 —— 所以菜单里两边都只写 "TTFT"，不写 p50
            if let h = obj["histograms"] as? [String: Any],
               let tt = h["time_to_first_token_seconds"] as? [String: Any],
               let cnt = num(tt["count"]), cnt > 0, let sum = num(tt["sum"]) {
                s.ttftP50 = sum / cnt * 1000.0
            }
            // 实时解码速度 = Δ(累计生成 token) / Δ(真实经过时间)
            // 速率来源用 gauges.generation_tokens_live，**不要用直方图**。
            //
            // 踩过的坑：histograms.output_tokens.sum 只在**请求完成时**才累加 ——
            // 实测长生成期间它纹丝不动（3379 → 3379 → 3379），直到请求结束才跳到 4279。
            // 而 WorkBuddy 的 agent 生成动辄几十秒，于是整个生成过程都算不出速率，
            // 菜单一直显示 idle（用户看到的正是这个）。
            //
            // generation_tokens_live 是**包含进行中请求**的实时累计量
            // （实测生成中持续增长：3403 → 3761 → 4118）。
            // 生成是连续的、会铺满整个轮询窗口，所以这里用墙上时间做分母不会被摊薄
            // —— 被摊薄的是"短请求落在长窗口里"那种情况，长生成不适用。
            let hh = (obj["histograms"] as? [String: Any]) ?? [:]
            let outSum = num((hh["output_tokens"] as? [String: Any])?["sum"]) ?? 0
            let decSum = num((hh["decode_time_seconds"] as? [String: Any])?["sum"]) ?? 0
            if let live = num(g["generation_tokens_live"]) {
                let now = Date()
                // **每次采样都记**，空闲时也记 —— 否则生成刚开始时历史是空的，
                // 要等到第 2 次采样才有基线，首次出数就慢了一拍。
                mlxLiveHistory.append((now, live))
                mlxLiveHistory.removeAll { now.timeIntervalSince($0.t) > 6 }
                if let prev = lastMLXSample {
                    var rate: Double?
                    let dOut = outSum - prev.outTokens
                    let dDec = decSum - prev.decodeSeconds
                    if dOut > 0, dDec > 0.05 {
                        // ① 直方图：窗口内有请求**完成**时最精确（分母是真实解码耗时，不摊薄）
                        rate = dOut / dDec
                    } else if s.reqRunning > 0 {
                        // ② 实时累计量：长生成期间直方图一动不动，只有它可靠。
                        //
                        // 必须用 requests_running 把这条路径限制在"确实有请求在跑"时：
                        // 生成结束后 live 计数就不动了，再拿它算差值会得到一路衰减的假值
                        // （实测 123 → 48 → …），而这时正确的做法是保留上一个准确值。
                        //    基线要往前取 ~2.5 秒 —— 它的更新粒度约 1.6 秒，
                        //    用 1 秒窗口会一次吞掉一整批，算出来虚高（实测 367 vs 真实 184）。
                        // 优先取 ~2.5 秒前的基线（跨过计数器约 1.6 秒的刷新粒度），
                        // 但刚进入生成时还没有那么早的样本 —— 这时退回用最老的样本，
                        // 宁可数字略糙也要尽早出数（原来越是等基线越显得"迟了 2-3 秒"）。
                        let base = mlxLiveHistory.first { now.timeIntervalSince($0.t) >= 2.5 }
                                ?? mlxLiveHistory.first
                        if let base = base, base.t < now {
                            let dLive = live - base.v
                            let dt = now.timeIntervalSince(base.t)
                            if dLive > 0, dt > 0 { rate = dLive / dt }
                        }
                    }
                    if let r = rate, r > 0 {
                        lastMLXRate = (r, now)
                        s.tps = r
                    }
                    lastMLXSample = (now, outSum, decSum, live)
                } else {
                    lastMLXSample = (now, outSum, decSum, live)   // 第一次采样只记录基线
                }
                // 本窗口没生成（绝大多数窗口都如此）：沿用上次实测值并标出年龄，
                // 超过 kMLXRateMaxAge 才当真空闲。否则菜单几乎永远显示 0，
                // 用户根本没机会看到真实的 tok/s。
                if s.tps == 0, let lr = lastMLXRate {
                    let age = now.timeIntervalSince(lr.at)
                    if age <= kMLXRateMaxAge {
                        s.tps = lr.value
                        s.tpsStaleSeconds = age
                    }
                }
            }
            return s
        }
        mlxLiveHistory.removeAll()
        lastMLXSample = nil   // 换回 Splash 时清掉，避免下次切回来算出离谱的差值
        // Splash 的 /status 既报健康也报数据，同一个端点，所以这次请求在 Splash 路径下才需要
        let r = httpGet(baseURL + activeEngine.healthPath)
        guard r.status == 0,
              let data = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        s.up = true
        s.maxContext = (obj["maximum_context_tokens"] as? Int) ?? 0
        s.memoryPressure = (obj["memory_pressure"] as? String) ?? ""
        // Splash 的推理**全在 GPU 上**：实测生成期间它的进程 CPU 只有 0.1%（空闲 0.0%），
        // 所以"引擎忙不忙"绝不能靠 CPU 判断 —— 那会让菜单栏的速度永远不显示。
        // 它自己就报了调度状态，直接读：
        //   scheduler.decoding / .prefilling / .queued  正在解码/预填充/排队的请求数
        //   frontend.active                             前端还没交给调度器的活跃请求
        // 两者取较大值（有重叠，不能相加）。
        let sched: Int = {
            guard let sc = obj["scheduler"] as? [String: Any] else { return 0 }
            return ((sc["decoding"] as? Int) ?? 0)
                 + ((sc["prefilling"] as? Int) ?? 0)
                 + ((sc["queued"] as? Int) ?? 0)
        }()
        let frontendActive = ((obj["frontend"] as? [String: Any])?["active"] as? Int) ?? 0
        s.reqRunning = max(sched, frontendActive)
        if let m = obj["metrics"] as? [String: Any] {
            if let d = m["decode_tokens_per_second"] as? Double { s.tps = d }
            if let d = m["draft_acceptance_rate"] as? Double { s.accept = d }
            if let t = m["ttft_ms"] as? [String: Any], let p = t["p50"] as? Double { s.ttftP50 = p }
        }
        if let mp = obj["memory_plan"] as? [String: Any],
           let dev = mp["device"] as? [String: Any],
           let n = dev["device_name"] as? String { s.deviceName = n }
        if let ma = obj["memory_actual"] as? [String: Any],
           let b = ma["current_bytes"] as? Double { s.residentGB = b / 1_073_741_824.0 }
        return s
    }
}

// MARK: - 菜单状态机（纯函数，可单独验证）

/// 一次探测的快照。四个布尔量决定了整个菜单的可用性。
struct Snapshot {
    var served = false    // HTTP /status 有响应
    var owned = false     // pid 文件有效且进程存活（本 App 托管）
    var paused = false    // 托管进程处于 SIGSTOP 冻结
    var starting = false  // 刚刚下发过启动命令的短暂过渡态

    /// 端口在响应，但不是我们管的（例如手工在终端跑的 splash）
    var isExternal: Bool { served && !owned }
    /// 真正在提供服务
    var isRunning: Bool { served && !paused }
    /// 进程已起、HTTP 还没就绪（Splash 加载模型约 12s）
    var isLoading: Bool { owned && !served && !paused }
}

/// 菜单项可用性规则。写成纯函数，便于 `--states` 打印全量真值表核对。
struct MenuPolicy {
    let s: Snapshot

    /// 启动（暂停态下语义为"继续"）
    /// 关键：端口已被占用（served）时一律不可启动，否则会 spawn 第二个进程、
    /// 绑定 8000 失败，pid 文件却被新 pid 覆盖，造成"显示托管中、实际是死的"错乱。
    var canStart: Bool { !s.starting && !s.served && (!s.owned || s.paused) }

    /// 暂停：只有真正在跑的托管进程才能暂停
    var canPause: Bool { s.owned && s.isRunning && !s.starting }

    /// 停止：有托管进程，或端口被外部进程占用（此时"停止"即清掉外部进程）
    var canStop: Bool { (s.owned || s.isExternal) && !s.starting }

    /// 重启：同停止。外部进程时等价于"接管后重启"
    var canRestart: Bool { (s.owned || s.isExternal) && !s.starting }

    /// 接管：仅在外部进程占用端口时显示
    var canTakeOver: Bool { s.isExternal && !s.starting }

    /// 打开 Web UI
    var canOpenUI: Bool { s.isRunning }
}

// MARK: - App 委托

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var statusItem: NSStatusItem!
    var cfg = Config.load()
    var st = Status()
    /// 模型清单缓存（见 installedModels）
    private var modelListCache: (at: Date, list: [String])?
    var timer: Timer?
    var starting = false

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyConfig(cfg)          // 必须在任何 Service 探测之前，否则会探到默认端口

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        rebuildMenu()
        refresh()

        if cfg.autoStartOnLaunch && !Service.managed && !Service.status().up {
            starting = true
            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                _ = Service.start(cfg: self.cfg)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.starting = false
                    self.refresh()
                }
            }
            rebuildMenu()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ aNotification: Notification) { timer?.invalidate() }

    /// 状态探测放到后台：curl 最长可能阻塞 2 秒，放主线程会让菜单卡顿
    private var lastPollAt = Date.distantPast
    private var lastEngineCPU: (at: Date, nanos: UInt64)?
    /// 最近一次检测到引擎在忙的时刻。菜单栏的速度显示靠它决定何时隐藏 ——
    /// 两个引擎统一走这个规则。
    private var lastBusyAt = Date.distantPast
    /// 上一次写进按钮标题的文字，用来跳过无变化的重复写入
    private var lastButtonText = ""

    /// 定时器每秒调一次，但**不是每次都真去请求**：
    /// 引擎忙（正在生成）时保持 1 秒高频；空闲时降到 5 秒一次。
    ///
    /// 忙闲判断用引擎进程的 CPU 时间 —— 纯系统调用，比"发个请求看看"便宜几个数量级，
    /// 所以可以每秒做。这样既不会漏掉生成的开始（最多迟 1 秒），
    /// 又能在占绝大多数的空闲时间里把请求量砍到 1/5。
    private func tick() {
        let now = Date()
        let busy = engineBusy(now: now)
        if busy { lastBusyAt = now }
        // 按钮标题每秒都重算一次：空闲时轮询降到 5 秒，若只靠 refresh() 更新，
        // "忙完 2 秒隐藏"会被拖成最多 5 秒才生效。只改标题，代价可忽略。
        applyStatusButton()
        let interval: TimeInterval = busy ? 1.0 : 5.0
        guard now.timeIntervalSince(lastPollAt) >= interval else { return }
        lastPollAt = now
        refresh()
    }

    /// 引擎进程 CPU 占用是否明显（阈值 25% 单核）。空闲时它的 CPU 时间几乎不涨。
    private func engineBusy(now: Date) -> Bool {
        guard let pid = Service.recordedPID, Service.isAlive(pid), let nanos = cpuNanos(of: pid) else {
            lastEngineCPU = nil
            return st.reqRunning > 0
        }
        guard let p = lastEngineCPU else {
            lastEngineCPU = (now, nanos)      // 第一次只记基线
            return st.reqRunning > 0
        }
        let dCPU = Double(nanos >= p.nanos ? nanos - p.nanos : 0) / 1e9
        let dt = now.timeIntervalSince(p.at)
        lastEngineCPU = (now, nanos)
        if dt > 0, dCPU / dt > 0.25 { return true }
        return st.reqRunning > 0
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = Service.status()
            DispatchQueue.main.async {
                self?.st = s
                self?.updateOpenMenuValues()   // 已展开的菜单是旧对象，必须原地改
                self?.rebuildMenu()
            }
        }
    }

    // MARK: 菜单

    /// 把构建好的菜单挂到状态栏
    func rebuildMenu() {
        statusItem.menu = buildMenu()
        applyStatusButton()
    }

    /// 纯构建：不碰 statusItem，便于 CLI 里单独 dump 校验
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // 必须关掉自动启用！NSMenu.autoenablesItems 默认 true，AppKit 会忽略我们
        // 手写的 isEnabled，改按"target 是否响应 action"判定；而本类实现了全部
        // 四个 action，于是启动/暂停/停止/重启会永远点亮（已实测复现）。
        menu.autoenablesItems = false

        // 一次探测，统一快照；所有可用性判定都走 MenuPolicy
        let owned = Service.managed
        let isPaused = Service.paused
        let snap = Snapshot(served: st.up, owned: owned, paused: isPaused, starting: starting)
        let policy = MenuPolicy(s: snap)

        let external = snap.isExternal
        let running = snap.isRunning

        // ── 状态区：压到 4 行以内（原来是 7 行）
        let runVer = Service.runningVersion()
        let instVer = Service.installedVersion()
        menu.addItem(disabled("\(activeEngine.displayName) \(runVer ?? instVer ?? "?")  ·  \(stateLabel())"))
        // 两个引擎的 KPI 不是一套：Splash 报草稿接受率，mlx-serve 没有（它的推测解码统计
        // 只进日志 [spec-stats]），但 mlx-serve 有 GPU 负载。所以按引擎分别渲染，
        // 不能共用一行——否则会显示一堆恒为 0 的假数字。
        if running {
            let it = disabled(speedLineText())
            it.representedObject = kKpiSpeed      // 供 updateOpenMenuValues 原地更新
            menu.addItem(it)
        }
        menu.addItem(disabled("\(modelShortName())  ·  \(baseURL.replacingOccurrences(of: "http://", with: ""))"))
        if running, let t = ttftLineText() {
            let it = disabled(t)
            it.representedObject = kKpiTtft
            menu.addItem(it)
        }
        if let r = runVer, let i = instVer, r != i {
            menu.addItem(disabled("⚠️ running \(r) ≠ installed \(i) — restart to switch"))
        }
        if external { menu.addItem(disabled("⚠️ port held by an external process, not managed by Splash-MLX")) }
        if starting { menu.addItem(disabled("⏳ loading model…")) }
        menu.addItem(.separator())

        // ── 引擎选择：决定下面整组菜单属于哪个引擎。
        // 两个引擎是互斥的（一次只跑一个），切换时若当前引擎在跑会先停掉。
        menu.addItem(submenuItem("Engine  ·  \(activeEngine.displayName)", items: engineItems()))

        // ── 模型选择：清单按当前引擎刷新（MLX 走 `mlx-serve list`，Splash 扫目录）
        menu.addItem(submenuItem("Model  ·  \(modelShortName())", items: modelItems()))

        // 启动：运行中 / 端口被占用时置灰；暂停时充当"继续"
        let startItem = NSMenuItem(title: isPaused ? "▶  Resume" : "▶  Start",
                                   action: #selector(startService), keyEquivalent: "s")
        startItem.target = self
        startItem.isEnabled = policy.canStart
        menu.addItem(startItem)

        // 暂停：仅"真正在跑的托管进程"可用；暂停中 / 启动中 / 已停止均置灰
        let pauseItem = NSMenuItem(title: "⏸  Pause", action: #selector(pauseService), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.isEnabled = policy.canPause
        menu.addItem(pauseItem)

        // 停止：有托管进程或外部进程时可用；已停止置灰
        let stopItem = NSMenuItem(title: external ? "■  Stop (external)" : "■  Stop",
                                  action: #selector(stopService), keyEquivalent: "x")
        stopItem.target = self
        stopItem.isEnabled = policy.canStop
        menu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "⟳  Restart", action: #selector(restartService), keyEquivalent: "r")
        restartItem.target = self
        restartItem.isEnabled = policy.canRestart
        menu.addItem(restartItem)

        // 端口被外部进程占用时，给一个显式接管入口（v1.0 有，v1.1 重写菜单时漏掉了，现恢复）
        if policy.canTakeOver {
            let take = NSMenuItem(title: "⇪  Take over as managed",
                                  action: #selector(takeOver), keyEquivalent: "")
            take.target = self
            menu.addItem(take)
        }
        menu.addItem(.separator())

        // ── 参数设置：8 个参数子菜单收进一个入口（原来平铺占 8 行）
        // 除 Model / API Key 外，每个子菜单都走 gatedSubmenu —— 引擎不认识的会自动整组置灰。
        var settingsItems: [NSMenuItem] = []
        // 探测失败时在这里统一说一次，而不是在 8 个子菜单里各说一遍。
        // 此时所有参数都保持可选（fail open），提示只是让用户知道"没探测到引擎"。
        if !Service.flagsProbed {
            settingsItems.append(disabled("Could not query the engine — options left enabled"))
            settingsItems.append(.separator())
        }
        settingsItems += (activeEngine == .mlx ? mlxSettingsItems() : splashSettingsItems())
        // 渐进式披露：引擎没跑起来时不展开 Settings，菜单保持精简。
        // 引擎/模型/启停始终在顶层，所以不会出现"想配置却无处可点"的死锁。
        if running { menu.addItem(submenuItem("Settings", items: settingsItems)) }

        // ── 打开：5 个入口收进一个子菜单（原来平铺占 5 行）
        let openUI = NSMenuItem(title: "Open Web UI in browser", action: #selector(openWebUI), keyEquivalent: "o")
        openUI.target = self
        openUI.isEnabled = policy.canOpenUI && !cfg.noWebUI
        let copyURL = NSMenuItem(title: "Copy API base URL", action: #selector(copyBaseURL), keyEquivalent: "c")
        copyURL.target = self
        var openItems: [NSMenuItem] = [openUI, copyURL, .separator()]
        for (title, sel) in [("View runtime log", #selector(openLogs)),
                             ("Open models folder", #selector(openModelDir)),
                             ("Open config folder", #selector(openConfigDir))] as [(String, Selector)] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            openItems.append(it)
        }
        menu.addItem(submenuItem("Open", items: openItems))

        // ── 偏好与关于：开关 + 关于收进一个子菜单（原来平铺占 3 行）
        let showName = NSMenuItem(title: "Show model name in menu bar", action: #selector(toggleModelName), keyEquivalent: "")
        showName.target = self
        showName.state = cfg.showModelName ? .on : .off

        let showSpeed = NSMenuItem(title: "Show speed in menu bar", action: #selector(toggleShowSpeed), keyEquivalent: "")
        showSpeed.target = self
        showSpeed.state = cfg.showSpeed ? .on : .off

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = cfg.loginItem ? .on : .off

        let about = NSMenuItem(title: "About Splash-MLX", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(submenuItem("Preferences & About", items: [showName, showSpeed, login, .separator(), about]))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Splash-MLX (stops the service)",
                              action: #selector(confirmQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// 状态短标签（和版本号拼在同一行，所以不重复图标之外的信息）
    private func stateLabel() -> String {
        if Service.paused { return "paused (frozen, memory still held)" }
        if st.up { return Service.managed ? "running (managed)" : "running (external)" }
        if Service.managed || starting { return "starting (waiting for model)" }
        return "stopped"
    }

    /// 从 App 包 Resources 里按 @3x → @2x → 1x 顺序取菜单栏图标
    private func menuBarIcon() -> NSImage? {
        let name: String
        if Service.paused { name = "menubar_paused" }
        else if st.up { name = "menubar_running" }
        else if Service.managed || starting { name = "menubar_paused" }   // 启动中：琥珀色过渡态
        else { name = "menubar_stopped" }

        let res = Bundle.main.resourcePath ?? ""
        for suffix in ["@3x", "@2x", ""] {
            let path = "\(res)/\(name)\(suffix).png"
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = false
                return img
            }
        }
        return nil
    }

    private func modelShortName() -> String {
        // **必须用按引擎分发的 currentModel**。
        // 原来固定读 cfg.model（Splash 的字段）—— 于是切成 MLX 后，
        // 菜单栏标题、信息栏、Model 子菜单标题全都还显示 Splash 的模型名
        // （配置和勾号是对的，只有显示不会变），用户看到就是"换了模型但名字没变"。
        let full = currentModel
        let short = full.split(separator: "/").last.map(String.init) ?? full
        return short.replacingOccurrences(of: "-Splash", with: "")
    }

    private func applyStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = menuBarIcon()
        // 速度只在"有值"时出现（生成中 + 结束后约 30 秒），空闲时这一块消失，
        // 所以菜单栏是**间歇性变宽**，而不是常驻变宽。
        var text = ""
        if cfg.showModelName { text += " " + modelShortName() }
        // 统一规则：只在"引擎忙 + 结束后 2 秒"内显示速度。
        // 不能只看 st.tps > 0 —— Splash 的 /status 报的是它自己的平滑值、**永不归零**，
        // 那样速度会常驻菜单栏（MLX 侧有 2 秒保留期兜着，所以只有 Splash 会露出这个问题）。
        let recentlyBusy = Date().timeIntervalSince(lastBusyAt) <= 2.0
        if cfg.showSpeed, st.tps > 0, recentlyBusy {
            // 有模型名时用 ｜ 隔开，否则两者会连成一片看不出边界
            text += (text.isEmpty ? " " : " ｜ ") + String(format: "%.0f t/s", st.tps)
        }

        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        // 等宽数字：比例字体下 "174" 和 "99" 宽度不同，每秒变一次会让整个图标左右跳。
        // 11pt 也比菜单栏默认字号小一点，配合 "t/s" 的缩写控制占宽。
        if text != lastButtonText {            // 不变就不重设，免得每秒无谓重绘
            lastButtonText = text
            button.attributedTitle = text.isEmpty
                ? NSAttributedString(string: "")
                : NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
        }
        button.toolTip = "Splash-MLX — \(currentModel)"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.tag = kInfoTag          // 打标，方便 --dump-menu 跳过纯信息行
        return it
    }

    /// Settings 里的**分组标题行**。和 disabled() 的区别是刻意做出视觉层级：
    /// 小号系统字体 + 次要色，让它读起来像"分类名"而不是"一个点不动的选项"。
    /// 不可点、无 action，同样打 kInfoTag 让 --dump-menu 跳过。
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.tag = kInfoTag
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.firstLineHeadIndent = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        it.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: attrs)
        return it
    }

    /// 一个分组：标题行 + 其下参数项。首个分组不加前置分隔线，后续分组之间用分隔线断开，
    /// 这样 14–15 项的长菜单能靠"标题 + 空白"扫读，而不是逐行看 flag 名。
    private func section(_ title: String, first: Bool = false, _ items: [NSMenuItem]) -> [NSMenuItem] {
        (first ? [] : [NSMenuItem.separator()]) + [sectionHeader(title)] + items
    }

    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false      // 同上：保证子菜单里的自定义置灰生效
        for i in items { sub.addItem(i) }
        it.submenu = sub
        return it
    }

    /// 建一个"受引擎能力约束"的参数子菜单。三件事一次做完，不靠调用方记得：
    ///   1. 引擎不认识该 flag 时**整组置灰** —— 否则用户以为选了就生效，
    ///      其实 `serveArguments` 会把它丢掉（更糟的情况是没过滤，服务直接起不来）
    ///   2. 补一行说明"为什么不能选" —— 只置灰不解释，用户会以为是自己配错了
    ///   3. 选项带 tag，`validateMenuItem` 用同一张表兜底
    ///
    /// 探测失败（`serve --help` 都问不到）时**保持全部可用**：fail open。
    /// 宁可让用户能点，也不要因为问不到引擎就把他存好的配置判成无效。
    ///
    /// `cap` 是第二道门：**模型包自带的能力**。引擎认识 flag ≠ 模型有对应部件，
    /// 例如 `--mtp` 引擎认识、但模型没带头时开了也白开。传了 cap 就同时按
    /// "磁盘上的包"置灰，并在可用时于菜单顶部显示探测结果（可视化）。
    private func gatedSubmenu(_ title: String, tag: Int, items: [NSMenuItem],
                              cap: ModelCapGate? = nil) -> NSMenuItem {
        // 门一：引擎认不认这个 flag
        if let flag = flagForTag(tag), Service.flagsProbed, !Service.flagAvailable(flag) {
            var header: [NSMenuItem] = [disabled("Engine \(Service.installedVersion() ?? "?") has no \(flag)")]
            // SSD 缓存层是 splash 1.1.0 才转正的特性，光说"不支持"不够，得告诉用户怎么拿到
            if flag == "--max-cache-disk" {
                header.append(disabled("Upgrade splash to 1.1.0 or later"))
            }
            header.append(.separator())
            for it in items where !it.isSeparatorItem { it.isEnabled = false }
            return submenuItem(title, items: header + items)
        }

        // 门二：模型包里有没有这个部件
        if let cap {
            let caps = modelCaps(cfg.mlx.resolvedModelPath)
            if !cap.present(in: caps) {
                var header: [NSMenuItem] = [disabled(cap.missingReason)]
                header.append(.separator())
                for it in items where !it.isSeparatorItem { it.isEnabled = false }
                return submenuItem(title, items: header + items)
            }
            // 可用：把探测结果亮出来，让用户看见"为什么这项能选"
            return submenuItem(title, items: [disabled(cap.presentNote), .separator()] + items)
        }
        return submenuItem(title, items: items)
    }

    /// 参数对**模型包自带部件**的依赖。和 `kMlxGatedParams`（引擎能力）是两条独立门控。
    enum ModelCapGate {
        case mtp, vision
        func present(in caps: ModelCaps) -> Bool {
            switch self {
            case .mtp:    return caps.mtp
            case .vision: return caps.vision
            }
        }
        var missingReason: String {
            switch self {
            case .mtp:    return "Model pack ships no MTP head (no mtp/ sidecar, no *.mtp.* tensors)"
            case .vision: return "Model pack ships no vision tower"
            }
        }
        var presentNote: String {
            switch self {
            case .mtp:    return "Model pack: MTP head detected"
            case .vision: return "Model pack: vision tower detected"
            }
        }
    }

    private func choiceItems(current: String, options: [(String, String)],
                             customLabel: String, tag: Int, custom: Bool = true) -> [NSMenuItem] {
        var items = options.map { value, label -> NSMenuItem in
            let it = NSMenuItem(title: label, action: #selector(pickValue(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
            it.representedObject = value
            it.state = (value == current) ? .on : .off
            return it
        }
        // 三态这类封闭枚举不该给 free-text 入口：手输一个非法值只会被静默丢弃
        guard custom else { return items }
        items.append(.separator())
        let custom = NSMenuItem(title: customLabel, action: #selector(pickCustom(_:)), keyEquivalent: "")
        custom.target = self
        custom.tag = tag
        items.append(custom)
        return items
    }

    /// 速率行的文字（两个引擎各一套指标）
    private func speedLineText() -> String {
        if activeEngine == .mlx {
            guard st.metricsAvailable else { return "⏳ no metrics yet — model still loading?" }
            return String(format: "%@ · GPU %.0f%% · memory %.1f GB",
                          mlxSpeedLabel(), st.gpuPct, st.residentGB)
        }
        return String(format: "%.1f tok/s · accept %.1f%% · memory %.1f GB",
                      st.tps, st.accept * 100, st.residentGB)
    }

    /// TTFT 行；MLX 侧没有上下文上限，改报并发队列。无可显示内容时返回 nil
    private func ttftLineText() -> String? {
        if activeEngine == .mlx {
            guard st.metricsAvailable else { return nil }
            var tail = ""
            if st.reqRunning > 0 { tail += " · \(st.reqRunning) running" }
            if st.reqWaiting > 0 { tail += " · \(st.reqWaiting) waiting" }
            return String(format: "TTFT avg %.0f ms%@", st.ttftP50, tail)
        }
        return String(format: "TTFT %.0f ms · limit %dK", st.ttftP50, st.maxContext / 1024)
    }

    /// 把**当前已展开**的菜单里那几行原地改掉文字。
    ///
    /// 这是"速率滞后"的最后一块：替换 `statusItem.menu` **不会**刷新已经展开的菜单
    /// —— 展开中的仍是旧对象。于是用户盯着菜单看时只能看到打开那一刻的数值，
    /// 关掉再打开（多半生成已结束）才更新，表现就是"输出都完了才显示速度"。
    /// 原地改 title 才能让展开中的菜单实时反映。
    private func updateOpenMenuValues() {
        guard let menu = statusItem?.menu else { return }
        for it in menu.items {
            switch it.representedObject as? String {
            case kKpiSpeed: it.title = speedLineText()
            case kKpiTtft:  it.title = ttftLineText() ?? it.title
            default: break
            }
        }
    }

    /// mlx-serve 的速率文案。
    /// 它的计数是累计量、只能靠窗口差值算速率，而生成往往是突发的 ——
    /// 实测 900 token 只占 1 个 5 秒窗口。所以窗口没撞上时给出**上次实测值 + 年龄**，
    /// 而不是显示一个等于"这一格恰好没生成"的 0；真空闲了才写 idle。
    private func mlxSpeedLabel() -> String {
        guard st.tps > 0 else { return "idle" }
        if st.tpsStaleSeconds < 0 { return String(format: "%.1f tok/s", st.tps) }
        return String(format: "%.1f tok/s (%ds ago)", st.tps, Int(st.tpsStaleSeconds))
    }

    /// 当前引擎选中的模型。两个引擎各存各的，所以读写都要按引擎分发。
    private var currentModel: String {
        switch activeEngine {
        case .splash: return cfg.model
        case .mlx:    return cfg.mlx.model
        }
    }

    private func setCurrentModel(_ m: String) {
        switch activeEngine {
        case .splash: cfg.model = m
        case .mlx:    cfg.mlx.model = m
        }
        cfg.save()
        invalidateModelList()
        invalidateModelCapsCache()   // 换了模型包，MTP/视觉探测结果必须重算
    }

    private func modelItems() -> [NSMenuItem] {
        var items = installedModels().map { m -> NSMenuItem in
            let it = NSMenuItem(title: m, action: #selector(pickModel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m
            it.state = (m == currentModel) ? .on : .off
            return it
        }
        items.append(.separator())
        let label = activeEngine == .mlx ? "Custom model (org/repo or path)…" : "Custom owner/repo…"
        let custom = NSMenuItem(title: label, action: #selector(pickCustomModel), keyEquivalent: "")
        custom.target = self
        items.append(custom)
        return items
    }

    /// "Engine default" 的具体值。splash 的 effort 回退链是：
    /// 请求参数 → --default-reasoning-effort → **模型 chat_template.jinja 里的默认**。
    /// 菜单选 "Engine default" 就是不传 flag、落到第三层，所以直接把第三层读出来展示：
    /// 从当前模型模板里找 `reasoning_effort|default('xhigh')` 这类写法。
    /// 读不到（模型没下载/模板没有 effort 分档）就退回笼统说法，绝不瞎猜具体档位。
    private func templateEffortDefaultHint() -> String {
        // Splash 模型包布局：<modelsDir>/<org>/<repo>/tokenizer/chat_template.jinja
        let modelDir = splashModelsDir.appendingPathComponent(cfg.model).path
        let tplPath = (modelDir as NSString).appendingPathComponent("tokenizer/chat_template.jinja")
        guard let tpl = try? String(contentsOfFile: tplPath, encoding: .utf8) else {
            return " (model template decides)"
        }
        // jinja 写法：reasoning_effort|default('xhigh')
        if let r = tpl.range(of: #"reasoning_effort\|default\('([a-z]+)'\)"#, options: .regularExpression) {
            let m = tpl[r]
            if let lo = m.firstIndex(of: "'"), let hi = m.lastIndex(of: "'"), lo < hi {
                let v = m[m.index(after: lo)..<hi]
                return " (= \(v), from model template)"
            }
        }
        // 模板没有 effort 分档（如 Qwen3.6-35B-A3B-Splash）：thinking 由模板自身开关
        if !tpl.contains("reasoning_effort") {
            return " (template has no effort levels)"
        }
        return " (model template decides)"
    }

    /// 布尔开关的子菜单项：就两项，带勾选状态，**不追加 Custom…**。
    /// 不能复用 choiceItems —— 它一定会加一个 free-text 输入项，
    /// 对"开/关"这种二值设置来说是个没有意义的入口。
    private func boolItems(on: Bool, onLabel: String, offLabel: String, tag: Int) -> [NSMenuItem] {
        let a = NSMenuItem(title: onLabel, action: #selector(pickValue(_:)), keyEquivalent: "")
        a.target = self; a.tag = tag; a.representedObject = "on"; a.state = on ? .on : .off
        let b = NSMenuItem(title: offLabel, action: #selector(pickValue(_:)), keyEquivalent: "")
        b.target = self; b.tag = tag; b.representedObject = "off"; b.state = on ? .off : .on
        return [a, b]
    }

    /// Splash 引擎的参数菜单。按**使用意图**分三组，每组一个小号标题行 + 分隔线，
    /// 让 14 项能靠扫读标题定位，而不是逐行看 flag 名。
    /// 分组依据是"用户调它时想解决什么问题"，不是技术子系统：
    ///   - Memory & cache：吃多少机器资源（Context 归这里，因为它决定 KV cache 占用）
    ///   - Model & decoding：模型怎么想、看什么（Max image pixels 与 Language only 同组）
    ///   - Serving & access：谁能连、怎么连（Max request size 是接口契约，归这里）
    private func splashSettingsItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items += section("Memory & cache", first: true, [
            gatedSubmenu("Max memory  --max-memory", tag: kTagMaxMemory, items: choiceItems(
                current: cfg.maxMemory,
                options: [("auto", "auto (≈107 GB, M5 Max limit)"),
                          ("24G", "24G"), ("32G", "32G"), ("48G", "48G"),
                          ("64G", "64G"), ("96G", "96G")],
                customLabel: "Custom… (e.g. 28G)", tag: kTagMaxMemory)),
            gatedSubmenu("Context  --max-context", tag: kTagMaxContext, items: choiceItems(
                current: cfg.maxContext,
                options: [("auto", "auto (262144 = 256K)"),
                          ("32K", "32K"), ("64K", "64K"), ("128K", "128K"), ("256K", "256K")],
                customLabel: "Custom… (e.g. 100K)", tag: kTagMaxContext)),
            gatedSubmenu("KV cache format  --kv-format", tag: kTagKvFormat, items: choiceItems(
                current: cfg.kvFormat,
                options: [("", "int8 (engine default)"),
                          ("bf16", "bf16 — more memory, no quant loss")],
                customLabel: "", tag: kTagKvFormat, custom: false)),
            gatedSubmenu("Max cache disk  --max-cache-disk", tag: kTagCacheDisk, items: choiceItems(
                current: cfg.maxCacheDisk,
                options: [("", "Off (default)"),
                          ("8G", "8G"), ("16G", "16G"), ("32G", "32G"), ("64G", "64G")],
                customLabel: "Custom… (e.g. 12G)", tag: kTagCacheDisk)),
        ])

        items += section("Model & decoding", [
            gatedSubmenu("Reasoning effort  --default-reasoning-effort", tag: kTagReasoningEffort, items: choiceItems(
                current: cfg.reasoningEffort,
                options: [("", "Engine default" + templateEffortDefaultHint()),
                          ("none", "none — no thinking (fastest)"),
                          ("minimal", "minimal"), ("low", "low"),
                          ("medium", "medium"), ("high", "high")],
                customLabel: "Custom… (xhigh / max)", tag: kTagReasoningEffort)),
            gatedSubmenu("Draft model  --draft-model", tag: kTagDraftModel, items: choiceItems(
                current: cfg.draftModel,
                options: [("", "Auto (engine-picked DFlash2)")],
                customLabel: "Custom… (repo or local dir)", tag: kTagDraftModel)),
            gatedSubmenu("Model revision  --revision", tag: kTagRevision, items: choiceItems(
                current: cfg.revision,
                options: [("", "Repository default")],
                customLabel: "Custom… (branch / tag / commit)", tag: kTagRevision)),
            gatedSubmenu("Language only  --language-only", tag: kTagLanguageOnly, items: boolItems(
                on: !cfg.languageOnly,
                onLabel: "Load vision too (default)",
                offLabel: "Skip vision --language-only",
                tag: kTagLanguageOnly)),
            gatedSubmenu("Max image pixels  --max-image-pixels", tag: kTagMaxImagePixels, items: choiceItems(
                current: cfg.maxImagePixels,
                options: [("", "Engine default (4194304)"),
                          ("1048576", "1M  = 1048576"), ("2097152", "2M  = 2097152"),
                          ("4194304", "4M  = 4194304"), ("8388608", "8M  = 8388608")],
                customLabel: "Custom… (pixel count)", tag: kTagMaxImagePixels)),
        ])

        items += section("Serving & access", [
            gatedSubmenu("Port  --port", tag: kTagPort, items: choiceItems(
                current: cfg.port,
                options: [("8000", "8000 (Splash default)"),
                          ("8080", "8080"), ("8123", "8123"), ("9000", "9000")],
                customLabel: "Custom… (e.g. 7000)", tag: kTagPort)),
            gatedSubmenu("Allowed host  --allowed-host", tag: kTagAllowedHost, items: hostItems()),
            // 这一项不是 CLI 参数：Splash-MLX 通过环境变量注入（--api-key 的 default 就是它）
            submenuItem("API Key  $SPLASH_API_KEY", items: apiKeyItems()),
            gatedSubmenu("Web UI  --no-webui", tag: kTagWebUI, items: webUIItems()),
            gatedSubmenu("Max request size  --max-request-size", tag: kTagMaxRequestSize, items: choiceItems(
                current: cfg.maxRequestSize,
                options: [("", "128M (Splash 1.0.1 default — flag omitted)"),
                          ("64M", "64M"), ("256M", "256M"), ("512M", "512M"), ("1G", "1G")],
                customLabel: "Custom… (e.g. 32M)", tag: kTagMaxRequestSize)),
        ])

        return items
    }

    /// mlx-serve 的参数菜单。字段全部来自 `MLXConfig`（与 Splash 那套完全隔离），
    /// 每一项都过 `gatedSubmenu` —— 引擎 `--help` 里没有该 flag 就整组置灰。
    /// 分组与 Splash 同一套意图口径；Prefix cache 因为项多（4 个）单独成组，
    /// 塞进 Memory 会把它们稀释掉。
    private func mlxSettingsItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items += section("Memory & context", first: true, [
            gatedSubmenu("Context  --ctx-size", tag: kTagMlxCtx, items: choiceItems(
                current: cfg.mlx.ctxSize,
                options: [("", "auto (budgeted from model + GPU memory)"),
                          ("32768", "32K"), ("65536", "64K"),
                          ("131072", "128K"), ("262144", "256K")],
                customLabel: "Custom… (e.g. 96K)", tag: kTagMlxCtx)),
            gatedSubmenu("KV cache quant  --kv-quant", tag: kTagMlxKvQuant, items: choiceItems(
                current: cfg.mlx.kvQuant,
                options: [("off", "off (default)"), ("4", "4-bit"), ("8", "8-bit")],
                customLabel: "Custom…", tag: kTagMlxKvQuant)),
            // 所有常驻模型的「总」内存上限。选项刻意保守 —— 调太小会频繁驱逐、反而更慢
            gatedSubmenu("Max resident memory  --max-resident-mem", tag: kTagMlxResidentMem, items: choiceItems(
                current: cfg.mlx.maxResidentMem,
                options: [("", "Engine default (80% of wired limit)"),
                          ("48GB", "48GB"), ("64GB", "64GB"), ("96GB", "96GB")],
                customLabel: "Custom… (e.g. 80GB)", tag: kTagMlxResidentMem)),
            gatedSubmenu("Max resident models  --max-resident-models", tag: kTagMlxResident, items: choiceItems(
                current: cfg.mlx.maxResidentModels,
                options: [("", "Engine default (3)"), ("1", "1"), ("2", "2"), ("3", "3")],
                customLabel: "Custom…", tag: kTagMlxResident)),
        ])

        // 前缀缓存单独成组：四项是同一缓存的不同维度（内存层 / SSD 层 / 条数 / 驱逐），
        // 拆开会把它们稀释掉。Idle evict 放这里而非内存组 —— 用户找它的场景通常是
        // "为什么缓存没了 / 模型被踢了"，属于缓存生命周期。
        items += section("Prefix cache", [
            // 内存层预算：引擎默认只给 2GB，大内存机器加大能明显提高命中率
            gatedSubmenu("Prefix cache memory  --prefix-cache-mem", tag: kTagMlxPrefixMem, items: choiceItems(
                current: cfg.mlx.prefixCacheMem,
                options: [("", "Engine default (2GB)"),
                          ("4GB", "4GB"), ("8GB", "8GB"), ("16GB", "16GB")],
                customLabel: "Custom… (e.g. 6GB)", tag: kTagMlxPrefixMem)),
            gatedSubmenu("Prefix cache SSD  --prefix-cache-disk", tag: kTagMlxPrefixDisk, items: choiceItems(
                current: cfg.mlx.prefixCacheDisk,
                options: [("", "Off (default)"),
                          ("4GB", "4GB"), ("10GB", "10GB"), ("32GB", "32GB")],
                customLabel: "Custom… (e.g. 10GB)", tag: kTagMlxPrefixDisk)),
            gatedSubmenu("Prefix cache entries  --prefix-cache-entries", tag: kTagMlxPrefixEnt, items: choiceItems(
                current: cfg.mlx.prefixCacheEntries,
                options: [("", "Engine default (32)"),
                          ("64", "64"), ("128", "128"), ("256", "256")],
                customLabel: "Custom… (count)", tag: kTagMlxPrefixEnt)),
            gatedSubmenu("Idle evict  --idle-evict-secs", tag: kTagMlxIdle, items: choiceItems(
                current: cfg.mlx.idleEvictSecs,
                options: [("", "Off (default)"), ("300", "300 s"), ("900", "900 s"), ("3600", "3600 s")],
                customLabel: "Custom… (seconds)", tag: kTagMlxIdle)),
        ])

        items += section("Model & decoding", [
            // MTP 投机解码。三态而非布尔：MoE 模型引擎**默认关** MTP，
            // 想开必须显式 --mtp（旧版只有负向开关，导致 --mtp 永远缺席）。
            // 第二道门是模型包真带头（cap: .mtp），没带头整组置灰并说明原因。
            gatedSubmenu("MTP speculative  --mtp", tag: kTagMlxMTP, items: choiceItems(
                current: cfg.mlx.mtpMode,
                options: [("on", "On — pass --mtp (required for MoE models)"),
                          ("auto", "Auto — engine default (off for MoE, on for dense)"),
                          ("off", "Off — pass --no-mtp")],
                customLabel: "", tag: kTagMlxMTP, custom: false), cap: .mtp),
            // PLD：引擎默认开，这里只给"强制关"的出口
            gatedSubmenu("Prompt lookup decoding  --no-pld", tag: kTagMlxPLD, items: boolItems(
                on: cfg.mlx.enablePLD,
                onLabel: "Enabled (engine default)",
                offLabel: "Force-disable --no-pld",
                tag: kTagMlxPLD)),
            gatedSubmenu("Drafter  --drafter", tag: kTagMlxDrafter, items: choiceItems(
                current: cfg.mlx.drafter,
                options: [("", "Auto (use the checkpoint's own)")],
                customLabel: "Custom… (drafter folder)", tag: kTagMlxDrafter)),
            gatedSubmenu("Vision  --no-vision", tag: kTagMlxVision, items: boolItems(
                on: !cfg.mlx.noVision,
                onLabel: "Load the vision encoder",
                offLabel: "Skip it --no-vision (saves memory)",
                tag: kTagMlxVision), cap: .vision),
        ])
        // Metrics 不在这里出现：它被强制打开（见 MLXConfig.serveArguments）。
        // 菜单的运行信息栏要靠它取数，做成开关只会让用户把自己看瞎。

        items += section("Serving", [
            gatedSubmenu("Port  --port", tag: kTagMlxPort, items: choiceItems(
                current: cfg.mlx.port,
                options: [("11234", "11234 (mlx-serve default)"),
                          ("8000", "8000"), ("8080", "8080"),
                          ("11434", "11434 (Ollama drop-in)")],
                customLabel: "Custom… (e.g. 11235)", tag: kTagMlxPort)),
            gatedSubmenu("Bind address  --host", tag: kTagMlxHost, items: choiceItems(
                current: cfg.mlx.host,
                // 只给"绑本机"。暴露到局域网既不是性能收益、又降低安全性，
                // 按"只开放安全且有效益的项"的原则不放进菜单 —— 真需要就手改配置。
                options: [("127.0.0.1", "127.0.0.1 — this Mac only (default)")],
                customLabel: "Custom… (e.g. 192.168.1.5)", tag: kTagMlxHost)),
            submenuItem("Model folder…", items: modelDirItems()),
        ])

        return items
    }

    /// 手动指定模型目录 —— 兜住"每台电脑路径不一致"和 `--model-dir` 指到别处的情况。
    private func modelDirItems() -> [NSMenuItem] {
        let cur = activeEngine == .mlx ? cfg.mlx.modelDir : cfg.modelDirSplash
        var items: [NSMenuItem] = []
        items.append(disabled(engineModelsDir.path))
        items.append(.separator())
        let pick = NSMenuItem(title: "Choose folder…", action: #selector(pickModelDir), keyEquivalent: "")
        pick.target = self
        items.append(pick)
        let auto = NSMenuItem(title: "Use auto-detected", action: #selector(clearModelDir), keyEquivalent: "")
        auto.target = self
        auto.isEnabled = !cur.isEmpty
        items.append(auto)
        return items
    }

    @objc func pickModelDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = engineModelsDir
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if activeEngine == .mlx { cfg.mlx.modelDir = url.path } else { cfg.modelDirSplash = url.path }
        cfg.save(); applyConfig(cfg); invalidateModelList(); invalidateModelCapsCache(); refresh()
    }

    @objc func clearModelDir() {
        if activeEngine == .mlx { cfg.mlx.modelDir = "" } else { cfg.modelDirSplash = "" }
        cfg.save(); applyConfig(cfg); invalidateModelList(); invalidateModelCapsCache(); refresh()
    }

    private func apiKeyItems() -> [NSMenuItem] {
        let cur = cfg.apiKey.isEmpty ? "not set (no auth)" : "set (\(cfg.apiKey.count) chars)"
        let items = [disabled("Current: \(cur)"), NSMenuItem.separator()]
        let set = NSMenuItem(title: "Set / change…", action: #selector(setAPIKey), keyEquivalent: "")
        set.target = self
        let clear = NSMenuItem(title: "Clear", action: #selector(clearAPIKey), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !cfg.apiKey.isEmpty
        return items + [set, clear]
    }

    private func hostItems() -> [NSMenuItem] {
        let only = NSMenuItem(title: "Localhost only (127.0.0.1)", action: #selector(clearHost), keyEquivalent: "")
        only.target = self
        only.tag = kTagAllowedHost
        only.state = cfg.allowedHost.isEmpty ? .on : .off
        var items = [only, NSMenuItem.separator()]
        if !cfg.allowedHost.isEmpty { items.append(disabled("Current: \(cfg.allowedHost)")) }
        let set = NSMenuItem(title: "Allow LAN access…", action: #selector(setHost), keyEquivalent: "")
        set.target = self
        set.tag = kTagAllowedHost
        items.append(set)
        return items
    }

    private func webUIItems() -> [NSMenuItem] {
        let on = NSMenuItem(title: "On (default)", action: #selector(setWebUIOn), keyEquivalent: "")
        on.target = self
        on.tag = kTagWebUI
        on.state = cfg.noWebUI ? .off : .on
        let off = NSMenuItem(title: "Off --no-webui", action: #selector(setWebUIOff), keyEquivalent: "")
        off.target = self
        off.tag = kTagWebUI
        off.state = cfg.noWebUI ? .on : .off
        return [on, off]
    }

    /// 本地已有的 Splash 包，两个来源合并：
    ///   1) App 托管目录 —— Splash 服务过的模型会在这里留下符号链接
    ///   2) HF 缓存 —— 真正落盘的位置，包装配好就在这里
    /// 只看 (1) 会漏掉"已下载装配、但还没被服务过"的包，那样新下的模型在菜单里根本不出现，
    /// 只能靠 "Custom owner/repo…" 手打全名 —— 而用户刚下完一个包时最想看到的
    /// 恰恰是它能直接选。
    // MARK: 引擎切换

    private func engineItems() -> [NSMenuItem] {
        Engine.allCases.map { e in
            let it = NSMenuItem(title: e.displayName, action: #selector(pickEngine(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.rawValue
            it.state = (e == activeEngine) ? .on : .off
            return it
        }
    }

    /// 切换到另一个引擎。**互斥**：当前引擎在跑就先停掉，再换配置并重建菜单。
    /// 不停直接切会留下"菜单显示 MLX、实际还占着 8000 端口跑 Splash"的错乱状态。
    @objc func pickEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let e = Engine(rawValue: raw), e != cfg.engine else { return }
        if Service.managed || Service.status().up { _ = Service.stop() }
        cfg.engine = e
        cfg.save()
        invalidateModelCapsCache()   // 换引擎 = 换模型集，能力探测结果作废
        applyConfig(cfg)
        invalidateModelList()
        refresh()
    }

    /// 按引擎分发：能用引擎自己的 list 就用（口径和引擎一致），
    /// 没有这个命令的（Splash 只有 serve/claude/opencode/codex/hermes）才退回扫目录。
    fileprivate func installedModels() -> [String] {
        // 菜单每次重建都会走到这里，而 MLX 分支要跑 `mlx-serve list`（一个进程）。
        // 刷新频率提到 1 秒后，每秒起一个进程就太浪费了 —— 模型库很少变，缓存 60 秒。
        // 换引擎 / 换模型 / 换模型目录时会主动失效（见 invalidateModelList）。
        if let c = modelListCache, Date().timeIntervalSince(c.at) < 60 { return c.list }
        let list = (activeEngine == .mlx) ? mlxInstalledModels() : splashInstalledModels()
        modelListCache = (Date(), list)
        return list
    }

    private func invalidateModelList() { modelListCache = nil }

    /// mlx-serve 自带 `list` 子命令，输出是 `NAME  TYPE  SIZE` 表格。
    /// 命令失败（引擎没装 / 被换过）时退回扫 <models>/<org>/<repo>。
    private func mlxInstalledModels() -> [String] {
        let fm = FileManager.default
        var out = Set<String>()

        let r = run(engineBin, ["list"])
        if r.status == 0 {
            for line in r.out.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                // 跳过表头、空行，以及引擎启动时那行 [mem] 调试输出
                if s.isEmpty || s.hasPrefix("NAME") || s.hasPrefix("[") { continue }
                // 首列就是 org/repo
                guard let first = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
                let name = String(first)
                if name.contains("/") { out.insert(name) }
            }
        }

        if out.isEmpty {
            if let owners = try? fm.contentsOfDirectory(atPath: mlxModelsDir.path) {
                for owner in owners where !owner.hasPrefix(".") {
                    let dir = mlxModelsDir.appendingPathComponent(owner)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
                        for name in names where !name.hasPrefix(".") { out.insert("\(owner)/\(name)") }
                    }
                }
            }
        }

        var list = out.sorted()
        // 当前配置里的模型即使扫不到也要留着，否则菜单会把它"弄丢"
        if !cfg.mlx.model.isEmpty, !list.contains(cfg.mlx.model) { list.append(cfg.mlx.model) }
        return list
    }

    private func splashInstalledModels() -> [String] {
        let fm = FileManager.default
        var out = Set<String>()

        // 1) App 托管目录：<models>/<owner>/<name>
        //    用 engineModelsDir 而非 splashModelsDir，这样"手动指定的目录"也生效
        if let owners = try? fm.contentsOfDirectory(atPath: engineModelsDir.path) {
            for owner in owners where !owner.hasPrefix(".") {
                let dir = engineModelsDir.appendingPathComponent(owner)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
                    for name in names where !name.hasPrefix(".") { out.insert("\(owner)/\(name)") }
                }
            }
        }

        // 2) HF 缓存：models--<owner>--<name>
        // repo 名里本身可能含 "--"，所以只按第一处分隔（和 huggingface_hub 的解析方式一致）。
        if let entries = try? fm.contentsOfDirectory(atPath: hfHubDir.path) {
            for e in entries where e.hasPrefix("models--") {
                let body = e.dropFirst("models--".count)
                guard let sep = body.range(of: "--") else { continue }
                let owner = String(body[body.startIndex..<sep.lowerBound])
                let name  = String(body[sep.upperBound...])
                if !owner.isEmpty && !name.isEmpty { out.insert("\(owner)/\(name)") }
            }
        }

        var list = out.sorted()
        if list.isEmpty { list = ["incoai/Qwen3.8-27B-Splash", "incoai/Qwen3.6-35B-A3B-Splash"] }
        if !list.contains(cfg.model) { list.append(cfg.model) }
        return list
    }

    // MARK: 动作

    @objc func openWebUI() { NSWorkspace.shared.open(URL(string: baseURL)!) }

    @objc func copyBaseURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(baseURL + "/v1", forType: .string)
    }

    @objc func startService() {
        // 暂停态下"启动"即"继续"
        if Service.paused {
            print("[Splash-MLX] \(Service.resume())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
            return
        }
        starting = true
        rebuildMenu()
        let cfgNow = cfg
        DispatchQueue.global().async { [weak self] in
            let msg = Service.start(cfg: cfgNow)
            print("[Splash-MLX] \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.starting = false
                self?.refresh()
            }
        }
    }

    @objc func pauseService() {
        print("[Splash-MLX] \(Service.pause())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// 端口被外部进程占用时：先杀掉它，再由本 App 重新拉起，纳入托管
    @objc func takeOver() {
        starting = true
        rebuildMenu()
        let cfgNow = cfg
        DispatchQueue.global().async { [weak self] in
            let killed = Service.pidsOnPort()
            for p in killed { kill(p, SIGTERM) }
            Thread.sleep(forTimeInterval: 1.5)
            for p in Service.pidsOnPort() { kill(p, SIGKILL) }
            try? FileManager.default.removeItem(at: pidURL)
            let msg = Service.start(cfg: cfgNow)
            print("[Splash-MLX] take-over: killed external process(es) [\(killed.map(String.init).joined(separator: ","))]; \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.starting = false
                self?.refresh()
            }
        }
    }

    @objc func confirmQuit() {
        let a = NSAlert()
        a.messageText = "Quit Splash-MLX?"
        a.informativeText = """
        Quitting will also stop the inference service:
        \(currentModel)

        Reopen Splash-MLX to start it again.
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "Quit and stop service")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        print("[Splash-MLX] quit: \(Service.stop())")
        NSApp.terminate(nil)
    }

    @objc func toggleModelName() {
        cfg.showModelName.toggle()
        cfg.save()
        applyStatusButton()
    }

    @objc func toggleShowSpeed() {
        cfg.showSpeed.toggle(); cfg.save(); applyStatusButton()
    }

    @objc func stopService() {
        DispatchQueue.global().async { [weak self] in
            let msg = Service.stop()
            print("[Splash-MLX] \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refresh() }
        }
    }

    @objc func restartService() {
        starting = true
        rebuildMenu()
        let cfgNow = cfg
        DispatchQueue.global().async { [weak self] in
            let msg = Service.restart(cfg: cfgNow)
            print("[Splash-MLX] \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.starting = false
                self?.refresh()
            }
        }
    }

    @objc func pickModel(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        setCurrentModel(m); askRestart("Model switched to \(m)")
    }

    @objc func pickCustomModel() {
        let msg = activeEngine == .mlx
            ? "Model directory path, or org/repo from the model library"
            : "Hugging Face repository, in owner/repo form"
        guard let v = askString(title: "Custom model", message: msg,
                                defaultValue: currentModel), !v.isEmpty else { return }
        setCurrentModel(v); askRestart("Model switched to \(v)")
    }

    @objc func pickValue(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        switch sender.tag {
        case kTagMaxMemory:      cfg.maxMemory = v
        case kTagMaxContext:     cfg.maxContext = v
        case kTagPort:           cfg.port = v
        case kTagMaxRequestSize: cfg.maxRequestSize = v
        case kTagMaxImagePixels: cfg.maxImagePixels = v
        case kTagCacheDisk:      cfg.maxCacheDisk = v
        case kTagReasoningEffort: cfg.reasoningEffort = v
        case kTagKvFormat:       cfg.kvFormat = v
        case kTagDraftModel:     cfg.draftModel = v
        case kTagRevision:       cfg.revision = v
        case kTagLanguageOnly:   cfg.languageOnly = (v == "off")
        // ── MLX 专属（写入 cfg.mlx，与 Splash 那套完全隔离）
        case kTagMlxPort:        cfg.mlx.port = v
        case kTagMlxHost:        cfg.mlx.host = v
        case kTagMlxCtx:         cfg.mlx.ctxSize = v
        case kTagMlxKvQuant:     cfg.mlx.kvQuant = v
        case kTagMlxPrefixDisk:  cfg.mlx.prefixCacheDisk = v
        case kTagMlxPrefixMem:   cfg.mlx.prefixCacheMem = v
        case kTagMlxPrefixEnt:   cfg.mlx.prefixCacheEntries = v
        case kTagMlxResident:    cfg.mlx.maxResidentModels = v
        case kTagMlxResidentMem: cfg.mlx.maxResidentMem = v
        case kTagMlxIdle:        cfg.mlx.idleEvictSecs = v
        case kTagMlxDrafter:     cfg.mlx.drafter = v
        case kTagMlxVision:      cfg.mlx.noVision = (v == "off")
        case kTagMlxMetrics:     cfg.mlx.metrics = (v == "on")
        case kTagMlxMTP:         cfg.mlx.mtpMode = v
        case kTagMlxPLD:         cfg.mlx.enablePLD = (v == "on")
        default: return
        }
        cfg.save()
        applyConfig(cfg)          // 端口一改，探测用的 activePort 必须立刻跟上
        askRestart("Setting updated: \(v.isEmpty ? "default" : v)")
    }

    @objc func pickCustom(_ sender: NSMenuItem) {
        let tag = sender.tag
        let info = customSpec(tag)
        guard let v = askString(title: info.title, message: info.message,
                                defaultValue: info.current),
              !v.isEmpty else { return }

        switch tag {
        case kTagMaxMemory:      cfg.maxMemory = v
        case kTagMaxContext:     cfg.maxContext = v
        case kTagPort:
            // 端口必须校验：写进去一个非法值会让服务起不来，而且 lsof 探测也会失效
            guard let n = Int(v.trimmingCharacters(in: .whitespaces)), n >= 1, n <= 65535 else {
                alert(title: "Invalid port", message: "Expected an integer between 1 and 65535, got \"\(v)\"")
                return
            }
            cfg.port = String(n)
        case kTagMaxRequestSize: cfg.maxRequestSize = v
        case kTagMaxImagePixels: cfg.maxImagePixels = v
        case kTagCacheDisk:      cfg.maxCacheDisk = v
        // 既有修复：reasoningEffort 的 Custom… 入口此前会被 default 吞掉（输入不保存）
        case kTagReasoningEffort: cfg.reasoningEffort = v
        case kTagDraftModel:     cfg.draftModel = v
        case kTagRevision:       cfg.revision = v
        default: return
        }
        cfg.save()
        applyConfig(cfg)
        askRestart("Setting updated: \(v)")
    }

    /// 各参数（tag 1…6）对应的自定义弹窗文案与当前值
    private func customSpec(_ tag: Int) -> (title: String, message: String, current: String) {
        switch tag {
        case kTagMaxMemory:      return ("Custom max memory", "e.g. 28G / 512M", cfg.maxMemory)
        case kTagMaxContext:     return ("Custom context length", "e.g. 100K / 32768", cfg.maxContext)
        case kTagPort:           return ("Custom port", "1-65535, e.g. 7000", cfg.port)
        case kTagMaxRequestSize: return ("Custom max request size", "e.g. 64M / 1G", cfg.maxRequestSize)
        case kTagMaxImagePixels: return ("Custom max image pixels", "integer pixel count, e.g. 4194304", cfg.maxImagePixels)
        case kTagCacheDisk:      return ("Custom max cache disk", "e.g. 8G / 12G / 64G", cfg.maxCacheDisk)
        case kTagReasoningEffort: return ("Custom reasoning effort", "none / minimal / low / medium / high / xhigh / max", cfg.reasoningEffort)
        case kTagDraftModel:     return ("Custom draft model", "DFlash2 repo (owner/repo) or local directory", cfg.draftModel)
        case kTagRevision:       return ("Custom model revision", "branch / tag / commit hash", cfg.revision)
        // ── MLX 专属
        case kTagMlxPort:        return ("Custom port", "1-65535, e.g. 11235", cfg.mlx.port)
        case kTagMlxHost:        return ("Custom bind address", "e.g. 0.0.0.0 / 127.0.0.1", cfg.mlx.host)
        case kTagMlxCtx:         return ("Custom context size", "e.g. 32768 / 128K", cfg.mlx.ctxSize)
        case kTagMlxPrefixDisk:  return ("Custom prefix-cache SSD tier", "e.g. 10GB / 32GB", cfg.mlx.prefixCacheDisk)
        case kTagMlxPrefixMem:   return ("Custom prefix-cache memory budget", "e.g. 4GB / 8GB", cfg.mlx.prefixCacheMem)
        case kTagMlxPrefixEnt:   return ("Custom prefix-cache entries", "e.g. 64 / 128", cfg.mlx.prefixCacheEntries)
        case kTagMlxResidentMem: return ("Custom total resident memory cap", "e.g. 64GB / 96GB", cfg.mlx.maxResidentMem)
        case kTagMlxResident:    return ("Custom max resident models", "e.g. 2", cfg.mlx.maxResidentModels)
        case kTagMlxIdle:        return ("Custom idle evict seconds", "e.g. 300", cfg.mlx.idleEvictSecs)
        case kTagMlxDrafter:     return ("Custom drafter directory",
                                         "Gemma 4 assistant or DFlash block-drafter folder", cfg.mlx.drafter)
        default:                 return ("Custom context length", "e.g. 100K / 32768", cfg.maxContext)
        }
    }

    @objc func setAPIKey() {
        guard let v = askString(title: "API Key",
                                message: "Leave empty for no auth. When set, clients must send Authorization: Bearer <key>",
                                defaultValue: cfg.apiKey) else { return }
        cfg.apiKey = v; cfg.save(); askRestart("API key updated")
    }

    @objc func clearAPIKey() { cfg.apiKey = ""; cfg.save(); askRestart("API key cleared") }

    @objc func setHost() {
        guard let v = askString(title: "Allowed host",
                                message: "LAN IP of this Mac (e.g. 192.168.1.20) so other devices can reach it",
                                defaultValue: cfg.allowedHost) else { return }
        cfg.allowedHost = v; cfg.save(); askRestart("Allowed host set: \(v)")
    }

    @objc func clearHost() { cfg.allowedHost = ""; cfg.save(); askRestart("Reverted to localhost only") }

    @objc func setWebUIOn()  { cfg.noWebUI = false; cfg.save(); askRestart("Web UI enabled") }
    @objc func setWebUIOff() { cfg.noWebUI = true;  cfg.save(); askRestart("Web UI disabled") }

    @objc func toggleLoginItem() {
        let wanted = !cfg.loginItem
        do {
            if wanted {
                try SMAppService.mainApp.register()
                cfg.loginItem = true
                cfg.autoStartOnLaunch = true
            } else {
                try SMAppService.mainApp.unregister()
                cfg.loginItem = false
                cfg.autoStartOnLaunch = false
            }
            cfg.save()
        } catch {
            cfg.loginItem = SMAppService.mainApp.status == .enabled
            cfg.save()
            let a = NSAlert()
            a.messageText = "Could not update the login item"
            a.informativeText = """
            \(error.localizedDescription)

            You can add it manually: System Settings → General → Login Items & Extensions → Open at Login → add SplashMLX.app
            """
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refresh()
    }

    @objc func openLogs() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: logErrPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logErrPath) {
            FileManager.default.createFile(atPath: logErrPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logErrPath))
    }

    @objc func openModelDir()  { NSWorkspace.shared.open(engineModelsDir) }
    @objc func openConfigDir() { NSWorkspace.shared.open(appSupportDir) }

    @objc func showAbout() {
        // 版本号只认 Info.plist，避免两处各写一份对不上
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Splash-MLX \(appVer)"
        alert.informativeText = """
        Menu-bar controller for the local Splash inference server

        Engine: running \(Service.runningVersion() ?? "—") · installed \(Service.installedVersion() ?? "—")
        Model: \(currentModel)
        Args: \((activeEngine == .mlx ? cfg.mlx.serveArguments : cfg.serveArguments).joined(separator: " "))
        Process: \(Service.recordedPID.map(String.init) ?? "none")
        Config: \(configURL.path)
        Log: \(logErrPath)
        Login item: \(SMAppService.mainApp.status == .enabled ? "registered" : "not registered")
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 菜单校验（第二道保险）

    /// 兜底：万一某处把 autoenablesItems 又开回来，AppKit 会改调这个方法来决定可用性。
    /// 判定与 rebuildMenu() 里的 isEnabled 走同一套 MenuPolicy，保证两边永不打架。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let snap = Snapshot(served: st.up, owned: Service.managed,
                            paused: Service.paused, starting: starting)
        let p = MenuPolicy(s: snap)
        let a = menuItem.action

        if a == #selector(startService)   { return p.canStart }
        if a == #selector(pauseService)   { return p.canPause }
        if a == #selector(stopService)    { return p.canStop }
        if a == #selector(restartService) { return p.canRestart }
        if a == #selector(takeOver)       { return p.canTakeOver }
        if a == #selector(openWebUI)      { return p.canOpenUI && !cfg.noWebUI }
        if a == #selector(clearAPIKey)    { return !cfg.apiKey.isEmpty }
        // 引擎不认识的参数：哪怕 autoenablesItems 被谁打开了，也不允许点。
        // 走和 rebuildMenu 同一张 tag→flag 表，保证两处判定范围永远一致
        // （曾经这里只兜底 cache-disk，另外两个同样会被过滤掉的 flag 漏了）。
        if let flag = flagForTag(menuItem.tag), !Service.flagAvailable(flag) { return false }
        // 模型包没带对应部件的参数同样不许点（与 gatedSubmenu 的第二道门同源）
        if let gate = capGateForTag(menuItem.tag),
           !gate.present(in: modelCaps(cfg.mlx.resolvedModelPath)) { return false }
        return true
    }

    // MARK: 辅助

    private func askRestart(_ what: String) {
        guard Service.managed || st.up else { refresh(); return }
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = "This takes effect only after the service restarts. Restart now?"
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { restartService() } else { refresh() }
    }

    private func askString(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.stringValue = defaultValue
        alert.accessoryView = tf
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
            ? tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - CLI

private func yn(_ b: Bool) -> String { b ? "✅" : "──" }

/// 终端列宽对齐：CJK 与 emoji 按 2 列算
private func pad(_ s: String, _ width: Int) -> String {
    let w = s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
    return s + String(repeating: " ", count: max(0, width - w))
}

func runCLI(_ argv: [String]) -> Bool {
    guard argv.count >= 2 else { return false }
    let cmd = argv[1]
    switch cmd {
    case "--start", "--stop", "--restart", "--status", "--states", "--takeover",
         "--pause", "--resume", "--login-on", "--login-off", "--dump-menu", "--version-of",
         "--engine-flags", "--models", "--rate":
        break
    case "--help", "-h":
        print("""
        Splash-MLX CLI

          Splash-MLX --status     Show service state and current arguments
          Splash-MLX --start      Start (detached session; survives quitting this app)
          Splash-MLX --pause      Freeze the process group with SIGSTOP (memory stays held)
          Splash-MLX --resume     Thaw with SIGCONT
          Splash-MLX --stop       Stop (kill the whole process group)
          Splash-MLX --restart    Restart
          Splash-MLX --login-on   Register as a login item (launch Splash-MLX and start the service at login)
          Splash-MLX --login-off  Unregister the login item
          Splash-MLX --takeover   Kill the external process holding the port and take it over
          Splash-MLX --states     Print the menu state-machine truth table plus the live state
          Splash-MLX --dump-menu  Build the real menu and recursively print item availability (post-AppKit-validation)
          Splash-MLX --version-of <path>  Run the version parser against an executable path (debug)
          Splash-MLX --engine-flags  List the serve flags this engine accepts, and which get filtered (debug)
          Splash-MLX --models     List locally available Splash packages as the Model submenu sees them (debug)
        """)
        return true
    default:
        return false
    }

    let cfg = Config.load()
    applyConfig(cfg)              // 同上：CLI 也要先同步端口再探测
    switch cmd {
    case "--status":
        let s = Service.status()
        print("config:    \(configURL.path)")
        print("engine:    running \(Service.runningVersion() ?? "—") · installed \(Service.installedVersion() ?? "—")")
        // 按引擎取模型名 —— 原来固定打印 cfg.model（Splash 的字段），
        // 导致跑着 MLX 时 status 里显示的却是 Splash 的模型
        print("model:     \(activeEngine == .mlx ? cfg.mlx.model : cfg.model)")
        print("args:      \(cfg.serveArguments.joined(separator: " "))")
        let state = Service.paused ? "paused"
                  : (s.up ? (Service.managed ? "running (managed)" : "running (external)") : "stopped")
        print("state:     \(state)")
        print("managed:   \(Service.managed ? "pid \(Service.recordedPID!)" : "none")")
        print("http:      \(s.up ? "ok" : "no response")")
        if s.up {
            if activeEngine == .mlx {
                if s.metricsAvailable {
                    // 注意：CLI 每次都是新进程，没有上一次采样做基线，
                    // 所以速率这里永远是 idle —— 要看真实速率得用菜单栏（它有常驻状态）。
                    let sp = s.tps > 0 ? String(format: "%.1f tok/s", s.tps) : "idle"
                    print(String(format: "speed:     %@ · GPU %.0f%% · memory %.1f GB · %d running",
                                 sp, s.gpuPct, s.residentGB, s.reqRunning))
                } else {
                    print("metrics:   unavailable — model not loaded yet?")
                }
            } else {
                print(String(format: "speed:     %.1f tok/s · accept %.1f%% · memory %.1f GB",
                             s.tps, s.accept * 100, s.residentGB))
            }
        }
        print("login:     \(SMAppService.mainApp.status == .enabled ? "registered" : "not registered")")
    case "--start":
        print(Service.start(cfg: cfg))
        Thread.sleep(forTimeInterval: 3)
        print("http: \(Service.status().up ? "ok" : "no response")")
    case "--stop":
        print(Service.stop())
    case "--restart":
        print(Service.restart(cfg: cfg))
    case "--states":
        // 全量真值表：所有可达状态的菜单可用性
        let rows: [(String, Snapshot)] = [
            ("stopped", Snapshot(served: false, owned: false, paused: false, starting: false)),
            ("running (managed)", Snapshot(served: true,  owned: true,  paused: false, starting: false)),
            ("paused (managed)", Snapshot(served: false, owned: true,  paused: true,  starting: false)),
            ("starting (loading)", Snapshot(served: false, owned: true,  paused: false, starting: false)),
            ("external process", Snapshot(served: true,  owned: false, paused: false, starting: false)),
        ]
        print(pad("state", 20) + pad("start", 8) + pad("pause", 8) + pad("stop", 8) + pad("restart", 8) + pad("take", 8) + "WebUI")
        print(String(repeating: "─", count: 70))
        for (name, snap) in rows {
            let p = MenuPolicy(s: snap)
            print(pad(name, 20) + pad(yn(p.canStart), 8) + pad(yn(p.canPause), 8) + pad(yn(p.canStop), 8) + pad(yn(p.canRestart), 8) + pad(yn(p.canTakeOver), 8) + yn(p.canOpenUI))
        }
        print(String(repeating: "─", count: 70))
        let s = Service.status()
        let live = Snapshot(served: s.up, owned: Service.managed,
                            paused: Service.paused, starting: false)
        let lp = MenuPolicy(s: live)
        let label = live.paused ? "paused (managed)" : live.isLoading ? "starting (loading)"
                  : live.isExternal ? "external process" : live.served ? "running (managed)" : "stopped"
        print("live:      \(label)")
        print("           start \(yn(lp.canStart))  pause \(yn(lp.canPause))  stop \(yn(lp.canStop))  restart \(yn(lp.canRestart))  take \(yn(lp.canTakeOver))")
    case "--dump-menu":
        // 走与 App 完全相同的构建路径，再让 AppKit 跑一遍它的启用校验，
        // 打印校验之后的真实结果 —— 这是唯一能证明"置灰真的生效"的方法。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = AppDelegate()
        d.cfg = Config.load()
        d.st = Service.status()
        let menu = d.buildMenu()

        // 递归打印（子菜单也走 AppKit 的校验）；信息行单独标注，便于核对顶部布局
        func walk(_ m: NSMenu, _ indent: String, _ auto: Bool) {
            m.autoenablesItems = auto
            m.update()
            for it in m.items {
                if it.isSeparatorItem { continue }
                if it.tag == kInfoTag {
                    print("\(indent)\(pad("  info", 14))\(it.title)")
                    continue
                }
                // 只用 ✅ / ❌ 做标记：两者都是 Emoji_Presentation，列宽确定为 2。
                // 不要用 ─ 或 ·——它们属于东亚「歧义宽度」，Swift 按 2 算、终端却按 1 渲染，会错列。
                let mark = pad(it.isEnabled ? "✅ enabled" : "❌ disabled", 14)
                let arrow = it.submenu != nil ? "  ▸" : ""
                print("\(indent)\(mark)\(it.title)\(arrow)")
                if let sub = it.submenu { walk(sub, indent + "    ", auto) }
            }
        }

        func dump(_ auto: Bool, _ label: String) {
            print("")
            print("── \(label) ──")
            walk(menu, "  ", auto)
        }
        dump(false, "autoenablesItems = false (what the app runs with)")
        dump(true,  "autoenablesItems = true (AppKit overrides isEnabled)")
    case "--takeover":
        let killed = Service.pidsOnPort()
        for p in killed { kill(p, SIGTERM) }
        Thread.sleep(forTimeInterval: 1.5)
        for p in Service.pidsOnPort() { kill(p, SIGKILL) }
        try? FileManager.default.removeItem(at: pidURL)
        print("killed external process(es) [\(killed.map(String.init).joined(separator: ","))]")
        print(Service.start(cfg: cfg))
        Thread.sleep(forTimeInterval: 3)
        print("http: \(Service.status().up ? "ok" : "no response")")
    case "--pause":
        print(Service.pause())
    case "--models":
        // 调试验证用：看 Model 子菜单会列出哪些本地已有的包，以及它们来自哪个来源
        let fm = FileManager.default
        var hosted = Set<String>(), hf = Set<String>()
        if let owners = try? fm.contentsOfDirectory(atPath: splashModelsDir.path) {
            for o in owners where !o.hasPrefix(".") {
                let d = splashModelsDir.appendingPathComponent(o)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
                for n in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where !n.hasPrefix(".") {
                    hosted.insert("\(o)/\(n)")
                }
            }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: hfHubDir.path) {
            for e in entries where e.hasPrefix("models--") {
                let body = e.dropFirst("models--".count)
                guard let sep = body.range(of: "--") else { continue }
                let o = String(body[body.startIndex..<sep.lowerBound])
                let n = String(body[sep.upperBound...])
                if !o.isEmpty && !n.isEmpty { hf.insert("\(o)/\(n)") }
            }
        }
        print("hf cache: \(hfHubDir.path)")
        print("models dir: \(splashModelsDir.path)")
        print("App-managed: \(hosted.isEmpty ? "(none)" : hosted.sorted().joined(separator: " "))")
        print("HF cache:    \(hf.isEmpty ? "(none)" : hf.sorted().joined(separator: " "))")
        let app = AppDelegate()
        app.cfg = Config.load()
        print("menu lists:")
        if activeEngine == .mlx {
            // MLX 的清单来自 `mlx-serve list`，拿 Splash 的 App/HF 目录去比对毫无意义
            // （那样每一条都会被标成 cfg）。这里改成区分"库里的"和"配置里手填的"。
            print("  (source: `mlx-serve list`，失败时退回扫模型目录)")
            let configured = app.cfg.mlx.model
            for m in app.installedModels() {
                print("  [\(m == configured ? "cfg " : "list")] \(m)")
            }
        } else {
            for m in app.installedModels() {
                let mark = hosted.contains(m) ? "App" : (hf.contains(m) ? "HF " : "cfg")
                print("  [\(mark)] \(m)")
            }
        }
    case "--rate":
        // 调试验证用：在**单个进程**里跑真实的 status() 轮询，并同时发一次生成，
        // 打印每次算出的 tps。菜单栏的速率逻辑必须跨调用才有基线，
        // 单次 --status 永远测不出来（那是新进程、没有 lastMLXSample）。
        print("polling Service.status() while a generation runs…")
        DispatchQueue.global().async {
            // 用当前引擎真实的模型名：MLX 的 API 只认不带 org 的仓库名，
            // Splash 认完整的 owner/repo。原来硬编码 MLX 的名字，切到 Splash 就必然被拒。
            let apiModel = activeEngine == .mlx
                ? String(cfg.mlx.model.split(separator: "/").last ?? "")
                : cfg.model
            let body = "{\"model\":\"" + apiModel + "\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 40.\"}],\"max_tokens\":60}"
            _ = run("/usr/bin/curl", ["-s", "--noproxy", "*", "--max-time", "120",
                                      "-X", "POST", "-H", "Content-Type: application/json",
                                      "-d", body, baseURL + "/v1/chat/completions"])
        }
        for i in 0..<10 {
            let s = Service.status()
            print(String(format: "  t=%2ds  metrics=%@  tps=%6.1f  stale=%3.0f  state=%@",
                         i * 2, s.metricsAvailable ? "yes" : "no", s.tps, s.tpsStaleSeconds,
                         s.up ? "up" : "down"))
            Thread.sleep(forTimeInterval: 2)
        }
        return true
    case "--engine-flags":
        // 调试验证用：看引擎到底认哪些 flag，以及当前配置里有没有被过滤掉的
        let known = Service.serveFlags().sorted()
        print("engine:  \(Service.installedVersion() ?? "?")")
        print("probed:  \(Service.flagsProbed ? "ok" : "FAILED — assuming every flag is supported")")
        print("flags:   \(known.isEmpty ? "(none)" : known.joined(separator: " "))")
        // 逐项列出受门控的参数 —— 范围与顺序都取自 kGatedParams，
        // 也就是菜单置灰 / serveArguments 过滤的同一张表
        // 用当前引擎自己的那张门控表，否则 MLX 下会去查一堆 Splash 专属 flag
        for p in (activeEngine == .mlx ? kMlxGatedParams : kGatedParams) {
            print("  \(Service.flagAvailable(p.flag) ? "✅" : "❌") \(p.flag)")
        }
        // 模型包自带部件（第二道门）：和菜单置灰同一套探测
        if activeEngine == .mlx {
            let path = cfg.mlx.resolvedModelPath
            let caps = modelCaps(path)
            print("model:   \(path.isEmpty ? "(none / on-demand)" : path)")
            print("  \(caps.mtp ? "✅" : "❌") MTP head (mtp/ sidecar or *.mtp.* tensors)")
            print("  \(caps.vision ? "✅" : "❌") vision tower")
        }
        print("args:    \(cfg.serveArguments.joined(separator: " "))")
    case "--version-of":
        // 调试验证用：把一条可执行文件路径喂给版本解析逻辑
        guard argv.count >= 3 else { print("usage: --version-of <path>"); return true }
        print(Service.versionFromPath(argv[2]) ?? "(unrecognized)")
    case "--resume":
        print(Service.resume())
    case "--login-on":
        do {
            try SMAppService.mainApp.register()
            cfg.loginItem = true; cfg.autoStartOnLaunch = true; cfg.save()
            print("login item: registered (status=\(SMAppService.mainApp.status == .enabled ? "enabled" : "notEnabled"))")
        } catch { print("register failed: \(error.localizedDescription)") }
    case "--login-off":
        do {
            try SMAppService.mainApp.unregister()
            cfg.loginItem = false; cfg.autoStartOnLaunch = false; cfg.save()
            print("login item: unregistered")
        } catch { print("unregister failed: \(error.localizedDescription)") }
    default: break
    }
    return true
}

// MARK: - main

if runCLI(CommandLine.arguments) { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
