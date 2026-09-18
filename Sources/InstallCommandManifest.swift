import Foundation

/// 依赖修复建议的静态清单（GitHub #6）。
///
/// 这是应用里唯一一处“安装命令”文本：编译期常量，不联网、不根据诊断结果动态
/// 生成，也不读取任何认证内容。诊断界面只展示和复制这些常量，应用自身绝不执行
/// 安装命令、绝不调用 `sudo`。请与 README 的 Prerequisites 一节保持一致。
enum InstallCommandManifest {
    /// Node.js 最低版本要求的唯一来源，`DependencyChecker` 直接引用。
    static let minimumNodeVersion = SemanticVersion(major: 22, minor: 19, patch: 0)

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

    static func entry(withID id: String) -> Entry? {
        all.first { $0.id == id }
    }
}
