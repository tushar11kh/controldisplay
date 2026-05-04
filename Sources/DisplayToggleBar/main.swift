import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

@_silgen_name("SLSDetectDisplays")
private func SLSDetectDisplays() -> CGError

struct Display: Identifiable, Equatable, Codable {
    static let builtinCacheKey = "builtin-display"

    let id: CGDirectDisplayID
    let cacheKey: String
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isActive: Bool

    var stableDescription: String {
        if isBuiltin {
            return "\(name) · Built-in"
        }

        return name
    }

    var detailIdentifier: String {
        isBuiltin ? "Built-in display" : uuid
    }
}

final class DisplayManager {
    private let knownDisplaysKey = "knownDisplays"
    private var knownDisplaysByKey: [String: Display] = [:]

    init() {
        loadKnownDisplays()
    }

    enum ToggleError: LocalizedError {
        case beginConfiguration(CGError)
        case configure(CGError)
        case complete(CGError)
        case builtinEnableFailed(CGError)
        case noKnownBuiltinDisplay
        case lastActiveDisplay

        var errorDescription: String? {
            switch self {
            case let .beginConfiguration(error):
                return "Could not start display configuration: \(error)"
            case let .configure(error):
                return "Could not update display state: \(error)"
            case let .complete(error):
                return "Could not apply display configuration: \(error)"
            case let .builtinEnableFailed(error):
                return "Could not re-enable the built-in display after display-wake retries: \(error). macOS is rejecting the display transaction."
            case .noKnownBuiltinDisplay:
                return "No known built-in display is available to restore."
            case .lastActiveDisplay:
                return "The only active display cannot be disabled."
            }
        }
    }

