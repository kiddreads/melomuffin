# melomuffin

MeloCafe's Cemu core and iOS bridge, unmodified, with Muffin's own UI in place of
MeloCafe's UI.

[MeloCafe](https://github.com/stossy11/MeloCafe) by stossy11 is a Wii U emulator
for iOS/macOS built on [Cemu](https://github.com/cemu-project/Cemu), with its own
Swift-to-C++ bridge and its own SwiftUI app. [Muffin](https://github.com/kiddreads/cemu-ios-muffin)
is a separate iOS Cemu port with its own bridge and its own SwiftUI app, built
around different integration choices.

This repository is MeloCafe's tree, kept exactly as MeloCafe has it - the Cemu
core, the build system, the existing Swift-to-C++ bridge (`Core/`,
`src/gui/uikit/WindowSystem.mm`, `src/config/*Wrapper.mm`, and so on) - with only
`MeloCafe/MeloCafe/UI/` replaced by Muffin's own UI, adapted to call MeloCafe's
real bridge instead of Muffin's.

It is **not** a merge of the two codebases (that is a different, existing project -
[kiddreads/MuffinEMU](https://github.com/kiddreads/MuffinEMU) - which unifies
Muffin's UI and a shared core into one tree). This repository deliberately keeps
MeloCafe's tree and bridge as-is and only swaps the UI folder.

## What actually changed

- `MeloCafe/MeloCafe/UI/` - previously MeloCafe's own SwiftUI screens - now holds
  Muffin's UI (originally `src/ios/App/*.swift` in cemu-ios-muffin), adapted to
  call MeloCafe's real bridge. See "Known gaps" below for what is and isn't wired.
- `MeloCafe/MeloCafe/Common/Alert.swift` (MeloCafe's own UIAlertController helper,
  used only by the UI screens it shipped with) was removed along with the UI that
  used it.
- `MeloCafe/MeloCafe/UI/Emulation/MetalView.swift` and `MetalViewContainer.swift` -
  MeloCafe's own CAMetalLayer-backed render-surface views, genuinely bridge glue
  rather than swappable UI - were kept, and moved to
  `MeloCafe/MeloCafe/Core/RenderBridge/` to make that boundary explicit. Muffin's
  UI now uses MeloCafe's real `MetalView` (via the adapted `DisplayRouter`) instead
  of a raw `UIView`.
- Two small, real additions to MeloCafe's own bridge layer, in its own style, both
  wrapping code that already existed in this repo's core:
  - `CemuUIKit_IsPadOpen()` (`src/gui/uikit/WindowSystem.mm`) - a getter over the
    already-real `WindowSystem::IsPadWindowOpen()`. Muffin's UI needs to ask
    whether a GamePad surface is currently registered; nothing exposed that before.
  - `CemuTimebase_GetShift()` / `CemuTimebase_SetShift()` (`src/main.cpp`) - thin
    wrappers over `ActiveSettings::GetTimerShiftFactor()` /
    `SetTimerShiftFactor()`, both already present in this repo's
    `src/config/ActiveSettings.h/.cpp`. Backs Muffin's "Emulated clock" setting.
- `MeloCafe.xcodeproj/project.pbxproj`: three ported-but-unadapted UI files
  (see below) are added to the existing `PBXFileSystemSynchronizedBuildFileExceptionSet`
  membership-exception list so they're present in the repo but excluded from the
  `MeloCafe` target's Sources - the same mechanism the project already used to
  exclude `Assets/Info.plist`/`Assets/MeloNX.xcconfig` from Sources. Everything
  else under `MeloCafe/MeloCafe/` is a
  [file-system-synchronized group](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes),
  so the UI swap itself needed no other project file changes - Xcode picks up
  added/removed/moved files under that folder automatically.

## Known gaps

Ported honestly, not faked: where Muffin's UI called a Muffin-only bridge function
with no verified MeloCafe equivalent, the calling code was adapted to MeloCafe's
real equivalent where one exists, or the feature was removed from the UI (never
left calling a function that doesn't exist, and never backed by an invented stub).

**Removed from the UI, kept in the repo for a future pass** (present under
`MeloCafe/MeloCafe/UI/`, excluded from the Xcode target's Sources - see above):

- `DlcUpdateImport.swift` - DLC/update install, matching, and removal. Wraps
  `cemu_bridge_inspect_title`, `cemu_bridge_derive_content_title_id`,
  `cemu_bridge_get_mlc_title_path_components`, etc. MeloCafe's core almost
  certainly has the underlying pieces (`TitleInfo::GetAppTitleId`,
  `CafeTitleList::FindBaseTitleId`, `TitleInfo`'s `InvalidReason` enum, and
  `TitleIdParser`'s type byte are all present in this repo's `src/Cafe/TitleList`
  and `src/Cafe/Filesystem/FST`), but wiring five new bridge functions against
  those headers correctly, with real signatures rather than guessed ones, is a
  separate pass this one didn't have time for.
- `DecryptROMView.swift` - "Decrypt to Files/WUA". Wraps
  `cemu_bridge_start_decrypt`/`_get_decrypt_progress`/`_cancel_decrypt`, which
  would need a new `FSTVolume`/`TitleInfo`-based decrypt subsystem added to
  MeloCafe's bridge. Not attempted this pass.
- `CoverArtFetcher.swift` - automatic GameTDB box-art fetch on import. Derives a
  GameTDB ID via Muffin's own `IOSCoverArt.cpp`, which has no MeloCafe-side
  equivalent at all (this is Muffin-authored glue, not upstream Cemu).

**Simplified or removed for a real, verified reason** (see the adaptation-note
comment at the top of each file for specifics):

- Pause/resume - removed. MeloCafe's `src/Cafe/CafeSystem.h` declares
  `ShutdownTitle()` but no `PauseTitle()`/`ResumeTitle()`, so there is nothing
  real for Muffin's pause button (or its background/foreground auto-pause) to
  call. A running title is not currently paused when the app backgrounds.
- Live FPS/boot-progress HUD - the HUD stays on screen but always reads "-- FPS"
  rather than a real number. MeloCafe's bridge has no equivalent to
  `cemu_bridge_get_fps()`/`cemu_bridge_get_progress()`.
- Shader-cache stats/clear, the "reduce encoder splitting" and "legacy timebase"
  toggles, and the CPU-mode diagnostic string in Settings - removed from
  `SettingsView.swift`. No verified MeloCafe-side equivalent
  (`g_shaderCachePersistenceEnabled` does not appear in this repo's `LatteShader`
  code, and no getter/setter pair for the other two was found).
- Muffin's own device-diagnostics report (`cemu_bridge_device_report`) - removed.
  A real replacement (pure OS APIs, no core dependency) would be easy to add but
  wasn't done this pass.
- The on-screen pad's automatic "timebase ladder" (steps the emulated clock down
  by itself while booting) - removed; only manual control
  (`CemuTimebase_GetShift/SetShift`, above) was ported. The ladder lived entirely
  in Muffin's own bridge as a background timer watching boot-progress counters
  this bridge doesn't have.
- Muffin's resource icons (`icon-manifest.json`, the alternate-icon
  `Assets.xcassets`) were copied to `MeloCafe/MeloCafe/UIResources/` alongside the
  UI so `IconPickerView.swift`/`IconManifest.swift` have something to read, but
  this was **not build-verified** - if `IconManifest.swift` expects that resource
  at a specific bundle-relative path, it may need moving.

**What is genuinely wired to MeloCafe's real bridge**, not faked:

- Game boot/list/icon/run/shutdown (`GameManager.swift`, rewritten as a thin
  adapter over MeloCafe's own `GamesManager`/`CemuManager`/`ControllerManager` -
  see that file's header comment for why a rewrite, not a port, was the right
  call: MeloCafe's C++ core already has a real title list
  (`CafeTitleList`/`CemuGetAllGames`), where Muffin's own `GameManager` had to
  build one itself in Swift because its bridge has no equivalent).
- Display/window routing (`DisplayRouter.swift`, adapted onto
  `CemuUIKit_SetMainView/SetPadView/InitializeLayer/ShutdownLayer/
  UpdateMainWindowSize/UpdatePadWindowSize` plus the new `CemuUIKit_IsPadOpen()`).
  Muffin's own dual-screen/AirPlay placement logic is untouched.
- The on-screen pad's buttons and stick (`ContentView.swift`), now driving
  MeloCafe's own `VirtualController` (`ControllerManager.shared.virtualController`)
  instead of Muffin's `cemu_bridge_set_button_state`/`set_stick_axis`.
- CPU mode, renderer, VSync, async shader compile, and stretch-to-fill in
  Settings - all real `ConfigManager`/`CemuConfigWrapper` bindings MeloCafe
  already had.
- Graphic packs (`GraphicPacksView.swift`, rewritten against MeloCafe's real
  `GraphicPackManager` instead of Muffin's own wire-format bridge calls).
- Wii U decryption keys (`WiiUKeys.swift`) - copied unmodified; it never called
  Muffin's bridge in the first place.

## What could not be verified here

No iOS toolchain (Xcode/`xcodebuild` targeting `iphoneos`, or the vcpkg-built
dependencies) was available in the environment this port was built in - the same
constraint other work on this machine has hit this session. What *was* checked:

- Every bridge symbol this port calls, on both the "does Muffin call it" and
  "does MeloCafe/its Cemu core actually have it" sides, was verified by reading
  the real headers/`.mm`/`.cpp` files (`grep`-confirmed, not assumed) - see the
  per-file adaptation notes for exactly which core symbols were checked
  (`ActiveSettings::GetTimerShiftFactor/SetTimerShiftFactor`,
  `WindowSystem::IsPadWindowOpen`, `CemuConfigWrapper`'s real property list,
  `GraphicPackManager`'s real method list, `VirtualController`'s real button
  bit-mapping).
- Every Swift type this port's rewritten files reference from the kept/unmodified
  UI files (`WiiUControllerSkin`, `MuffinTheme`, `ControllerLayoutSettings`,
  `PerGameSettingsStore`, `OrganizedControllerSkinSelector`,
  `MuffinSecondaryButtonStyle`/`MuffinPrimaryButtonStyle`, `IconPickerView`,
  `DocumentImport`) was confirmed to actually exist with a matching name.
- A full `swiftc`/Xcode build was **not** run. `git submodule update --init` was
  also not run (this repo, like a plain `git clone` of MeloCafe without
  `--recurse-submodules`, has empty submodule directories under `dependencies/`
  until that's done) - dependency compilation was out of scope given the toolchain
  gap.

If the true build turns up further mismatches (an ObjC property name that differs
subtly from what a call site expects, a missing target-membership entry for the
relocated `Core/RenderBridge/` files, etc.), they are exactly that class of
finding this write-up expects rather than something masked.

## Credits and license

- [Cemu](https://github.com/cemu-project/Cemu) (MPL-2.0), the emulator this is
  built on.
- [MeloCafe](https://github.com/stossy11/MeloCafe) by stossy11 (MPL-2.0) - the
  core, build system, and bridge this repository keeps unmodified.
- [Muffin](https://github.com/kiddreads/cemu-ios-muffin) (MPL-2.0) - the UI this
  repository ported in, by Brandon (kiddreads).
- [Melo-Controller](https://github.com/stossy11/Melo-Controller) by stossy11
  (GPL-3.0) - MeloCafe's own virtual-controller bridge, which this repository's
  UI now drives directly (see `ContentView.swift`'s pad wiring). Linked in every
  build, as it already was in MeloCafe's own.
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache-2.0).

This repository's source is MPL-2.0, like Cemu, MeloCafe and Muffin; see
`LICENSE.txt`. Source files keep their original copyright and authorship notices -
MeloCafe's files keep MeloCafe's, Muffin's files keep Muffin's.

Same reasoning as [kiddreads/MuffinEMU](https://github.com/kiddreads/MuffinEMU#credits-and-license),
which faces the identical combination: MeloCafe's own `Core/Controller/
VirtualController.swift` links Melo-Controller, and MPL-2.0 code may be combined
into a GPL work, so a **built app** from this repository is, as a whole,
distributed under GPL-3.0, with this repository as its source.
