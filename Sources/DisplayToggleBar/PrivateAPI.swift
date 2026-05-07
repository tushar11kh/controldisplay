import CoreGraphics
import Foundation
import IOKit

// MARK: - SkyLight (private CGS / SLS bridge)

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

@_silgen_name("SLSDetectDisplays")
func SLSDetectDisplays() -> CGError

// MARK: - DisplayServices brightness
//
// Used for the built-in panel. Doesn't require entitlements (BetterDisplay
// imports the same set). Brightness range is 0.0 ... 1.0.

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesCanChangeBrightness")
func DisplayServicesCanChangeBrightness(_ display: CGDirectDisplayID) -> Bool

// MARK: - IOAVService (dynamic load)
//
// IOAVServiceCreateWithService / ReadI2C / WriteI2C / CopyEDID are the
// symbols MonitorControl and BetterDisplay use to talk DDC/CI to external
// monitors over the I²C pins of their cable. Apple stripped them from the
// on-disk framework binaries on modern macOS, so we resolve them at runtime
// via dlsym instead of link-time symbol binding.

struct IOAVAPI {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    typealias ReadFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias WriteFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> Int32
    typealias CopyEDIDFn = @convention(c) (AnyObject, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32

    let create: CreateFn
    let read: ReadFn
    let write: WriteFn
    let copyEDID: CopyEDIDFn?

    static let shared: IOAVAPI? = load()

    private static func load() -> IOAVAPI? {
        // RTLD_DEFAULT searches every framework already loaded into the
        // process. CoreDisplay (linked by the package) pulls these in.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let candidatePaths = [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel",
            "/System/Library/PrivateFrameworks/IOAVFamily.framework/IOAVFamily",
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        ]

        func resolve(_ name: String) -> UnsafeMutableRawPointer? {
            if let p = dlsym(rtldDefault, name) { return p }
            for path in candidatePaths {
                guard let h = dlopen(path, RTLD_LAZY) else { continue }
                if let p = dlsym(h, name) { return p }
            }
            return nil
        }

        guard
            let createPtr = resolve("IOAVServiceCreateWithService"),
            let readPtr = resolve("IOAVServiceReadI2C"),
            let writePtr = resolve("IOAVServiceWriteI2C")
        else {
            return nil
        }
        let copyEDIDPtr = resolve("IOAVServiceCopyEDID")

        return IOAVAPI(
            create: unsafeBitCast(createPtr, to: CreateFn.self),
            read: unsafeBitCast(readPtr, to: ReadFn.self),
            write: unsafeBitCast(writePtr, to: WriteFn.self),
            copyEDID: copyEDIDPtr.map { unsafeBitCast($0, to: CopyEDIDFn.self) }
        )
    }
}
