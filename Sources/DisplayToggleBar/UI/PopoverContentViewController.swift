import AppKit

/// `NSButton` that fires a closure on click. Avoids the target/action
/// boilerplate at every call site.
@MainActor
final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func invoke() {
        closure()
    }
}

/// Root view controller hosted inside the status-bar `NSPopover`. Lays out a
/// vertical stack of `DisplayTileView`s, a separator, and a footer with
/// Refresh / Quit buttons. The popover sizes itself to the view's
/// `fittingSize`, so tile expand/collapse animations naturally drive popover
/// resizing.
@MainActor
final class PopoverContentViewController: NSViewController {
    private static let popoverWidth: CGFloat = 320

    var refreshAction: (() -> Void)?
    var quitAction: (() -> Void)?

    private let tilesStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No displays found")
    private let separator = NSBox()
    private let footerStack = NSStackView()

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        tilesStack.orientation = .vertical
        tilesStack.alignment = .leading
        tilesStack.distribution = .fill
        tilesStack.spacing = 4
        tilesStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = makeFooterButton(title: "Refresh", systemImage: "arrow.clockwise") { [weak self] in
            self?.refreshAction?()
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let quitButton = makeFooterButton(title: "Quit", systemImage: "power") { [weak self] in
            self?.quitAction?()
        }

        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(refreshButton)
        footerStack.addArrangedSubview(spacer)
        footerStack.addArrangedSubview(quitButton)

        root.addSubview(tilesStack)
        root.addSubview(emptyLabel)
        root.addSubview(separator)
        root.addSubview(footerStack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.popoverWidth),

            tilesStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tilesStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tilesStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            emptyLabel.topAnchor.constraint(equalTo: tilesStack.topAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: tilesStack.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            separator.heightAnchor.constraint(equalToConstant: 1),

            footerStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footerStack.heightAnchor.constraint(equalToConstant: 28)
        ])

        self.view = root
    }

    func setTiles(_ tiles: [DisplayTileView], hasDisplays: Bool) {
        // Drop the previous tiles so we don't accumulate.
        for view in tilesStack.arrangedSubviews {
            tilesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        emptyLabel.isHidden = hasDisplays

        for tile in tiles {
            tilesStack.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: tilesStack.widthAnchor).isActive = true
        }

        // Force the view to layout so the popover picks up the new content size
        // immediately on first show.
        view.layoutSubtreeIfNeeded()
    }

    private func makeFooterButton(title: String, systemImage: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}