    func displays() -> [Display] {
        let activeDisplayIDs = Set(displayIDs(using: CGGetActiveDisplayList))
        let onlineDisplayIDs = displayIDs(using: CGGetOnlineDisplayList)

        let currentDisplays = onlineDisplayIDs.map { displayID in
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let displayUUID = uuid(for: displayID)

            return Display(
                id: displayID,
                cacheKey: isBuiltin ? Display.builtinCacheKey : displayUUID,
                uuid: displayUUID,
                name: name(for: displayID),
                isBuiltin: isBuiltin,
                isActive: activeDisplayIDs.contains(displayID)
            )
        }

        for display in currentDisplays {
            knownDisplaysByKey[display.cacheKey] = display
        }
        persistKnownDisplays()

        let currentKeys = Set(currentDisplays.map(\.cacheKey))
        let cachedDisabledDisplays = knownDisplaysByKey.values
            .filter { display in
                !currentKeys.contains(display.cacheKey) && !display.isActive
            }

        return (currentDisplays + cachedDisabledDisplays).sorted { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin {
                return lhs.isBuiltin
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func canDisable(_ display: Display) -> Bool {
        guard display.isActive else {
            return true
        }

        return displays().filter(\.isActive).count > 1
    }

    func setDisplay(_ display: Display, enabled: Bool) throws {
        if !enabled, !canDisable(display) {
            throw ToggleError.lastActiveDisplay
        }

        let targetDisplay = enabled ? resolveDisplayForEnable(display) : display
        let appliedDisplay: Display

        do {
            try applyDisplayState(targetDisplay, enabled: enabled, option: .forSession)
            appliedDisplay = targetDisplay
        } catch ToggleError.complete where enabled && targetDisplay.isBuiltin {
            Thread.sleep(forTimeInterval: 0.35)
            let refreshedDisplay = resolveDisplayForEnable(targetDisplay)

            do {
                try applyDisplayState(refreshedDisplay, enabled: enabled, option: .permanently)
                appliedDisplay = refreshedDisplay
            } catch ToggleError.complete(let error) {
                detectDisplays()
                Thread.sleep(forTimeInterval: 0.35)
                let detectedDisplay = resolveDisplayForEnable(refreshedDisplay)

                do {
                    try applyDisplayState(detectedDisplay, enabled: enabled, option: .forSession)
                    appliedDisplay = detectedDisplay
                } catch ToggleError.complete {
                    try wakeDisplayPipeline()
                    detectDisplays()
                    Thread.sleep(forTimeInterval: 0.65)
                    let wakeRefreshedDisplay = resolveDisplayForEnable(detectedDisplay)

                    do {
                        try applyDisplayState(wakeRefreshedDisplay, enabled: enabled, option: .forSession)
                        appliedDisplay = wakeRefreshedDisplay
                    } catch ToggleError.complete {
                        Thread.sleep(forTimeInterval: 1.0)
                        detectDisplays()
                        do {
                            try applyDisplayState(wakeRefreshedDisplay, enabled: enabled, option: .permanently)
                            appliedDisplay = wakeRefreshedDisplay
                        } catch ToggleError.complete {
                            throw ToggleError.builtinEnableFailed(error)
                        }
                    }
                }
            }
        } catch {
            throw error
        }

        knownDisplaysByKey[appliedDisplay.cacheKey] = Display(
            id: appliedDisplay.id,
            cacheKey: appliedDisplay.cacheKey,
            uuid: appliedDisplay.uuid,
            name: appliedDisplay.name,
            isBuiltin: appliedDisplay.isBuiltin,
            isActive: enabled
        )
        persistKnownDisplays()
    }

    @discardableResult
    func restoreBuiltinDisplayIfNeeded(force: Bool = false) throws -> Bool {
        detectDisplays()
        let currentDisplays = displays()
        guard let builtinDisplay = currentDisplays.first(where: \.isBuiltin) ?? knownDisplaysByKey[Display.builtinCacheKey] else {
            throw ToggleError.noKnownBuiltinDisplay
        }

        guard !builtinDisplay.isActive else {
            return false
        }

        let activeNonBuiltinCount = currentDisplays.filter { !$0.isBuiltin && $0.isActive }.count
        guard force || activeNonBuiltinCount == 0 else {
            return false
        }

        try setDisplay(builtinDisplay, enabled: true)
        return true
    }

    private func applyDisplayState(_ display: Display, enabled: Bool, option: CGConfigureOption) throws {
        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            throw ToggleError.beginConfiguration(beginError)
        }

        let configureError = CGSConfigureDisplayEnabled(config, display.id, enabled)
        guard configureError == .success else {
            CGCancelDisplayConfiguration(config)
            throw ToggleError.configure(configureError)
        }

        let completeError = CGCompleteDisplayConfiguration(config, option)
        guard completeError == .success else {
            throw ToggleError.complete(completeError)
        }
    }

    private func resolveDisplayForEnable(_ display: Display) -> Display {
        guard display.isBuiltin else {
            return display
        }

        detectDisplays()
        return displays().first { $0.isBuiltin && $0.id != display.id } ?? display
    }

    private func detectDisplays() {
        _ = SLSDetectDisplays()
    }

    private func wakeDisplayPipeline() throws {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            "DisplayToggleBar built-in display restore" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            return
        }
    }

    private func loadKnownDisplays() {
        guard let data = UserDefaults.standard.data(forKey: knownDisplaysKey),
              let displays = try? JSONDecoder().decode([Display].self, from: data) else {
            return
        }

        knownDisplaysByKey = Dictionary(uniqueKeysWithValues: displays.map { ($0.cacheKey, $0) })
    }

    private func persistKnownDisplays() {
        guard let data = try? JSONEncoder().encode(Array(knownDisplaysByKey.values)) else {
            return
        }

        UserDefaults.standard.set(data, forKey: knownDisplaysKey)
    }

    private func displayIDs(
        using getter: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard getter(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let error = displayIDs.withUnsafeMutableBufferPointer { buffer in
            getter(count, buffer.baseAddress, &count)
        }

        guard error == .success else {
            return []
        }

        return Array(displayIDs.prefix(Int(count)))
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-\(displayID)"
        }

        let cfUUID = unmanagedUUID.takeRetainedValue()
        return (CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?) ?? "display-\(displayID)"
    }

    private func name(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == displayID {
                return screen.localizedName
            }
        }

        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }

