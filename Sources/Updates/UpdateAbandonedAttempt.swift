import Foundation

// MARK: - 「已放弃」记录（GitHub #62 / alpha.3 安全审查 A-6、A-7）
//
// 超时之后系统里可能还剩着“本应用启动过、但已经停止等待”的进程：
//
// - Pi Web 的 npm 子进程会随超时被结束一次它**自己的独立进程组**（尽力而为），
//   但派生出来的子进程是否真的结束、什么时候结束，应用没有证据；
// - Pi CLI 与扩展包的更新命令就是 `pi` 本身，超时只放弃等待，绝不发送任何信号，
//   被放弃的命令可能继续在后台运行；
//
// 这个文件把这件事变成一条可持久化的记录，并把它接进判定链：
//
// - 三个适配器（Pi Web / Pi CLI / 扩展包）共用同一个记录类型与同一份存储；
// - `finishedAt` 恒为 nil：语义就是“结束时间未知”，应用不假装知道；
// - 同一组件存在未清除的记录时**不允许自动执行**（硬前置，推迟到下次启动），
//   手动入口仍然可用，但必须在确认框里先看到这条记录；
// - 三个组件互相独立：一个组件的记录不影响其它组件；
// - 应用退出与下次启动都保留记录；只有用户显式清除，或该组件后来成功完成了一次
//   更新，才清除该组件的记录；
// - 记录只含脱敏后的命令摘要、组件、来源、时间与固定文案；不含 Home 绝对路径、
//   环境变量值、子进程输出或凭据。

/// 一条「已放弃」记录：本应用启动过某个更新命令，但已经停止等待，且不知道它
/// 什么时候结束、有没有结束。

struct UpdateAbandonedAttempt: Equatable {
    /// 放弃等待的原因。两者都表示“本应用不再等这个子进程”。
    enum Reason: String, Equatable, CaseIterable {
        /// 达到超时上限。
        case timedOut
        /// 显式放弃等待（例如应用退出）。
        case abandonedWaiting

        var text: String {
            switch self {
            case .timedOut: return "超时"
            case .abandonedWaiting: return "放弃等待（例如应用退出）"
            }
        }
    }

    /// 放弃等待时对本次启动的子进程实际做了什么。三个适配器的差异就在这里，
    /// 记录必须如实写出来，不能让人以为“超时 = 进程已经结束”。
    enum ChildProcessAction: String, Equatable, CaseIterable {
        /// 只放弃等待：没有向任何进程发送任何信号（Pi CLI 与扩展包路径）。
        case waitedWithoutSignals
        /// 已对本次启动的子进程组发送过一次终止信号（仅 Pi Web 的 npm 子进程）。
        case terminatedOwnProcessGroup
        /// 无法为本次子进程建立独立进程组，或系统拒绝了这一次发送：**没有发送任何
        /// 信号**（不允许对共享进程组或其它进程发信号）。
        case processGroupUnavailable

        var text: String {
            switch self {
            case .waitedWithoutSignals:
                return "只放弃等待：没有向任何进程发送任何信号"
            case .terminatedOwnProcessGroup:
                return "已对本次启动的 npm 子进程组发送过一次终止信号（尽力而为），未确认派生进程是否结束"
            case .processGroupUnavailable:
                return "没有发送任何信号（无法确认本次子进程在它自己的独立进程组里，或系统拒绝了这一次发送）"
                    + "：未确认派生进程是否结束"
            }
        }
    }

    /// 命令摘要的长度上限（与进程摘要同一量级）。
    static let commandSummaryLimit = 200
    /// 超时值的可接受上界（秒）；超出范围的记录读回时视为不可信。
    static let maximumTimeout: TimeInterval = 24 * 60 * 60

    var componentKind: ComponentKind
    /// 只有扩展包有包名；必须是已通过 npm 包名校验的字符串。
    var packageName: String?
    var reason: Reason
    /// 脱敏后的命令摘要（可执行文件路径已把 Home 前缀换成 `~`）。
    var commandSummary: String
    /// 命令开始执行的时间（本应用自己的时钟）。
    var startedAt: Date
    /// 本次执行的超时上限（秒）。
    var timeout: TimeInterval
    /// 结束时间。**恒为 nil**：应用不知道那个进程什么时候结束。
    var finishedAt: Date?
    var source: InstallSource
    /// 记录写入的时间。
    var recordedAt: Date
    var childProcessAction: ChildProcessAction
    /// 派生进程是否已确认结束。**恒为 nil**：应用没有证据确认，因此记录“未知”。
    var derivedProcessesConfirmedEnded: Bool?

