import Foundation

// PREVIEW_TOOLS.md "level" + CONTRACTS.md "Pause camera, analysis and CoreMotion
// when library covers it; stop them on inactive/background scene".
//
// Pure, orientation-aware level state machine. There is deliberately no
// CoreMotion import in this file: the caller (a MainActor motion adapter, P10)
// converts `CMDeviceMotion` into `GravityReading` values. That keeps the
// tolerance/gain/gating policy testable with synthetic gravity and means this
// file cannot touch a sensor.

/// Device-space gravity in g units. `x` is the device's right edge in portrait,
/// `y` the device's top edge and `z` out of the display.
struct GravityReading: Hashable, Sendable {
    let x: Double
    let y: Double
    let z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    /// Rough magnitude, used to reject a sensor reading that is not gravity-like.
    var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Interface orientation the level is drawn for. Roll is measured in the screen's
/// own plane, so the same physical tilt reads 0° in every orientation.
enum DeviceOrientation: String, Hashable, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeRight
    case landscapeLeft

    /// Screen-right and screen-up unit vectors expressed in device coordinates.
    var screenAxes: (right: (x: Double, y: Double), up: (x: Double, y: Double)) {
        switch self {
        case .portrait:
            return (right: (1, 0), up: (0, 1))
        case .portraitUpsideDown:
            return (right: (-1, 0), up: (0, -1))
        case .landscapeRight:
            // Device rotated 90° clockwise: its top edge is screen-right.
            return (right: (0, 1), up: (-1, 0))
        case .landscapeLeft:
            // Device rotated 90° counter-clockwise: its top edge is screen-left.
            return (right: (0, -1), up: (1, 0))
        }
    }

    var displayLabel: String {
        switch self {
        case .portrait: return "Portrait"
        case .portraitUpsideDown: return "Portrait upside down"
        case .landscapeRight: return "Landscape right"
        case .landscapeLeft: return "Landscape left"
        }
    }
}

/// How close the device is to level inside the current orientation.
enum LevelZone: String, Hashable, Sendable {
    case level
    case nearLevel
    case tilted
    case unavailable

    var displayLabel: String {
        switch self {
        case .level: return "Level"
        case .nearLevel: return "Near level"
        case .tilted: return "Tilted"
        case .unavailable: return "Level unavailable"
        }
    }
}

/// Near a face-up/down position, horizon roll is undefined. The real gravity
/// vector still measures whether the phone's surface is horizontal, so present
/// that independent two-axis tilt instead of calling a healthy sensor missing.
struct LevelSurfaceTilt: Hashable, Sendable {
    let rightDegrees: Double
    let upDegrees: Double
    let deviationDegrees: Double
}

/// One snapshot of the level. Value-only so it can cross an isolation boundary.
struct LevelState: Hashable, Sendable {
    let isEnabled: Bool
    let isVisible: Bool
    let isSceneActive: Bool
    /// True only when this state came from a real, accepted gravity reading.
    let isProducingReadings: Bool
    /// Increments once per accepted reading; unchanged when hidden/inactive.
    let sequenceNumber: UInt64
    let rollDegrees: Double
    let pitchDegrees: Double
    let zone: LevelZone
    let orientation: DeviceOrientation
    let lastUpdateInstant: Double
    let statusLabel: String
    /// Non-nil only for a current accepted face-up/down surface reading.
    /// `rollDegrees` is not meaningful in this presentation and is not drawn.
    let surfaceTilt: LevelSurfaceTilt?

    static let stopped = LevelState(isEnabled: false,
                                    isVisible: false,
                                    isSceneActive: false,
                                    isProducingReadings: false,
                                    sequenceNumber: 0,
                                    rollDegrees: 0,
                                    pitchDegrees: 0,
                                    zone: .unavailable,
                                    orientation: .portrait,
                                    lastUpdateInstant: 0,
                                    statusLabel: "Level stopped",
                                    surfaceTilt: nil)
}