        return "Display \(displayID)"
    }
}

final class DisplaySwitch: NSSwitch {
    var display: Display?
}

@MainActor
final class DisplayMenuItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let switchControl = DisplaySwitch()

    init(display: Display, activeCount: Int, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 48))

        let canToggle = !display.isActive || activeCount > 1

        titleLabel.stringValue = display.stableDescription
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail

        if !canToggle {
            detailLabel.stringValue = "Only active display cannot be disabled"
        } else if display.isActive {
            detailLabel.stringValue = display.detailIdentifier
        } else {
            detailLabel.stringValue = "Disabled · \(display.detailIdentifier)"
        }
        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        switchControl.display = display
        switchControl.state = display.isActive ? .on : .off
        switchControl.isEnabled = canToggle
        switchControl.target = target
        switchControl.action = action

        let labelStack = NSStackView(views: [titleLabel, detailLabel])
        labelStack.orientation = .vertical
        labelStack.spacing = 2
        labelStack.alignment = .leading

        let rowStack = NSStackView(views: [labelStack, switchControl])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        rowStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            labelStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class MenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let displayManager = DisplayManager()
    private var lastDisplayKeys: Set<String> = []

    override init() {
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "Display Toggle"
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        refreshMenu()
    }

    @objc private func refreshMenu() {
        menu.removeAllItems()

        let displays = displayManager.displays()
        let activeCount = displays.filter(\.isActive).count
        lastDisplayKeys = Set(displays.map(\.cacheKey))

        if displays.isEmpty {
            let item = NSMenuItem(title: "No displays found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for display in displays {
                let item = NSMenuItem()
                item.view = DisplayMenuItemView(
                    display: display,
                    activeCount: activeCount,
                    target: self,
                    action: #selector(toggleDisplay(_:))
                )
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Displays", action: #selector(refreshMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DisplayToggleBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func displayConfigurationChanged() {
        let previousDisplayKeys = lastDisplayKeys

        scheduleBuiltinRestorePass(after: 0.8, previousDisplayKeys: previousDisplayKeys, showErrors: true)
        scheduleBuiltinRestorePass(after: 2.0, previousDisplayKeys: previousDisplayKeys, showErrors: false)
        scheduleBuiltinRestorePass(after: 4.0, previousDisplayKeys: previousDisplayKeys, showErrors: false)
    }

    private func scheduleBuiltinRestorePass(after delay: TimeInterval, previousDisplayKeys: Set<String>, showErrors: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restoreBuiltinAfterDisplayChange(previousDisplayKeys: previousDisplayKeys, showErrors: showErrors)
        }
    }

    private func restoreBuiltinAfterDisplayChange(previousDisplayKeys: Set<String>, showErrors: Bool) {
        let displays = displayManager.displays()
        let currentDisplayKeys = Set(displays.map(\.cacheKey))
        let removedDisplayKeys = previousDisplayKeys.subtracting(currentDisplayKeys)
        let removedNonBuiltinDisplay = removedDisplayKeys.contains { $0 != Display.builtinCacheKey }
        let noActiveNonBuiltinDisplay = !displays.contains { !$0.isBuiltin && $0.isActive }

        if removedNonBuiltinDisplay || noActiveNonBuiltinDisplay {
            do {
                _ = try displayManager.restoreBuiltinDisplayIfNeeded(force: removedNonBuiltinDisplay)
            } catch {
                if showErrors {
                    showError(error)
                }
            }
        }

        refreshMenu()
    }

    @objc private func toggleDisplay(_ sender: DisplaySwitch) {
        guard let display = sender.display else {
            return
        }

        do {
            try displayManager.setDisplay(display, enabled: sender.state == .on)
        } catch {
            sender.state = display.isActive ? .on : .off
            showError(error)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshMenu()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Display toggle failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let menuController = MenuController()
_ = menuController

app.run()
