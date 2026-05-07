import AppKit

/// `NSSwitch` subclass that carries its associated `Display`, so a target/
/// action handler can recover which display was toggled.
final class DisplaySwitch: NSSwitch {
    var display: Display?
}

@MainActor
protocol DisplayTileDelegate: AnyObject {
    func displayTile(_ tile: DisplayTileView, didToggleEnabled enabled: Bool)
    func displayTile(_ tile: DisplayTileView, didChangeBrightness value: Float)
    func displayTile(_ tile: DisplayTileView, didSetExpanded expanded: Bool)
    func displayTileBrightness(_ tile: DisplayTileView) -> Float?
    func displayTileCanChangeBrightness(_ tile: DisplayTileView) -> Bool
}

/// One row in the popover. Header has icon, name, optional chevron, and an
/// enable/disable switch. When `canChangeBrightness` is `true` the tile is
/// click-to-expand, revealing a brightness slider section. When `false`, no
/// chevron is shown and clicks pass through.
@MainActor
final class DisplayTileView: NSView {
    let display: Display
    private weak var delegate: DisplayTileDelegate?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let switchControl = DisplaySwitch()
    private let headerRow = NSView()

    private let brightnessIcon = NSImageView()
    private let brightnessLabel = NSTextField(labelWithString: "")
    private let brightnessSlider = NSSlider()
    private let expandedContainer = NSStackView()

    private let canToggle: Bool
    private let isExpandable: Bool
    private(set) var isExpanded: Bool

    private static let collapsedHeight: CGFloat = 36
    private static let expandedHeight: CGFloat = 100

    private var heightConstraint: NSLayoutConstraint!