/// Orientation-aware level state machine.
///
/// Tolerance bands are display policy (PREVIEW_TOOLS.md gives no numeric level
/// requirement): ±0.5° reads as level, ±3° as near level. `gain` is the
/// low-pass response applied to the roll so a hand tremor does not make the
/// indicator jitter; it is a UI smoothing parameter, never a sensor guarantee.
struct LevelService: Sendable {
    struct Tolerances: Hashable, Sendable {
        /// |roll| at or below this reads as level.
        var levelDegrees: Double = 0.5
        /// |roll| at or below this reads as near level.
        var nearLevelDegrees: Double = 3.0
        /// Beyond this pitch horizon roll is undefined; use surface tilt.
        var flatPitchDegrees: Double = 75.0
    }

    private let clock: MonotonicClock
    let tolerances: Tolerances
    /// Low-pass response in 0...1 applied to the roll.
    let gain: Double
    private(set) var orientation: DeviceOrientation
    private(set) var isEnabled: Bool
    private(set) var isVisible: Bool
    private(set) var isSceneActive: Bool
    private var filteredRollDegrees: Double?
    private var lastState: LevelState

    init(clock: MonotonicClock = SystemMonotonicClock(),
         orientation: DeviceOrientation = .portrait,
         tolerances: Tolerances = Tolerances(),
         gain: Double = 0.25,
         isEnabled: Bool = true) {
        self.clock = clock
        self.orientation = orientation
        self.tolerances = tolerances
        self.gain = min(max(gain.isFinite ? gain : 0.25, 0), 1)
        self.isEnabled = isEnabled
        self.isVisible = true
        self.isSceneActive = true
        self.lastState = LevelState(isEnabled: isEnabled,
                                    isVisible: true,
                                    isSceneActive: true,
                                    isProducingReadings: false,
                                    sequenceNumber: 0,
                                    rollDegrees: 0,
                                    pitchDegrees: 0,
                                    zone: .unavailable,
                                    orientation: orientation,
                                    lastUpdateInstant: clock.now(),
                                    statusLabel: "Waiting for motion",
                                    surfaceTilt: nil)
    }

    var state: LevelState { lastState }

