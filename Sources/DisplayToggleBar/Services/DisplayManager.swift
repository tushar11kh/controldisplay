import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Coordinates display enumeration, enable/disable, and brightness routing.
///
/// Routes:
/// - Enumeration: `CGGetOnlineDisplayList` + `CGGetActiveDisplayList`, with a
///   `UserDefaults`-backed cache so disabled displays remain visible.
/// - Toggle: `CGSConfigureDisplayEnabled`. Built-in re-enable after a long
///   disable hits `kCGErrorCannotComplete (1001)` because WindowServer GC's
///   the display descriptor; we work around it by poking the framebuffer kext
///   directly via `IOServiceRequestProbe` (the same path lid-close uses) and
///   retrying.
/// - Brightness: `DisplayServices*` for built-in, `DDCBrightness` (DDC/CI
///   over I²C) for external.
@MainActor
final class DisplayManager {
    private let knownDisplaysKey = "knownDisplays"
    private var knownDisplaysByKey: [String: Display] = [:]
    private let ddc = DDCBrightness()

    init() {
        loadKnownDisplays()
    }

    // MARK: - Errors

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

    // MARK: - Enumeration

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
        guard display.isActive else { return true }
        return displays().filter(\.isActive).count > 1
    }

    // MARK: - Toggle

    func setDisplay(_ display: Display, enabled: Bool) throws {
        if !enabled, !canDisable(display) {
            throw ToggleError.lastActiveDisplay
        }

        // First try: use the display as-is. Fast/common path — handles both
        // disable and quick re-enable (within a few seconds).
        do {
            try applyDisplayState(display, enabled: enabled, option: .forSession)
            updateKnownDisplay(display, isActive: enabled)
            return
        } catch ToggleError.complete(let firstError) where enabled && display.isBuiltin {
            // Long-disable case for built-in: WindowServer GC'd the display
            // descriptor. Poke the framebuffer kext directly to force re-probe
            // (same kernel path lid-close uses), then SLSDetectDisplays + retry.
            wakeBuiltinFramebuffer()
            detectDisplays()
            Thread.sleep(forTimeInterval: 0.5)

            let refreshed = resolveDisplayForEnable(display)
            do {
                try applyDisplayState(refreshed, enabled: true, option: .forSession)
                updateKnownDisplay(refreshed, isActive: true)
                return
            } catch ToggleError.complete {
                // Second escalation: longer wait + permanently option.
                Thread.sleep(forTimeInterval: 1.0)
                wakeBuiltinFramebuffer()
                detectDisplays()
                Thread.sleep(forTimeInterval: 1.0)
                let refreshed2 = resolveDisplayForEnable(refreshed)
                do {
                    try applyDisplayState(refreshed2, enabled: true, option: .permanently)
                    updateKnownDisplay(refreshed2, isActive: true)
                    return
                } catch ToggleError.complete {
                    throw ToggleError.builtinEnableFailed(firstError)
                }
            }
        }
    }

    @discardableResult
    func restoreBuiltinDisplayIfNeeded(force: Bool = false) throws -> Bool {
        detectDisplays()
        let currentDisplays = displays()
        guard let builtinDisplay = currentDisplays.first(where: \.isBuiltin) ?? knownDisplaysByKey[Display.builtinCacheKey] else {
            throw ToggleError.noKnownBuiltinDisplay
        }

        guard !builtinDisplay.isActive else { return false }

        let activeNonBuiltinCount = currentDisplays.filter { !$0.isBuiltin && $0.isActive }.count
        guard force || activeNonBuiltinCount == 0 else { return false }

        try setDisplay(builtinDisplay, enabled: true)
        return true
    }

    // MARK: - Brightness routing

    func canChangeBrightness(_ display: Display) -> Bool {
        if display.isBuiltin {
            return DisplayServicesCanChangeBrightness(display.id)
        }
        return ddc.canChangeBrightness(display.id)
    }

    func brightness(for display: Display) -> Float? {
        if display.isBuiltin {
            var value: Float = 0
            let result = DisplayServicesGetBrightness(display.id, &value)
            guard result == 0 else { return nil }
            return value
        }
        return ddc.brightness(for: display.id)
    }

    @discardableResult
    func setBrightness(_ display: Display, to value: Float) -> Bool {
        let clamped = max(0.0, min(1.0, value))
        if display.isBuiltin {
            return DisplayServicesSetBrightness(display.id, clamped) == 0
        }
        return ddc.setBrightness(for: display.id, normalized: clamped)
    }

    func invalidateBrightnessCache() {
        ddc.invalidate()
    }

    // MARK: - Display modes (resolution + refresh rate)

    /// Every `CGDisplayMode` macOS reports for the display. We deliberately
    /// don't filter on `isUsableForDesktopGUI` — many modes flagged
    /// "non-recommended" actually work fine, and macOS re-enumerates the
    /// "usable" set after a mode change, so dropping them up-front would
    /// hide real options (this is the same behavior BetterDisplay relies
    /// on). `kCGDisplayShowDuplicateLowResolutionModes` unhides modes
    /// classified as duplicates.
    func availableModes(for display: Display) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(display.id, options) as? [CGDisplayMode] else {
            return []
        }
        return cgModes.map(DisplayMode.init)
    }

    func currentMode(for display: Display) -> DisplayMode? {
        guard let cg = CGDisplayCopyDisplayMode(display.id) else { return nil }
        return DisplayMode(cg)
    }

    /// All desktop-usable display modes, deduped and sorted for the
    /// dropdown. Includes both HiDPI ("Retina"-style) and non-HiDPI
    /// variants — they have the same pixel resolution but produce different
    /// UI scaling, and the user choice depends on panel pixel density.
    ///
    /// Sort: larger pixel area first; then larger point area (= less
    /// aggressive scaling); then higher refresh rate. That puts the most
    /// "powerful" modes at the top.
    func displayModes(for display: Display) -> [DisplayMode] {
        let allModes = availableModes(for: display)

        let sorted = allModes.sorted { a, b in
            let aPixels = a.pixelWidth * a.pixelHeight
            let bPixels = b.pixelWidth * b.pixelHeight
            if aPixels != bPixels { return aPixels > bPixels }
            let aPointArea = a.width * a.height
            let bPointArea = b.width * b.height
            if aPointArea != bPointArea { return aPointArea > bPointArea }
            return a.refreshRate > b.refreshRate
        }

        // Dedup on (pixelW, pixelH, isHiDPI, roundedRate). HiDPI and
        // non-HiDPI variants of the same pixel resolution are distinct modes
        // with different UI scaling and must both be selectable.
        var seen = Set<String>()
        var unique: [DisplayMode] = []
        for mode in sorted {
            let key = "\(mode.pixelWidth)x\(mode.pixelHeight)x\(mode.isHiDPI)@\(Int(mode.refreshRate.rounded()))"
            if seen.insert(key).inserted {
                unique.append(mode)
            }
        }
        return unique
    }

    @discardableResult
    func setMode(_ mode: DisplayMode, on display: Display) -> Bool {
        FileHandle.standardError.write(Data(
            "[mode] applying id=\(mode.id) px=\(mode.pixelWidth)x\(mode.pixelHeight) pt=\(mode.width)x\(mode.height) hiDPI=\(mode.isHiDPI) @ \(String(format: "%.2f", mode.refreshRate))Hz\n".utf8
        ))
        return applyDisplayMode(mode.cgDisplayMode(), on: display)
    }

    private func applyDisplayMode(_ cgMode: CGDisplayMode, on display: Display) -> Bool {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        FileHandle.standardError.write(Data("[mode]   begin=\(begin.rawValue)\n".utf8))
        guard begin == .success, let config else { return false }

        let configure = CGConfigureDisplayWithDisplayMode(config, display.id, cgMode, nil)
        FileHandle.standardError.write(Data("[mode]   configure=\(configure.rawValue)\n".utf8))
        guard configure == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        FileHandle.standardError.write(Data("[mode]   complete=\(complete.rawValue)\n".utf8))
        return complete == .success
    }

    // MARK: - Configuration transactions

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
        guard display.isBuiltin else { return display }
        detectDisplays()
        return displays().first { $0.isBuiltin && $0.id != display.id } ?? display
    }

    private func detectDisplays() {
        _ = SLSDetectDisplays()
    }

    /// Asks the kernel framebuffer driver for the built-in panel to re-probe.
    /// Same kernel path lid-close + lid-open exercises; what BetterDisplay
    /// imports `IOServiceGetMatchingServices` + `IOServiceRequestProbe` for.
    private func wakeBuiltinFramebuffer() {
        for serviceClass in ["AppleCLCD2", "IOMobileFramebufferAP", "IOMobileFramebuffer"] {
            requestProbe(forServiceMatching: serviceClass)
        }
    }

    private func requestProbe(forServiceMatching className: String) {
        guard let matching = IOServiceMatching(className) else { return }
        var iter: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard result == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            _ = IOServiceRequestProbe(service, 0)
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
    }

    // MARK: - Cache persistence

    private func updateKnownDisplay(_ display: Display, isActive: Bool) {
        knownDisplaysByKey[display.cacheKey] = Display(
            id: display.id,
            cacheKey: display.cacheKey,
            uuid: display.uuid,
            name: display.name,
            isBuiltin: display.isBuiltin,
            isActive: isActive
        )
        persistKnownDisplays()
    }

    private func loadKnownDisplays() {
        guard let data = UserDefaults.standard.data(forKey: knownDisplaysKey),
              let displays = try? JSONDecoder().decode([Display].self, from: data) else {
            return
        }
        knownDisplaysByKey = Dictionary(uniqueKeysWithValues: displays.map { ($0.cacheKey, $0) })
    }

    private func persistKnownDisplays() {
        guard let data = try? JSONEncoder().encode(Array(knownDisplaysByKey.values)) else { return }
        UserDefaults.standard.set(data, forKey: knownDisplaysKey)
    }

    // MARK: - Display ID helpers

    private func displayIDs(
        using getter: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard getter(0, nil, &count) == .success, count > 0 else { return [] }

        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let error = displayIDs.withUnsafeMutableBufferPointer { buffer in
            getter(count, buffer.baseAddress, &count)
        }
        guard error == .success else { return [] }
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