    init(
        componentKind: ComponentKind,
        packageName: String?,
        reason: Reason,
        commandSummary: String,
        startedAt: Date,
        timeout: TimeInterval,
        finishedAt: Date? = nil,
        source: InstallSource,
        recordedAt: Date,
        childProcessAction: ChildProcessAction,
        derivedProcessesConfirmedEnded: Bool? = nil
    ) {
        self.componentKind = componentKind
        self.packageName = packageName
        self.reason = reason
        self.commandSummary = commandSummary
        self.startedAt = startedAt
        self.timeout = timeout
        self.finishedAt = finishedAt
        self.source = source
        self.recordedAt = recordedAt
        self.childProcessAction = childProcessAction
        self.derivedProcessesConfirmedEnded = derivedProcessesConfirmedEnded
    }

    /// 记录所属组件（与更新历史/更新事务使用同一个组件模型）。
    var component: UpdateTransactionComponent {
        UpdateTransactionComponent(kind: componentKind, packageName: packageName)
    }

    var displayName: String { component.displayName }

    /// 记录类型是否可信：只有三个“应用自己启动命令”的组件会产生记录。
    var hasRecordableComponent: Bool {
        switch componentKind {
        case .piWeb, .piCLI: return true
        case .piPackage: return packageName.flatMap(ComponentInstallationDetector.isPackageName) != nil
        case .desktopApp: return false
        }
    }

    /// 脱敏后的命令摘要。可执行文件路径由调用方用 `LogRedactor` 处理后再传入；
    /// 这里只做长度截断、控制字符剔除与空白折叠。
    static func makeCommandSummary(
        executablePath: String,
        arguments: [String],
        redactingWith redact: (String) -> String
    ) -> String {
        let commandText = ([executablePath] + arguments).joined(separator: " ")
        let redacted = redact(commandText)
        let collapsed = redacted
            .unicodeScalars
            .filter { !($0.value < 0x20 || $0.value == 0x7F) }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(commandSummaryLimit))
    }
}

// MARK: - 存储

/// 「已放弃」记录的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
///
/// 存储形状与统一更新历史（`UpdateHistoryStore`）同构：单键 JSON + 显式字段 +
/// 读回校验。Pi Web / Pi CLI 各一个槽位（同组件最多一条），扩展包一个槽位（按
/// 包名，容量与更新历史一致）。读取时任何字段不可信就丢弃整条记录，而不是把
/// 可疑文本展示给用户。
enum UpdateAbandonedAttemptStore {
    /// 扩展包记录的条数上限。
    static let maximumPackageRecords = 20
    /// 展示文本里时间字段的可接受范围起点（早于此时间的记录视为不可信）。
    static let earliestRecordedAt = Date(timeIntervalSince1970: 1_000_000_000)

    /// 全部组件的记录（顺序：Pi Web、Pi CLI、扩展包按包名）。
    static func load(from defaults: UserDefaults) -> [UpdateAbandonedAttempt] {
        var result: [UpdateAbandonedAttempt] = []
        if let attempt = loadSingle(
            key: UpdateSettingKeys.piWebAbandonedAttempt,
            kind: .piWeb,
            from: defaults
        ) {
            result.append(attempt)
        }
        if let attempt = loadSingle(
            key: UpdateSettingKeys.piCLIAbandonedAttempt,
            kind: .piCLI,
            from: defaults
        ) {
            result.append(attempt)
        }
        result.append(contentsOf: loadPackages(from: defaults))
        return result
    }

    /// 指定组件的记录；没有或不可信时返回 nil。
    static func load(
        component: UpdateTransactionComponent,
        from defaults: UserDefaults
    ) -> UpdateAbandonedAttempt? {
        load(from: defaults).first { $0.component == component }
    }

