import AppKit
import MiscKitCore

/// 状态菜单里的「标题 + 右侧开关」行。
///
/// 菜单项一旦挂了自定义 view，AppKit 就不再画标题、勾选和高亮，全得自己做：
/// 高亮由 `NSMenuDelegate.menu(_:willHighlight:)` 驱动（鼠标与键盘都走它），
/// 自己再补一层鼠标跟踪，键盘高亮和指针悬停都不至于看不出来。
///
/// 开关是自己画的：系统 `NSSwitch` 在这一版是 54×24，塞进菜单比标题高出一大截；
/// 这里按 38×20 画，并且在高亮行上补一圈白描边，否则蓝轨道会融进蓝底。
final class MenuSwitchRow: NSView {
    let kind: ReminderKind
    let toggle = MenuToggle()

    weak var menuItem: NSMenuItem?

    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
            titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            toggle.isRowHighlighted = isHighlighted
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?

    init(kind: ReminderKind, title: String, isOn: Bool, target: AnyObject, action: Selector) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 202, height: 30))
        autoresizingMask = [.width]

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        toggle.isOn = isOn
        toggle.target = target
        toggle.action = action
        toggle.setAccessibilityLabel(title)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 38),
            toggle.heightAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    /// 点标题也算点这一行：不关菜单，两个开关可以连着改。
    override func mouseUp(with event: NSEvent) {
        guard let action = toggle.action else { return }
        NSApp.sendAction(action, to: toggle.target, from: toggle)
    }

    /// 验收用：把这一行自己画成位图（不需要屏幕录制权限；菜单原生高亮不在其中）。
    func debugCapture(to path: String, highlighted: Bool) {
        let previous = isHighlighted
        isHighlighted = highlighted
        layoutSubtreeIfNeeded()
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                NSLog("[menu] row captured %@ %dx%d", path, rep.pixelsWide, rep.pixelsHigh)
            }
        }
        isHighlighted = previous
    }
}

/// 菜单里的开关：38×20 的胶囊 + 白色圆钮，配色跟系统开关一致（开=强调色，关=三级文字色）。
final class MenuToggle: NSControl {
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            needsDisplay = true
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    var isRowHighlighted = false {
        didSet {
            guard oldValue != isRowHighlighted else { return }
            needsDisplay = true
        }
    }

    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let trackRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = trackRect.height / 2
        let track = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)

        if isOn {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor.tertiaryLabelColor.setFill()
        }
        track.fill()

        // 选中行整行是强调色，蓝轨道会淹没；补一圈白描边把轮廓拉回来
        if isOn && isRowHighlighted {
            NSColor.selectedMenuItemTextColor.setStroke()
            track.lineWidth = 1
            track.stroke()
        }

        let diameter = bounds.height - 3
        let knobX = isOn ? bounds.width - diameter - 1.5 : 1.5
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: 1.5, width: diameter, height: diameter))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isPressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
