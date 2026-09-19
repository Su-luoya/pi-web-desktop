import Foundation

/// 依赖修复建议的静态清单（GitHub #6）。
///
/// 这是应用里唯一一处“安装命令”文本：编译期常量，不联网、不根据诊断结果动态
/// 生成，也不读取任何认证内容。诊断界面只展示和复制这些常量，应用自身绝不执行
/// 安装命令、绝不调用 `sudo`。请与 README 的 Prerequisites 一节保持一致。
enum InstallCommandManifest {
    /// Node.js 最低版本要求的唯一来源，`DependencyChecker` 直接引用。
    static let minimumNodeVersion = SemanticVersion(major: 22, minor: 19, patch: 0)

    /// 上游包名的唯一来源：安装命令文本与组件识别（GitHub #16）的包名核对共用。
    static let piCLIPackageName = "@earendil-works/pi-coding-agent"
    static let piWebPackageName = "@agegr/pi-web"

    struct Entry: Equatable {
        /// 诊断结果 `remediationID` 引用的稳定标识。
        let id: String
        let title: String
        /// 可直接复制的安装命令；为 nil 表示只提供说明和官方文档，不提供命令。
        let command: String?
        let note: String
        let documentationURL: String
    }

    static let node = Entry(
        id: "install.node",
        title: "Node.js",
        command: nil,
        note: "需要 Node.js \(minimumNodeVersion) 或更高版本。请按官方文档安装或升级，应用不会自动安装 Node.js。",
        documentationURL: "https://nodejs.org/en/download"
    )

    static let piCLI = Entry(
        id: "install.pi",
        title: "Pi CLI",
        command: "npm install -g --ignore-scripts @earendil-works/pi-coding-agent",
        note: "Pi CLI 与 Pi Web 是两个不同的包，都需要安装。安装前请核对上游文档与包元数据。",
        documentationURL: "https://www.npmjs.com/package/@earendil-works/pi-coding-agent"
    )

    static let piWeb = Entry(
        id: "install.pi-web",
        title: "Pi Web",
        command: "npm install -g @agegr/pi-web",
        note: "Pi Web 是应用要启动的服务；安装前请核对上游文档与包元数据。",
        documentationURL: "https://github.com/agegr/pi-web"
    )

    /// 展示顺序固定：Node.js → Pi CLI → Pi Web。
    static let all: [Entry] = [node, piCLI, piWeb]

    // MARK: - 组件更新指引（GitHub #16）

    /// 按来源给出的更新命令；只有 npm/pnpm 全局来源带 `command`。
    /// 其余来源全部为 nil，由界面显示“请按来源文档更新”。
    static let updateNPMPiCLI = Entry(
        id: "update.pi.npm-global",
        title: "Pi CLI（npm 全局）",
        command: "npm install -g --ignore-scripts \(piCLIPackageName)",
        note: "来源是 npm 全局：用同一个包管理器更新该包即可。执行前请核对上游文档与包元数据。",
        documentationURL: "https://www.npmjs.com/package/\(piCLIPackageName)"
    )

    static let updateNPMPiWeb = Entry(
        id: "update.pi-web.npm-global",
        title: "Pi Web（npm 全局）",
        command: "npm install -g \(piWebPackageName)",
        note: "来源是 npm 全局：用同一个包管理器更新该包即可。执行前请核对上游文档与包元数据。",
        documentationURL: "https://github.com/agegr/pi-web"
    )

    static let updatePNPMPiCLI = Entry(
        id: "update.pi.pnpm-global",
        title: "Pi CLI（pnpm 全局）",
        command: "pnpm add -g \(piCLIPackageName)",
        note: "来源是 pnpm 全局：用 pnpm 更新该包，不要换用其它包管理器。执行前请核对上游文档与包元数据。",
        documentationURL: "https://www.npmjs.com/package/\(piCLIPackageName)"
    )

    static let updatePNPMPiWeb = Entry(
        id: "update.pi-web.pnpm-global",
        title: "Pi Web（pnpm 全局）",
        command: "pnpm add -g \(piWebPackageName)",
        note: "来源是 pnpm 全局：用 pnpm 更新该包，不要换用其它包管理器。执行前请核对上游文档与包元数据。",
        documentationURL: "https://github.com/agegr/pi-web"
    )