    /// 写入（或覆盖同组件的旧记录）。
    static func save(_ attempt: UpdateAbandonedAttempt, to defaults: UserDefaults) {
        guard attempt.hasRecordableComponent, let stored = valid(attempt) else { return }
        switch stored.componentKind {
        case .piWeb:
            write(stored, key: UpdateSettingKeys.piWebAbandonedAttempt, to: defaults)
        case .piCLI:
            write(stored, key: UpdateSettingKeys.piCLIAbandonedAttempt, to: defaults)
        case .piPackage:
            var records = loadPackages(from: defaults).filter { $0.component != stored.component }
            records.insert(stored, at: 0)
            records = Array(records.prefix(maximumPackageRecords))
            guard let data = encode(records) else { return }
            defaults.set(data, forKey: UpdateSettingKeys.piPackageAbandonedAttempts)
        case .desktopApp:
            return
        }
    }

    /// 清除指定组件的记录（用户显式清除，或该组件后来成功完成了一次更新）。
    static func clear(component: UpdateTransactionComponent, from defaults: UserDefaults) {
        switch component.kind {
        case .piWeb:
            defaults.removeObject(forKey: UpdateSettingKeys.piWebAbandonedAttempt)
        case .piCLI:
            defaults.removeObject(forKey: UpdateSettingKeys.piCLIAbandonedAttempt)
        case .piPackage:
            let remaining = loadPackages(from: defaults).filter { $0.component != component }
            if remaining.isEmpty {
                defaults.removeObject(forKey: UpdateSettingKeys.piPackageAbandonedAttempts)
            } else if let data = encode(remaining) {
                defaults.set(data, forKey: UpdateSettingKeys.piPackageAbandonedAttempts)
            }
        case .desktopApp:
            return
        }
    }

    /// 清除全部记录（“已放弃的更新记录…”菜单里的显式清除）。
    static func clearAll(from defaults: UserDefaults) {
        for key in UpdateSettingKeys.allAbandonedAttemptKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// 写入时同样做一次校验：不把不受控文本写进 UserDefaults。
    static func encode(_ attempts: [UpdateAbandonedAttempt]) -> Data? {
        try? JSONEncoder().encode(attempts.map(StoredAttempt.init(attempt:)))
    }

    static func decode(_ data: Data) -> [UpdateAbandonedAttempt]? {
        guard let stored = try? JSONDecoder().decode([StoredAttempt].self, from: data) else { return nil }
        return stored.compactMap { $0.attempt() }
    }

    // MARK: - 内部

    private static func loadSingle(
        key: String,
        kind: ComponentKind,
        from defaults: UserDefaults
    ) -> UpdateAbandonedAttempt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let attempts = decode(data) else { return nil }
        return attempts.first { $0.componentKind == kind }
    }

    private static func loadPackages(from defaults: UserDefaults) -> [UpdateAbandonedAttempt] {
        guard let data = defaults.data(forKey: UpdateSettingKeys.piPackageAbandonedAttempts),
              let attempts = decode(data) else { return [] }
        return attempts
            .filter { $0.componentKind == .piPackage }
            .prefix(maximumPackageRecords)
            .map { $0 }
    }

    private static func write(_ attempt: UpdateAbandonedAttempt, key: String, to defaults: UserDefaults) {
        guard let data = encode([attempt]) else { return }
        defaults.set(data, forKey: key)
    }

    /// 读回/写入前的字段校验：任何一个字段不可信就整条丢弃。
    static func valid(_ attempt: UpdateAbandonedAttempt) -> UpdateAbandonedAttempt? {
        guard attempt.hasRecordableComponent else { return nil }
        // `finishedAt` 必须为空：这条记录的语义就是“结束时间未知”。写入了结束
        // 时间的记录不是本类型能表达的语义，视为不可信。
        guard attempt.finishedAt == nil else { return nil }
        guard attempt.derivedProcessesConfirmedEnded == nil else { return nil }
        guard let summary = clippedCommandSummary(attempt.commandSummary) else { return nil }
        guard attempt.timeout > 0, attempt.timeout <= UpdateAbandonedAttempt.maximumTimeout else { return nil }
        guard attempt.startedAt >= earliestRecordedAt, attempt.recordedAt >= earliestRecordedAt else { return nil }
        guard attempt.childProcessAction.isRecordable(for: attempt) else { return nil }
        var copy = attempt
        copy.commandSummary = summary
        return copy
    }

