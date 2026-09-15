import Foundation

//  Adapted from cemu-ios-muffin's src/ios/App/TimebaseScale.swift.
//
//  MELOMUFFIN ADAPTATION NOTE: the manual get/set below now call
//  CemuTimebase_GetShift/SetShift (src/main.cpp), added to MeloCafe's own bridge for
//  this port - real, thin wrappers over ActiveSettings::GetTimerShiftFactor/
//  SetTimerShiftFactor, which already existed in this repo's core untouched.
//
//  DROPPED: Muffin's automatic "ladder" (cemu_bridge_set_timebase_auto_enabled) that
//  steps the shift down by itself every 12 seconds while a title boots under the
//  interpreter, stopping once GX2Init is reached. That behavior lived entirely in
//  Muffin's own CemuBridge.mm as a background timer watching its own boot-progress
//  counters (CemuBridgeProgress.gx2_init_reached) - counters this bridge has no
//  equivalent for - so there is nothing here to hook it to. Only manual control
//  survives this pass; a person has to pick a value themselves.
///
/// See the original file (kept verbatim in this repo's history / upstream) for the
/// full rationale on why this setting matters under a forced interpreter.
enum TimebaseScale: Int, CaseIterable, Identifiable {
    case realTime = 3
    case half = 4
    case quarter = 5
    case eighth = 6
    case sixteenth = 7
    case thirtySecond = 8
    case sixtyFourth = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .realTime:     return "Real time"
        case .half:         return "1/2 speed"
        case .quarter:      return "1/4 speed"
        case .eighth:       return "1/8 speed"
        case .sixteenth:    return "1/16 speed"
        case .thirtySecond: return "1/32 speed"
        case .sixtyFourth:  return "1/64 speed"
        }
    }

    var summary: String {
        switch self {
        case .realTime:
            return "What MeloCafe used before this. Correct with the recompiler; under the interpreter it is what makes a running game look frozen."
        case .half, .quarter:
            return "A mild correction. Worth trying first if a game advances but stutters badly."
        case .eighth:
            return "A reasonable starting point under the interpreter. Enough slack for most titles' own deadlines to stay reachable."
        case .sixteenth, .thirtySecond:
            return "For a title that still will not advance at 1/8. The game plays in slow motion; it does not run slower than it already was."
        case .sixtyFourth:
            return "As slow as this goes. If a game will not move here, the problem is not the clock."
        }
    }

    static let storageKey = "melomuffin.timebaseShift"

    static var hasExplicitChoice: Bool {
        UserDefaults.standard.object(forKey: storageKey) != nil
    }

    static var current: TimebaseScale {
        if hasExplicitChoice,
           let value = TimebaseScale(rawValue: UserDefaults.standard.integer(forKey: storageKey)) {
            return value
        }
        return TimebaseScale(rawValue: Int(CemuTimebase_GetShift())) ?? .realTime
    }

    static func apply(_ scale: TimebaseScale) {
        UserDefaults.standard.set(scale.rawValue, forKey: storageKey)
        CemuTimebase_SetShift(UInt8(scale.rawValue))
    }

    /// Re-applies a stored choice after the engine has initialized. Unlike Muffin's
    /// version there is no automatic ladder to arm when nothing has been chosen -
    /// see this file's header note - so the no-choice branch simply leaves the
    /// engine's own default (real time) in place.
    static func applyStoredChoiceIfAny() {
        guard hasExplicitChoice,
              let value = TimebaseScale(rawValue: UserDefaults.standard.integer(forKey: storageKey))
        else { return }
        CemuTimebase_SetShift(UInt8(value.rawValue))
    }
}
