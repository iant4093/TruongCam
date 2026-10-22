import Foundation

/// Which parameter panel is open. Panel visibility is never capture state.
enum CameraPanel: String, Hashable, Sendable, CaseIterable, Identifiable {
    case shutter
    case iso
    case focus
    case whiteBalance
    case exposureBias

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shutter: return "Shutter"
        case .iso: return "ISO"
        case .focus: return "Focus"
        case .whiteBalance: return "White balance"
        case .exposureBias: return "Exposure compensation"
        }
    }
}

/// Hardware swipes express the same discrete intent as the on-screen rulers.
/// No hardware callback is allowed to write directly to a native camera device.
enum HardwareControlKind: String, Hashable, Sendable {
    case lenses, shutter, iso, focus, temperature, tint, exposureBias
}
enum HardwareControlValue: Hashable, Sendable {
    case automatic, number(Double), lens(PhysicalCameraKind)
}
struct HardwareControlOption: Hashable, Sendable {
    let title: String
    let value: HardwareControlValue
}
struct HardwareControlDomain: Hashable, Sendable {
    let generation: ConfigurationGeneration
    let kind: HardwareControlKind
    let title: String
    let symbol: String
    let options: [HardwareControlOption]
    func value(at index: Int) -> HardwareControlValue? {
        guard options.indices.contains(index) else { return nil }
        return options[index].value
    }
}
struct HardwareControlSelection: Hashable, Sendable {
    let domain: HardwareControlDomain
    let index: Int
    /// Auto is positioned at its live value, without changing camera intent.
    var isAutomatic: Bool = false
}

enum HardwarePickerSynchronization {
    static func shouldUpdateIndex(active: Bool, ownerChanged: Bool, automaticChanged: Bool) -> Bool {
        // A moving Auto readout or an older model echo must not pull a physical
        // swipe back. Mode/owner changes deliberately re-anchor it once.
        !active || ownerChanged || automaticChanged
    }
}
struct HardwareControlEvent: Hashable, Sendable {
    let interactionID: UUID
    let selection: HardwareControlSelection
}
struct HardwareControlConfiguration: Hashable, Sendable {
    let enabled: Bool
    let selections: [HardwareControlSelection]
    /// A real photo temporarily closes command admission, but must not tear
    /// down the system's hardware-control presentation mid-full-press.
    var preservesPresentation: Bool = false
}
protocol HardwareCameraControlling: Sendable {
    /// Synchronous latest-intent mailbox; native changes execute on the session queue.
    func configureHardwareControls(_ configuration: HardwareControlConfiguration, interactionID: UUID)
    var hardwareControlSelections: AsyncStream<HardwareControlEvent> { get }
    var hardwareControlFullscreen: AsyncStream<Bool> { get }
}