    /// Pi 扩展包没有固定包名：只给指引，不给命令（命令必须来自静态清单，
    /// 不能根据包名动态拼接）。
    static let updatePiPackage = Entry(
        id: "update.pi-package.documentation",
        title: "Pi 扩展包",
        command: nil,
        note: "Pi 扩展包由各自上游发布：请按该包自己的官方文档更新；应用不会代为执行任何命令。",
        documentationURL: "https://www.npmjs.com/"
    )

    static let updateHomebrew = Entry(
        id: "update.homebrew.documentation",
        title: "Homebrew",
        command: nil,
        note: "来源是 Homebrew（Cellar/opt 结构）：请用 Homebrew 按来源文档升级对应 formula，然后重新检测；应用不会代为执行。",
        documentationURL: "https://docs.brew.sh/FAQ"
    )

    static let updateNVM = Entry(
        id: "update.nvm.documentation",
        title: "nvm",
        command: nil,
        note: "来源是 nvm 管理的 Node 版本：请先切换到目标 Node 版本，再用该版本自带的 npm 更新；应用不会代为执行。",
        documentationURL: "https://github.com/nvm-sh/nvm"
    )

    static let updateMise = Entry(
        id: "update.mise.documentation",
        title: "mise",
        command: nil,
        note: "来源是 mise 管理的安装目录：请用 mise 按来源文档切换或升级工具版本；应用不会代为执行。",
        documentationURL: "https://mise.jdx.dev/"
    )

    static let updateGitCheckout = Entry(
        id: "update.git-checkout.documentation",
        title: "git checkout",
        command: nil,
        note: "来源是 git checkout：请在仓库目录执行 git pull，并按上游 README 重新构建或链接；应用不会代为执行。",
        documentationURL: "https://github.com/agegr/pi-web"
    )

    static let updateOfficialInstaller = Entry(
        id: "update.official-installer.documentation",
        title: "官方安装器",
        command: nil,
        note: "来源是官方安装器或发布产物：请按官方发布说明更新；应用不会代为执行。",
        documentationURL: "https://github.com/Su-luoya/pi-web-desktop/releases"
    )

    static let updateLocalPath = Entry(
        id: "update.local-path.documentation",
        title: "本地路径",
        command: nil,
        note: "来源是本地路径：应用不会自动更新，请按来源文档更新后重新检测。",
        documentationURL: "https://github.com/agegr/pi-web"
    )

    static let updateUnknown = Entry(
        id: "update.unknown.documentation",
        title: "来源未知",
        command: nil,
        note: "来源无法确认：为避免用错包管理器，应用不给出更新命令。请先确认来源，再按来源文档更新。",
        documentationURL: "https://github.com/agegr/pi-web"
    )

    /// 按“组件种类 + 安装来源”给出的更新指引。
    ///
    /// 只有 npm/pnpm 全局来源返回带 `command` 的条目；Homebrew、nvm/mise、
    /// git checkout、本地路径、官方安装器与未知来源一律返回 `command == nil`
    /// 的指引条目。因此不存在“非 npm 安装却统一给出 npm install -g”的路径。
    static func updateGuidance(for kind: ComponentKind, source: InstallSource) -> Entry? {
        switch source {
        case .npmGlobal:
            switch kind {
            case .piCLI: return updateNPMPiCLI
            case .piWeb: return updateNPMPiWeb
            case .piPackage, .desktopApp: return updatePiPackage
            }
        case .pnpmGlobal:
            switch kind {
            case .piCLI: return updatePNPMPiCLI
            case .piWeb: return updatePNPMPiWeb
            case .piPackage, .desktopApp: return updatePiPackage
            }
        case .homebrew: return updateHomebrew
        case .nvm: return updateNVM
        case .mise: return updateMise
        case .gitCheckout: return updateGitCheckout
        case .officialInstaller: return updateOfficialInstaller
        case .localPath: return updateLocalPath
        case .unknown: return updateUnknown
        }
    }

    static func entry(withID id: String) -> Entry? {
        (all + updateGuidanceEntries).first { $0.id == id }
    }

    /// 更新指引条目的固定顺序（与来源枚举顺序一致）。
    static let updateGuidanceEntries: [Entry] = [
        updateNPMPiCLI, updateNPMPiWeb, updatePNPMPiCLI, updatePNPMPiWeb, updatePiPackage,
        updateHomebrew, updateNVM, updateMise, updateGitCheckout, updateOfficialInstaller,
        updateLocalPath, updateUnknown
    ]
}
