import AppKit
import Foundation

/// App-level coordinator. Owns the status-bar item, popover, and
/// `DisplayManager`. Bridges tile-level user actions back into the manager,
/// and handles automatic built-in restore when an external display
/// disconnects.
@MainActor
final class MenuController: NSObject, DisplayTileDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let contentVC: PopoverContentViewController
    private let displayManager = DisplayManager()
    private var lastDisplayKeys: Set<String> = []
    private var expandedDisplayKeys: Set<String> = []
    private var eventMonitor: Any?

    // Throttle DDC writes — each round trip is ~50ms over I²C, so spamming on
    // every continuous slider step makes drags feel laggy. We coalesce to the
    // most recent value and send at most every 80ms.
    private var ddcWriteTimer: DispatchSourceTimer?
    private var pendingDDCWrite: (display: Display, value: Float)?

    override init() {
        self.contentVC = PopoverContentViewController()
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "Display Toggle"
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentVC
        popover.delegate = self

        contentVC.refreshAction = { [weak self] in self?.refreshContent() }
        contentVC.quitAction = { NSApplication.shared.terminate(nil) }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        refreshContent()
    }

    // MARK: - Popover lifecycle

    @objc private func statusItemClicked(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            refreshContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Close popover when user clicks outside it.
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Content refresh

    @objc private func refreshContent() {
        let displays = displayManager.displays()
        let activeCount = displays.filter(\.isActive).count
        lastDisplayKeys = Set(displays.map(\.cacheKey))
        expandedDisplayKeys.formIntersection(Set(displays.map(\.cacheKey)))

        let tiles = displays.map { display in
            DisplayTileView(
                display: display,
                activeCount: activeCount,
                expanded: expandedDisplayKeys.contains(display.cacheKey),
                canChangeBrightness: displayManager.canChangeBrightness(display),
                delegate: self
            )
        }
        contentVC.setTiles(tiles, hasDisplays: !displays.isEmpty)
    }

    // MARK: - Display reconfig + auto-restore

    @objc private func displayConfigurationChanged() {
        let previousDisplayKeys = lastDisplayKeys
        // Display IDs and IOAVService bindings can change after reconfig.
        displayManager.invalidateBrightnessCache()

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

        refreshContent()
    }

    // MARK: - DisplayTileDelegate

    func displayTile(_ tile: DisplayTileView, didToggleEnabled enabled: Bool) {
        let display = tile.display
        do {
            try displayManager.setDisplay(display, enabled: enabled)
        } catch {
            showError(error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshContent()
        }
    }

    func displayTile(_ tile: DisplayTileView, didChangeBrightness value: Float) {
        let display = tile.display
        if display.isBuiltin {
            // DisplayServices is fast (memory write); update on every step.
            displayManager.setBrightness(display, to: value)
            return
        }
        // External display — throttle to avoid lag during slider drag.
        pendingDDCWrite = (display, value)
        if ddcWriteTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.08, repeating: .never)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let pending = self.pendingDDCWrite {
                    self.displayManager.setBrightness(pending.display, to: pending.value)
                }
                self.pendingDDCWrite = nil
                self.ddcWriteTimer = nil
            }
            ddcWriteTimer = timer
            timer.resume()
        }
    }

    func displayTile(_ tile: DisplayTileView, didSetExpanded expanded: Bool) {
        if expanded {
            expandedDisplayKeys.insert(tile.display.cacheKey)
        } else {
            expandedDisplayKeys.remove(tile.display.cacheKey)
        }
    }

    func displayTileBrightness(_ tile: DisplayTileView) -> Float? {
        displayManager.brightness(for: tile.display)
    }

    func displayTileCanChangeBrightness(_ tile: DisplayTileView) -> Bool {
        displayManager.canChangeBrightness(tile.display)
    }

    // MARK: - Errors

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Display toggle failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