    /// 摘要必须非空、长度有界、无控制字符；否则视为不可信。
    private static func clippedCommandSummary(_ text: String) -> String? {
        let filtered = text.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7F) }
        let value = String(String.UnicodeScalarView(filtered))
        let clipped = String(value.prefix(UpdateAbandonedAttempt.commandSummaryLimit))
        return clipped.isEmpty ? nil : clipped
    }

    /// JSON 存储形状：显式字段，避免把任意 Enum 原始值直接落盘。
    private struct StoredAttempt: Codable {
        var componentKind: String
        var packageName: String?
        var reason: String
        var commandSummary: String
        var startedAt: Double
        var timeout: Double
        var finishedAt: Double?
        var source: String
        var recordedAt: Double
        var childProcessAction: String
        var derivedProcessesConfirmedEnded: Bool?

        init(attempt: UpdateAbandonedAttempt) {
            componentKind = attempt.componentKind.rawValue
            packageName = attempt.packageName
            reason = attempt.reason.rawValue
            commandSummary = attempt.commandSummary
            startedAt = attempt.startedAt.timeIntervalSince1970
            timeout = attempt.timeout
            finishedAt = attempt.finishedAt?.timeIntervalSince1970
            source = attempt.source.rawValue
            recordedAt = attempt.recordedAt.timeIntervalSince1970
            childProcessAction = attempt.childProcessAction.rawValue
            derivedProcessesConfirmedEnded = attempt.derivedProcessesConfirmedEnded
        }

        func attempt() -> UpdateAbandonedAttempt? {
            guard let kind = ComponentKind(rawValue: componentKind),
                  let reason = UpdateAbandonedAttempt.Reason(rawValue: reason),
                  let action = UpdateAbandonedAttempt.ChildProcessAction(rawValue: childProcessAction) else { return nil }
            return UpdateAbandonedAttemptStore.valid(UpdateAbandonedAttempt(
                componentKind: kind,
                packageName: packageName,
                reason: reason,
                commandSummary: commandSummary,
                startedAt: Date(timeIntervalSince1970: startedAt),
                timeout: timeout,
                finishedAt: finishedAt.map(Date.init(timeIntervalSince1970:)),
                source: InstallSource(rawValue: source) ?? .unknown,
                recordedAt: Date(timeIntervalSince1970: recordedAt),
                childProcessAction: action,
                derivedProcessesConfirmedEnded: derivedProcessesConfirmedEnded
            ))
        }
    }
}

private extension UpdateAbandonedAttempt.ChildProcessAction {
    /// 动作必须与组件匹配：只有 Pi Web 可能对子进程组发过信号，Pi CLI 与扩展包
    /// 的链路不许出现“发送过信号”的记录。
    func isRecordable(for attempt: UpdateAbandonedAttempt) -> Bool {
        switch self {
        case .waitedWithoutSignals:
            return attempt.componentKind == .piCLI
                || attempt.componentKind == .piPackage
                || attempt.componentKind == .piWeb
        case .terminatedOwnProcessGroup, .processGroupUnavailable:
            return attempt.componentKind == .piWeb
        }
    }
}

// MARK: - 重叠防护（硬前置）

/// 同一组件的「已放弃」记录 → 是否禁止自动执行。三个组件互相独立。
enum UpdateAbandonedAttemptGate {
    /// 该组件的未清除记录；nil 表示没有阻断项。
    static func blockingAttempt(
        for component: UpdateTransactionComponent,
        in attempts: [UpdateAbandonedAttempt]
    ) -> UpdateAbandonedAttempt? {
        attempts.first { $0.component == component }
    }

    /// 是否允许该组件自动执行（手动入口不受这里约束）。
    static func allowsAutomaticExecution(
        for component: UpdateTransactionComponent,
        in attempts: [UpdateAbandonedAttempt]
    ) -> Bool {
        blockingAttempt(for: component, in: attempts) == nil
    }
}

// MARK: - 展示