    /// Enables/disables the level. Disabling also drops the filter so re-enabling
    /// cannot resume from a stale smoothed value.
    mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { filteredRollDegrees = nil }
        refreshGatingState()
    }

    /// The level is hidden while an overlay/sheet covers the camera view.
    mutating func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible { filteredRollDegrees = nil }
        refreshGatingState()
    }

    /// Scene inactive/background stops motion work entirely
    /// (CONTRACTS.md "stop them on inactive/background scene").
    mutating func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if !active { filteredRollDegrees = nil }
        refreshGatingState()
    }

    mutating func setOrientation(_ newOrientation: DeviceOrientation) {
        guard newOrientation != orientation else { return }
        orientation = newOrientation
        filteredRollDegrees = nil
    }

    /// Full stop: no readings until re-enabled and re-activated.
    mutating func stop() {
        isEnabled = false
        isVisible = false
        isSceneActive = false
        filteredRollDegrees = nil
        refreshGatingState()
    }

    /// Feeds one gravity reading. Returns the current state; when the level is
    /// hidden, inactive, disabled or the reading is unusable, the returned state
    /// reports `isProducingReadings == false` and its `sequenceNumber` /
    /// `lastUpdateInstant` are unchanged, so no update is produced.
    @discardableResult
    mutating func update(gravity: GravityReading) -> LevelState {
        guard isEnabled, isVisible, isSceneActive else {
            refreshGatingState()
            return lastState
        }
        let magnitude = gravity.magnitude
        guard gravity.isFinite, magnitude.isFinite, magnitude > 0.01 else {
            filteredRollDegrees = nil
            lastState = LevelState(isEnabled: isEnabled,
                                   isVisible: isVisible,
                                   isSceneActive: isSceneActive,
                                   isProducingReadings: false,
                                   sequenceNumber: lastState.sequenceNumber,
                                   rollDegrees: lastState.rollDegrees,
                                   pitchDegrees: lastState.pitchDegrees,
                                   zone: .unavailable,
                                   orientation: orientation,
                                   lastUpdateInstant: lastState.lastUpdateInstant,
                                   statusLabel: "Level unavailable — no usable motion reading",
                                   surfaceTilt: nil)
            return lastState
        }

        let axes = orientation.screenAxes
        let towardRight = gravity.x * axes.right.x + gravity.y * axes.right.y
        let towardUp = gravity.x * axes.up.x + gravity.y * axes.up.y
        let measuredRoll = LevelService.degrees(atan2(towardRight, -towardUp))
        let pitch = LevelService.degrees(asin(min(max(-gravity.z / magnitude, -1), 1)))

        let roll: Double
        let surfaceTilt: LevelSurfaceTilt?
        let deviation: Double
        if abs(pitch) > tolerances.flatPitchDegrees {
            // Tiny x/y noise can make atan2 jump through any roll when z is
            // almost ±1. Never filter or render that undefined horizon angle.
            roll = 0
            filteredRollDegrees = nil
            let surfaceDeviation = LevelService.degrees(acos(min(abs(gravity.z) / magnitude, 1)))
            surfaceTilt = LevelSurfaceTilt(
                rightDegrees: LevelService.degrees(asin(min(max(towardRight / magnitude, -1), 1))),
                upDegrees: LevelService.degrees(asin(min(max(towardUp / magnitude, -1), 1))),
                deviationDegrees: surfaceDeviation)
            deviation = surfaceDeviation
        } else if let previous = filteredRollDegrees {
            roll = LevelService.wrapDegrees(previous + gain * LevelService.shortestDelta(from: previous, to: measuredRoll))
            filteredRollDegrees = roll
            surfaceTilt = nil
            deviation = abs(roll)
        } else {
            roll = measuredRoll
            filteredRollDegrees = roll
            surfaceTilt = nil
            deviation = abs(roll)
        }

        let zone: LevelZone
        let status: String
        if deviation <= tolerances.levelDegrees {
            zone = .level
            status = surfaceTilt == nil ? String(format: "Level %.1f°", roll) : "Phone flat — level"
        } else if deviation <= tolerances.nearLevelDegrees {
            zone = .nearLevel
            status = surfaceTilt == nil ? String(format: "Near level %.1f°", roll) : String(format: "Phone flat — near level, %.1f° tilt", deviation)
        } else {
            zone = .tilted
            status = surfaceTilt == nil ? String(format: "Tilted %.1f°", roll) : String(format: "Phone flat — %.1f° tilt", deviation)
        }

        lastState = LevelState(isEnabled: isEnabled,
                               isVisible: isVisible,
                               isSceneActive: isSceneActive,
                               isProducingReadings: true,
                               sequenceNumber: lastState.sequenceNumber + 1,
                               rollDegrees: roll,
                               pitchDegrees: pitch,
                               zone: zone,
                               orientation: orientation,
                               lastUpdateInstant: clock.now(),
                               statusLabel: status,
                               surfaceTilt: surfaceTilt)
        return lastState
    }

    private mutating func refreshGatingState() {
        let producing = isEnabled && isVisible && isSceneActive
        let status: String
        if !isEnabled {
            status = "Level off"
        } else if !isSceneActive {
            status = "Level stopped — app not active"
        } else if !isVisible {
            status = "Level paused — camera view not visible"
        } else {
            status = "Waiting for motion"
        }
        lastState = LevelState(isEnabled: isEnabled,
                               isVisible: isVisible,
                               isSceneActive: isSceneActive,
                               isProducingReadings: producing && lastState.isProducingReadings,
                               sequenceNumber: lastState.sequenceNumber,
                               rollDegrees: lastState.rollDegrees,
                               pitchDegrees: lastState.pitchDegrees,
                               zone: producing ? lastState.zone : .unavailable,
                               orientation: orientation,
                               lastUpdateInstant: lastState.lastUpdateInstant,
                               statusLabel: status,
                               surfaceTilt: producing ? lastState.surfaceTilt : nil)
    }

    // MARK: Angle helpers

    static func degrees(_ radians: Double) -> Double { radians * 180.0 / Double.pi }

    /// Wraps an angle into (-180, 180].
    static func wrapDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// Shortest signed rotation from `from` to `to`.
    static func shortestDelta(from: Double, to: Double) -> Double {
        wrapDegrees(to - from)
    }
}


/// Preview angles are interface rotations. CoreMotion axes describe the physical
/// device: UIKit's two landscape names intentionally refer to opposite axes.
extension DeviceOrientation {
    static func fromPreviewRotation(_ angle: Int) -> DeviceOrientation {
        switch ((angle % 360) + 360) % 360 {
        case 0: return .landscapeLeft
        case 180: return .landscapeRight
        case 270: return .portraitUpsideDown
        default: return .portrait
        }
    }
}
