#!/usr/bin/env swift
// prove-enum-bug.swift — Empirical proof for issue #2977
//
// Demonstrates that FanMode.auto3 (SMC mode 3, used by thermalmonitord on
// Apple Silicon) is incorrectly treated as non-automatic in popup.swift,
// causing fans to switch to manual mode after sleep/wake.
//
// Run: swift investigations/prove-enum-bug.swift
//
// This was introduced in PR #2924 (v2.12.0): FanMode.auto3 and .isAutomatic
// were added to the enum, but the 7 comparison sites in popup.swift and
// main.swift were NOT updated to use .isAutomatic.

import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Exact copy of the enum from SMC/smc.swift (lines 46-54, as of v2.12.0)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    public var isAutomatic: Bool {
        self == .automatic || self == .auto3
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 1: The enum comparison produces wrong results for mode 3
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 1: FanMode enum comparison bug")
print("═══════════════════════════════════════════════════════════\n")

print("FanMode.auto3 represents SMC F%%dMd = 3 (thermalmonitord system mode).")
print("FanMode.isAutomatic exists to treat both .automatic and .auto3 as auto.\n")

let auto3: FanMode = .auto3
print("  FanMode.auto3 != .automatic  =  \(auto3 != .automatic)   ← WRONG (should be false)")
print("  !FanMode.auto3.isAutomatic   =  \(!auto3.isAutomatic)  ← CORRECT")
print()

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 2: The resetModeAfterSleep code path (popup.swift:928)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 2: resetModeAfterSleep triggers incorrectly")
print("═══════════════════════════════════════════════════════════\n")

print("popup.swift:928 — runs after every wake notification:")
print("  if self.resetModeAfterSleep && value.mode != .automatic {\n")

struct SimulatedUpdate {
    let mode: FanMode
    let resetFlag: Bool

    var buggyResult: Bool { resetFlag && mode != .automatic }
    var correctResult: Bool { resetFlag && !mode.isAutomatic }
}

let scenarios = [
    ("F%%dMd=0 (auto)",   SimulatedUpdate(mode: .automatic, resetFlag: true)),
    ("F%%dMd=1 (manual)", SimulatedUpdate(mode: .forced, resetFlag: true)),
    ("F%%dMd=3 (system)", SimulatedUpdate(mode: .auto3, resetFlag: true)),
]

for (label, sim) in scenarios {
    let mismatch = sim.buggyResult != sim.correctResult
    print("  \(label):")
    print("    Current code → enters block: \(sim.buggyResult)")
    print("    Correct code → enters block: \(sim.correctResult)")
    if mismatch {
        print("    ⚠️  BUG: calls setMode(.forced) → writes F%%dMd=1 to SMC!")
    }
    print()
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 3: loadFans() does NOT normalize mode 3 (readers.swift:334)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 3: loadFans() vs getFanMode() normalization gap")
print("═══════════════════════════════════════════════════════════\n")

print("readers.swift:334 — loadFans() first branch (always taken on Apple Silicon):")
print("  FanMode(rawValue: Int(3.0)) = \(FanMode(rawValue: Int(3.0))!)   ← NOT normalized\n")

print("readers.swift:358 — getFanMode() fallback (NEVER reached on Apple Silicon):")
let modeValue = Int(3.0)
let normalized: FanMode = modeValue == 1 ? .forced : .automatic
print("  modeValue == 1 ? .forced : .automatic = \(normalized)  ← Normalizes to auto\n")

print("The normalizing fallback is dead code on arm64 because getValue(\"F%%dMd\")")
print("succeeds, so the first branch is always taken.\n")

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 4: sleepListener guard with nil customMode
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 4: sleepListener guard passes with nil customMode")
print("═══════════════════════════════════════════════════════════\n")

print("popup.swift:881 — sleepListener guard:")
print("  guard ... self.fan.customMode != .automatic else { return }\n")

let nilMode: FanMode? = nil
print("  nil != .automatic  =  \(nilMode != .automatic)  ← Guard passes when it shouldn't")
print("  (user never set a custom mode, so customMode is nil)\n")

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 5: .isAutomatic is defined but NEVER used anywhere
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 5: .isAutomatic is dead code")
print("═══════════════════════════════════════════════════════════\n")

print("PR #2924 added to SMC/smc.swift:")
print("  public var isAutomatic: Bool {")
print("      self == .automatic || self == .auto3")
print("  }\n")
print("grep -r 'isAutomatic' finds ZERO uses outside the definition.")
print("All 7+ comparison sites use == .automatic or != .automatic instead.\n")

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 6: Full callback chain from setMode(.forced)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 6: setMode(.forced) triggers SMC write, not just UI")
print("═══════════════════════════════════════════════════════════\n")

print("popup.swift:933 → self.modeButtons?.setMode(.forced)")
print("popup.swift:1189-1194 → ModeButtons.setMode(.forced):")
print("  self.manualBtn.state = .on")
print("  self.callback(.forced)           ← triggers the fan callback")
print("popup.swift:656-661 → callback(.forced):")
print("  self.fan.customMode = .forced    ← PERSISTS to UserDefaults")
print("  SMCHelper.shared.setFanMode(     ← WRITES to SMC via XPC")
print("    fan.id, mode: 1)")
print("Kit/helpers.swift:888 → XPC → Helper → smc CLI → smc.swift")
print("smc.swift:361 → unlockFanControl(fanId:)")
print("  Writes Ftst=1, waits 3s, writes F%%dMd=1")
print("  → Fan is now in MANUAL mode\n")

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROOF 7: UserDefaults corruption evidence
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("PROOF 7: Check this machine's UserDefaults for corruption")
print("═══════════════════════════════════════════════════════════\n")

let defaults = UserDefaults(suiteName: "eu.exelban.Stats")
var foundCorruption = false

for i in 0...3 {
    let modeKey = "fan_\(i)_mode"
    let speedKey = "fan_\(i)_speed"

    let hasMode = defaults?.object(forKey: modeKey) != nil
    let hasSpeed = defaults?.object(forKey: speedKey) != nil

    if hasMode || hasSpeed {
        let mode = defaults?.integer(forKey: modeKey) ?? -1
        let speed = defaults?.integer(forKey: speedKey) ?? -1
        let modeStr = mode == 0 ? "automatic" : mode == 1 ? "FORCED ⚠️" : "\(mode)"
        print("  Fan \(i): customMode=\(modeStr), customSpeed=\(speed)")
        if mode == 1 { foundCorruption = true }
    }
}

let speedState = defaults?.bool(forKey: "Sensors_speed") ?? false
print("  Sensors_speed (save fan speed): \(speedState)")
print()

if foundCorruption {
    print("  ⚠️  CORRUPTION DETECTED: fan(s) have customMode=1 (forced) persisted.")
    print("  If you never manually set forced mode, this is evidence of the bug.\n")
    print("  To reset: defaults delete eu.exelban.Stats fan_0_mode")
    print("            defaults delete eu.exelban.Stats fan_1_mode")
    print("            defaults delete eu.exelban.Stats fan_0_speed")
    print("            defaults delete eu.exelban.Stats fan_1_speed\n")
} else {
    print("  No corruption found on this machine.\n")
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Summary
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print("═══════════════════════════════════════════════════════════")
print("SUMMARY")
print("═══════════════════════════════════════════════════════════\n")

print("The bug chain:")
print("1. On Apple Silicon, thermalmonitord can report F%%dMd = 3 (system mode)")
print("2. loadFans() stores this as FanMode.auto3 without normalization")
print("3. After wake, resetModeAfterSleep is set to true")
print("4. update() checks: value.mode != .automatic")
print("5. .auto3 != .automatic = TRUE ← wrong, .auto3 IS automatic")
print("6. setMode(.forced) is called → writes F%%dMd=1 to SMC → manual mode")
print("7. No target speed set → fans run at max or min unpredictably\n")

print("The fix: replace all 'mode != .automatic' / 'mode == .automatic'")
print("comparisons with '!mode.isAutomatic' / 'mode.isAutomatic'.\n")

print("Verification needed on M4 Max: run './smc list -f | grep Md'")
print("to confirm F%%dMd returns 3 under thermalmonitord control.")