/// 「已放弃」记录的用户可见文本（诊断页、偏好设置、手动确认框共用）。
///
/// 全部字段都是固定文案 + 已校验的组件名/包名/来源/时间；命令摘要已经过
/// `LogRedactor`，因此这里不再拼接任何绝对路径。
enum UpdateAbandonedAttemptPresenter {
    /// 没有注入格式器时的稳定时间格式（诊断/日志/拒绝原因都用它）。
    static func defaultFormat(_ date: Date) -> String {
        defaultFormatter.string(from: date)
    }

    private static let defaultFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 单行摘要（菜单/状态行）。
    static func summaryLine(
        for attempt: UpdateAbandonedAttempt,
        format: (Date) -> String = UpdateAbandonedAttemptPresenter.defaultFormat
    ) -> String {
        "\(attempt.displayName)：\(attempt.reason.text)，开始 \(format(attempt.startedAt))，结束时间未知"
    }

    /// 完整记录（组件、命令摘要、开始时间、超时、结束时间未知、实际动作、来源）。
    static func lines(
        for attempt: UpdateAbandonedAttempt,
        format: (Date) -> String = UpdateAbandonedAttemptPresenter.defaultFormat
    ) -> [String] {
        [
            "【已放弃的更新记录】组件：\(attempt.displayName)",
            "命令摘要：\(attempt.commandSummary)",
            "开始时间：\(format(attempt.startedAt))",
            "放弃原因：\(attempt.reason.text)",
            "超时上限：\(timeoutText(attempt.timeout))",
            "结束时间：未知（应用已经停止等待，不知道那个进程什么时候结束、有没有结束）",
            "本次实际动作：\(attempt.childProcessAction.text)",
            "来源：\(attempt.source.displayName)；记录时间：\(format(attempt.recordedAt))"
        ]
    }

    /// 自动路径被这条记录挡住时的可读原因与建议。
    static func automaticRefusalText(
        _ attempt: UpdateAbandonedAttempt,
        format: (Date) -> String = UpdateAbandonedAttemptPresenter.defaultFormat
    ) -> String {
        "\(attempt.displayName)存在未清除的「已放弃」记录（\(attempt.reason.text)；"
            + "开始 \(format(attempt.startedAt))；超时上限 \(timeoutText(attempt.timeout))；结束时间未知；"
            + attempt.childProcessAction.text + "）。"
            + "同一组件在清除这条记录前不会自动执行更新，本次推迟到下次启动；"
            + "手动入口不受影响，但会在确认框里先展示这条记录，需要显式确认后才执行。"
    }

    /// 手动确认框里的记录块：确认前必须能看到的内容。
    static func confirmationBlock(
        for attempt: UpdateAbandonedAttempt,
        format: (Date) -> String = UpdateAbandonedAttemptPresenter.defaultFormat
    ) -> String {
        var lines = lines(for: attempt, format: format)
        lines.append("这条记录不会被自动清除：只有用户显式清除，或该组件后来成功完成了一次更新，才会清除。")
        lines.append("确认后将执行一次本次更新；应用不会结束、暂停或接管任何 Pi 进程与会话。")
        return lines.joined(separator: "\n")
    }

    /// 全部记录的展示块；没有记录时返回 nil。
    static func block(
        for attempts: [UpdateAbandonedAttempt],
        format: (Date) -> String = UpdateAbandonedAttemptPresenter.defaultFormat
    ) -> String? {
        guard !attempts.isEmpty else { return nil }
        var result: [String] = ["已放弃等待的更新命令（结束时间未知）：\(attempts.count) 条"]
        for attempt in attempts {
            result.append("")
            result.append(contentsOf: UpdateAbandonedAttemptPresenter.lines(for: attempt, format: format))
        }
        result.append("")
        result.append(
            "这些记录不会阻止手动更新；自动更新在清除记录前不会执行。"
                + "清除方式：菜单“服务 → 更新检查设置 → 已放弃的更新记录…”。"
        )
        return result.joined(separator: "\n")
    }

    static func timeoutText(_ timeout: TimeInterval) -> String {
        let rounded = timeout.rounded()
        if abs(timeout - rounded) < 0.05 {
            return "\(Int(rounded)) 秒"
        }
        return String(format: "%.1f 秒", timeout)
    }
}
