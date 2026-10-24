import Cocoa

/// 设置类窗口共用的表单视图。
///
/// 更新检查偏好设置曾经把每个说明标签写死 620pt 宽，窗口因此既缩不窄也放不宽：
/// 文本永远按 620 折行，右边留白，且 `minSize` 被钉死在同一个数值上。设置窗口
/// 早先已经解决过同一问题，这里把那两个视图提出来给两个窗口共用，避免第二次
/// 修同一个毛病。

/// `NSScrollView` 的文档视图默认不翻转：内容比视口矮时会贴着底部。
/// 表单类内容需要始终从顶部开始排列。
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 多行说明标签：按当前宽度重新折行。
///
/// AppKit 只按 `preferredMaxLayoutWidth` 计算多行标签的内在高度；写死一个值后，
/// 窗口变宽时文字仍按窄宽度折行，右边留一大片空白。这里在每次布局后把该值更新为
/// 实际宽度，高度和折行位置就都跟着窗口走。
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, preferredMaxLayoutWidth != width else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}

/// 设置类表单的固定度量。
enum SettingsFormMetrics {
    /// 表单列最小宽度；窗口最小宽度 = 该值 + 两侧边距。
    static let minimumWidth: CGFloat = 520
    /// 行内输入控件的最小宽度；只决定“行能多窄”，不决定平时多宽（平时撑满整行）。
    static let fieldMinimumWidth: CGFloat = 200
    /// 表单两侧与上下的边距。
    static let inset: CGFloat = 24
    /// 窗口最小内容尺寸：可以缩到比表单矮，靠滚动查看其余内容。
    static let minimumContentSize = NSSize(width: minimumWidth + inset * 2, height: 320)

    /// 把说明标签配置成可换行、可被压窄的样式。
    ///
    /// 必须降横向抗压优先级：否则单行内在宽度会反过来把窗口拖到 1100pt 宽，
    /// 窗口就再也变不窄了。
    static func configureHint(_ label: NSTextField, color: NSColor = .secondaryLabelColor) {
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.textColor = color
    }
}
