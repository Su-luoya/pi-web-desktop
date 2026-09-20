import Foundation

// MARK: - 检查目标（GitHub #17）

/// 更新检查的分类。每一类都可以按策略独立控制（“服务 → 更新检查设置 → 更新检查
/// 偏好设置…”）：桌面应用 / Pi CLI / Pi Web 为关闭 / 每日 / 每周，扩展包为关闭 /
/// 检查并通知 / 询问后更新；策略定义在 `Sources/UpdateSettings.swift`。

/// Update check value model: categories, targets and the pinned inventory.

enum UpdateCheckCategory: String, CaseIterable, Equatable {
    case desktopApp = "desktop-app"
    case piCLI = "pi"
    case piWeb = "pi-web"
    case piPackages = "pi-packages"

    var displayName: String {
        switch self {
        case .desktopApp: return "桌面应用"
        case .piCLI: return "Pi CLI"
        case .piWeb: return "Pi Web"
        case .piPackages: return "Pi 扩展包"
        }
    }
}

/// 一个被检查对象：分类 + （扩展包才有的）具体包名。
struct UpdateCheckTarget: Equatable, Hashable {
    var category: UpdateCheckCategory
    /// 扩展包的包名（来自 #16 的 `pi list` 解析结果）；其它分类为 nil。
    var packageName: String?

    var id: String {
        if let packageName {
            return "\(category.rawValue):\(packageName)"
        }
        return category.rawValue
    }

    var displayName: String {
        if let packageName {
            return "\(category.displayName) \(packageName)"
        }
        return category.displayName
    }
}

/// `pi list` 报告的一个扩展包及其本机版本。
struct UpdateCheckPackage: Equatable {
    var name: String
    var installedVersion: String?
}

/// 本机已安装版本清单：#16 的组件识别结果是唯一输入。
///
/// 检查器只读这份清单，不自己执行命令，因此 unhosted 测试可以直接构造它，
/// 不触碰真实 `pi` / `npm`。
struct UpdateCheckInventory: Equatable {
    var desktopAppVersion: String?
    var piCLIVersion: String?
    var piWebVersion: String?
    var piPackages: [UpdateCheckPackage]

    init(
        desktopAppVersion: String? = nil,
        piCLIVersion: String? = nil,
        piWebVersion: String? = nil,
        piPackages: [UpdateCheckPackage] = []
    ) {
        self.desktopAppVersion = desktopAppVersion
        self.piCLIVersion = piCLIVersion
        self.piWebVersion = piWebVersion
        self.piPackages = piPackages
    }

    static let empty = UpdateCheckInventory()

    /// 从 #16 的组件识别结果构造。只使用 `kind`、`packageName` 与 `version`：
    /// 路径与证据不进入更新检查，也不会进入缓存。
    init(components: [ComponentInstallation]) {
        var desktopVersion: String?
        var piVersion: String?
        var piWebVersion: String?
        var packages: [UpdateCheckPackage] = []
        var seen: Set<String> = []
        for component in components {
            switch component.kind {
            case .desktopApp:
                if desktopVersion == nil { desktopVersion = component.version }
            case .piCLI:
                if piVersion == nil { piVersion = component.version }
            case .piWeb:
                if piWebVersion == nil { piWebVersion = component.version }
            case .piPackage:
                // 没有包名的条目无法逐包查询（`pi list` 解析失败时 #16 会给出这样
                // 的条目），跳过而不是猜测。
                guard let name = component.packageName, seen.insert(name).inserted else { continue }
                packages.append(UpdateCheckPackage(name: name, installedVersion: component.version))
            }
        }
        self.init(
            desktopAppVersion: desktopVersion,
            piCLIVersion: piVersion,
            piWebVersion: piWebVersion,
            piPackages: packages
        )
    }
}

// MARK: - 上游端点（白名单）

/// 更新检查访问的全部上游。只有这里列出的主机与路径会被请求；仓库外地址、
/// 环境变量或用户输入都不会拼进 URL。
enum UpdateCheckUpstream {
    /// 桌面应用自己的发布仓库（GitHub Releases）。
    static let desktopRepository = "Su-luoya/pi-web-desktop"
    /// Pi CLI 的 npm 包名（与 #6/#16 的安装清单同一来源，不重复字面值）。
    static let piCLIPackageName = InstallCommandManifest.piCLIPackageName
    /// Pi Web 的 npm 包名（同上）。
    static let piWebPackageName = InstallCommandManifest.piWebPackageName

    static let githubHost = "api.github.com"
    static let npmRegistryHost = "registry.npmjs.org"
}

/// 用户可见的更新检查说明（菜单“更新检查说明…”与 `docs/privacy.md` 用同一
/// 组事实：域名、请求内容、策略与默认值、提示方式、忽略语义、受限自动更新、
/// 缓存位置）。
///
/// 措辞约束：只描述版本查询，不把请求称作遥测；版本查询本身不下载、不安装；
/// “启动前自动更新 Pi Web”只在打开且来源与可信度满足时执行一次受限安装，
/// 并明确写出生效范围与不自动回滚。
enum UpdateCheckDisclosure {
    static func text(cachePath: String) -> String {
        let desktopHours = Int(UpdateCheckIntervals.standard.daily / 3600)
        let packageDays = Int(UpdateCheckIntervals.standard.packageCheck / (24 * 3600))
        return """
        更新检查本身只做只读的版本查询，不下载、不安装任何东西；只有下面“启动前自动更新 Pi Web”打开且条件满足时才会执行一次受限安装。

        · 访问的域名：\(UpdateCheckUpstream.githubHost)（桌面应用发布）、\(UpdateCheckUpstream.npmRegistryHost)（Pi CLI、Pi Web 与扩展包）。
        · 请求内容：GET + JSON 解析；User-Agent 只含应用名、版本与 bundle identifier；不发送 cookies、账号凭据、会话内容或诊断信息。
        · 频率：应用启动后立即检查一次；之后桌面应用 / Pi CLI / Pi Web 默认每 \(desktopHours) 小时（每日）、Pi 扩展包默认每 \(packageDays) 天（检查并通知）复查。四类可分别设为关闭 / 每日 / 每周（扩展包为关闭 / 检查并通知 / 询问后更新）；关闭后不发起对应请求，也不安排复查。应用关闭后不检查（不安装 LaunchAgent）。
        · 提示方式：应用内提示框（不使用系统通知中心、不申请通知权限）；提示只含组件名与版本。发现可用更新时最多在本次运行里提示一次，忽略某个版本后不再提示它。
        · 忽略版本：可以逐类忽略当前提示的版本；忽略与安装来源无关，只抑制这一个版本，上游发布更高版本时会再次提示。不实现版本锁定或降级。
        · 启动前自动更新 Pi Web：默认关闭。打开后只对“来源为已验证的 npm 全局安装”的 Pi Web 生效：应用启动时若有**本次运行刚从白名单主机取得**的已验证可用版本，会以参数数组执行 npm install -g <包名>@<版本>（不使用 shell、不调用 sudo、安装有超时），安装后重新检测版本并做健康检查。其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）仍只显示更新命令，绝不自动安装；应用不承诺所有来源都能回滚。
        · 结果缓存：\(cachePath)（只含版本、时间戳与条件请求字段），删除该文件即可清空。缓存不是可信输入（可被同一用户改写），只用于提示；读取时校验结构与上限、不合法就整份丢弃，且不参与自动安装判定。

        版本查询不是遥测：请求只用于比较版本，不会上传使用数据、会话或诊断内容。
        """
    }
}
