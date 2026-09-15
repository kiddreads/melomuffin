//
//  SettingsView.swift
//  melomuffin
//
//  Adapted from cemu-ios-muffin's src/ios/App/SettingsView.swift.
//
//  MELOMUFFIN ADAPTATION NOTE: Muffin's original (903 lines) is a much larger
//  screen than this - it covers per-game shader precompilation, device
//  diagnostics (cemu_bridge_device_report), shader-cache stats/clearing
//  (cemu_bridge_shader_cache_stats/_clear_shader_cache), a "legacy timebase" and
//  "reduce encoder splitting" toggle, and CPU-mode diagnostic text
//  (cemu_bridge_cpu_mode_detail) - none of which have a verified MeloCafe-side
//  equivalent (see this repo's README "Known gaps" section), so none of it is
//  guessed at here.
//
//  What DOES have a real, verified MeloCafe equivalent and is wired below:
//    - CPU mode / recompiler          -> ConfigManager.interpreter (CemuConfigWrapper.cpuMode)
//    - Renderer (Vulkan/Metal)        -> ConfigManager.renderer
//    - VSync                          -> ConfigManager.vsync (cemu_bridge_set_vsync_enabled's
//                                         real equivalent - CAMetalLayer.displaySyncEnabled)
//    - Async shader compile           -> ConfigManager.asyncCompile
//    - Stretch to fill                -> ConfigManager.fullscreenScaling (== .stretch)
//    - Emulated clock (timebase)      -> TimebaseScale.swift, adapted onto the new
//                                         CemuTimebase_GetShift/SetShift bridge functions
//    - Graphic packs                  -> GraphicPacksView.swift, adapted onto
//                                         GraphicPackManager
//    - Wii U decryption keys          -> WiiUKeys.swift, unmodified (no bridge calls at all)
//
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var gameManager: GameManager
    @ObservedObject private var config = ConfigManager.shared
    @State private var timebaseSelection = TimebaseScale.current
    @State private var showingKeyImporter = false
    @State private var keyImportMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Emulation") {
                    Picker("CPU mode", selection: config.interpreter) {
                        ForEach(CPUMode.allCases, id: \.self) { mode in
                            Text(mode.string).tag(mode)
                        }
                    }
                    Picker("Renderer", selection: config.renderer) {
                        ForEach(Renderer.allCases, id: \.self) { renderer in
                            Text(renderer.string).tag(renderer)
                        }
                    }
                }

                Section {
                    Picker("Emulated clock", selection: $timebaseSelection) {
                        ForEach(TimebaseScale.allCases) { scale in
                            Text(scale.title).tag(scale)
                        }
                    }
                    .onChange(of: timebaseSelection) { newValue in
                        TimebaseScale.apply(newValue)
                    }
                    Text(timebaseSelection.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } header: {
                    Text("Timing")
                } footer: {
                    Text("Slows the guest console's own clock so its deadlines stay reachable under the forced PPC interpreter. Does not change any emulated result.")
                }

                Section("Display") {
                    Toggle("VSync", isOn: config.vsync)
                    Toggle("Async shader compile", isOn: config.asyncCompile)
                    Toggle("Stretch to fill screen", isOn: Binding(
                        get: { config.fullscreenScaling.wrappedValue == .stretch },
                        set: { config.fullscreenScaling.wrappedValue = $0 ? .stretch : .keepAspectRatio }
                    ))
                }

                Section {
                    NavigationLink("Graphic Packs") {
                        GraphicPacksView()
                    }
                }

                Section {
                    Button("Import Wii U decryption keys…") { showingKeyImporter = true }
                    if WiiUKeys.keysFileExists() {
                        Text("\(WiiUKeys.installedKeyCount()) key(s) installed")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("Remove keys", role: .destructive) {
                            try? WiiUKeys.removeKeys()
                        }
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("Your own console's keys.txt - dumped from a Wii U you own. Required to boot an encrypted disc image; homebrew works without it.")
                }

                Section {
                    Button("Back to games") { dismiss() }
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showingKeyImporter, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    do {
                        let count = try WiiUKeys.importKeys(from: url)
                        keyImportMessage = "Imported \(count) key(s)."
                    } catch {
                        keyImportMessage = error.localizedDescription
                    }
                case .failure(let error):
                    keyImportMessage = error.localizedDescription
                }
            }
            .alert("Keys", isPresented: .constant(keyImportMessage != nil), presenting: keyImportMessage) { _ in
                Button("OK") { keyImportMessage = nil }
            } message: { Text($0) }
        }
    }
}