    init(display: Display, activeCount: Int, expanded: Bool, canChangeBrightness: Bool, delegate: DisplayTileDelegate) {
        self.display = display
        self.delegate = delegate
        self.canToggle = !display.isActive || activeCount > 1
        self.isExpandable = canChangeBrightness
        self.isExpanded = canChangeBrightness && expanded
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.collapsedHeight))

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let initialHeight = isExpandable && self.isExpanded ? Self.expandedHeight : Self.collapsedHeight
        heightConstraint = heightAnchor.constraint(equalToConstant: initialHeight)
        heightConstraint.isActive = true

        configureHeader()
        if isExpandable {
            configureExpanded()
        }
        layoutSubviewsManually()
        applyExpandedState(animated: false)
        if isExpandable {
            refreshBrightnessFromSystem()
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let h = (isExpandable && isExpanded) ? Self.expandedHeight : Self.collapsedHeight
        return NSSize(width: 320, height: h)
    }

    // MARK: - Subview configuration

    private func configureHeader() {
        let symbolName = display.isBuiltin ? "laptopcomputer" : "display"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.contentTintColor = canToggle ? .labelColor : .secondaryLabelColor

        titleLabel.stringValue = display.name
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = canToggle ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = canToggle ? nil : "Only active display cannot be disabled"

        chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor

        switchControl.display = display
        switchControl.state = display.isActive ? .on : .off
        switchControl.isEnabled = canToggle
        switchControl.target = self
        switchControl.action = #selector(switchToggled(_:))
    }

    private func configureExpanded() {
        brightnessIcon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        brightnessIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        brightnessIcon.contentTintColor = .secondaryLabelColor

        brightnessLabel.font = .systemFont(ofSize: 11, weight: .regular)
        brightnessLabel.textColor = .secondaryLabelColor
        brightnessLabel.alignment = .right
        brightnessLabel.stringValue = "—"

        brightnessSlider.minValue = 0
        brightnessSlider.maxValue = 1
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged(_:))

        let row = NSStackView(views: [brightnessIcon, brightnessSlider, brightnessLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        brightnessIcon.setContentHuggingPriority(.required, for: .horizontal)
        brightnessLabel.setContentHuggingPriority(.required, for: .horizontal)
        brightnessLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        expandedContainer.orientation = .vertical
        expandedContainer.alignment = .leading
        expandedContainer.spacing = 6
        expandedContainer.distribution = .fill
        expandedContainer.addArrangedSubview(makeSectionLabel("Brightness"))
        expandedContainer.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor).isActive = true
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func layoutSubviewsManually() {
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        switchControl.translatesAutoresizingMaskIntoConstraints = false

        headerRow.addSubview(iconView)
        headerRow.addSubview(titleLabel)
        headerRow.addSubview(switchControl)
        addSubview(headerRow)

        var constraints: [NSLayoutConstraint] = [
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerRow.heightAnchor.constraint(equalToConstant: 28),

            iconView.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            switchControl.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            switchControl.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ]

        if isExpandable {
            chevronView.translatesAutoresizingMaskIntoConstraints = false
            expandedContainer.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(chevronView)
            addSubview(expandedContainer)

            constraints.append(contentsOf: [
                chevronView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
                chevronView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
                chevronView.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -8),

                expandedContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
                expandedContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                expandedContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),
                expandedContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
            ])
        } else {
            // No chevron — let titleLabel run up to the switch.
            constraints.append(
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -8)
            )
        }

        NSLayoutConstraint.activate(constraints)

        switchControl.setContentHuggingPriority(.required, for: .horizontal)
        switchControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: - Behavior

    override func mouseDown(with event: NSEvent) {
        // No expandable content → let the click pass through (still allows
        // the switch to receive its own events).
        guard isExpandable else {
            super.mouseDown(with: event)
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        if switchControl.frame.contains(p) {
            super.mouseDown(with: event)
            return
        }
        if isExpanded, expandedContainer.frame.contains(p) {
            super.mouseDown(with: event)
            return
        }
        isExpanded.toggle()
        applyExpandedState(animated: true)
        delegate?.displayTile(self, didSetExpanded: isExpanded)
        if isExpanded {
            refreshBrightnessFromSystem()
        }
    }

    private func applyExpandedState(animated: Bool) {
        guard isExpandable else {
            heightConstraint.constant = Self.collapsedHeight
            return
        }

        let isExpanding = isExpanded
        chevronView.image = NSImage(
            systemSymbolName: isExpanding ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )

        let targetHeight: CGFloat = isExpanding ? Self.expandedHeight : Self.collapsedHeight

        guard animated else {
            heightConstraint.constant = targetHeight
            expandedContainer.isHidden = !isExpanding
            expandedContainer.alphaValue = isExpanding ? 1 : 0
            return
        }

        // Stage expanded content visible-but-transparent on expand so it can
        // fade in. On collapse, keep visible during shrink and hide at end.
        if isExpanding {
            expandedContainer.isHidden = false
            expandedContainer.alphaValue = 0
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            heightConstraint.animator().constant = targetHeight
            expandedContainer.animator().alphaValue = isExpanding ? 1 : 0
            superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isExpanded {
                    self.expandedContainer.isHidden = true
                }
            }
        })
    }

    private func refreshBrightnessFromSystem() {
        let canChange = delegate?.displayTileCanChangeBrightness(self) ?? false
        brightnessSlider.isEnabled = canChange
        brightnessIcon.contentTintColor = canChange ? .secondaryLabelColor : .tertiaryLabelColor

        if let value = delegate?.displayTileBrightness(self) {
            brightnessSlider.floatValue = value
            brightnessLabel.stringValue = "\(Int((value * 100).rounded()))%"
        } else {
            brightnessLabel.stringValue = canChange ? "—" : "N/A"
        }
    }

    @objc private func switchToggled(_ sender: DisplaySwitch) {
        delegate?.displayTile(self, didToggleEnabled: sender.state == .on)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        let value = sender.floatValue
        brightnessLabel.stringValue = "\(Int((value * 100).rounded()))%"
        delegate?.displayTile(self, didChangeBrightness: value)
    }
}
