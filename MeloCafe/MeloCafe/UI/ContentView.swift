//
//  ContentView.swift
//  melomuffin
//
//  Adapted from cemu-ios-muffin's src/ios/App/ContentView.swift.
//
//  MELOMUFFIN ADAPTATION NOTE - what changed and why, all tied to real, verified
//  gaps (see the repo README's "Known gaps" section for the full list):
//
//  - DLC/update import ("Import DLC…"/"Import Update…" menu entries, the
//    long-press "Remove DLC/Update" entries, and the game-picker/confirmation
//    sheets that went with them) is REMOVED from this view. It called
//    DlcUpdateImport.swift, which wraps cemu_bridge_inspect_title /
//    cemu_bridge_derive_content_title_id / cemu_bridge_get_mlc_title_path_components
//    - none of which exist on MeloCafe's bridge. MeloCafe's own core almost
//    certainly has the underlying TitleInfo/CafeTitleList machinery (confirmed
//    present: TitleInfo::GetAppTitleId, CafeTitleList::FindBaseTitleId, TitleInfo's
//    InvalidReason enum, TitleIdParser's type byte), but wiring five new bridge
//    functions against those headers correctly is a real, separate pass - not
//    done here. DlcUpdateImport.swift itself is kept in this repo, unmodified, for
//    that future pass; it is just not part of this app target's Sources yet.
//  - "Decrypt to Files/WUA" (the per-game context menu entry and its sheet) is
//    REMOVED for the same reason: DecryptROMView.swift calls
//    cemu_bridge_start_decrypt/cemu_bridge_get_decrypt_progress/
//    cemu_bridge_cancel_decrypt, which would need a new FSTVolume/TitleInfo-based
//    bridge subsystem to back it. Also kept, unmodified, out of Sources.
//  - Pause/resume is REMOVED (button and the scenePhase-triggered auto-pause).
//    Muffin's cemu_bridge_pause()/cemu_bridge_resume() wrap CafeSystem::PauseTitle/
//    ResumeTitle - MeloCafe's own src/Cafe/CafeSystem.h only declares
//    ShutdownTitle(), no PauseTitle/ResumeTitle at all, so there is nothing real to
//    call. Backgrounding a running title is therefore NOT handled on this port yet
//    (a real, open gap, not something to fake with a no-op "pause").
//  - The on-screen pad's button/stick calls now go through MeloCafe's own
//    VirtualController (Core/Controller/VirtualController.swift,
//    ControllerManager.shared.virtualController) instead of Muffin's
//    cemu_bridge_set_button_state/cemu_bridge_set_stick_axis/
//    cemu_bridge_release_all_buttons - see cemuButton(forLabel:) and
//    releaseAllVirtualButtons() below. MeloCafe's virtual controller has to be
//    attached to the core the same way a physical one is
//    (ControllerManager.attachAllToCore(), already called by CemuManager.run()) for
//    presses to reach a running title.
//  - The live FPS HUD stays on screen but is honest about not having a real
//    number: GameManager.frameRate is hardcoded to 0 (MeloCafe's bridge has no
//    cemu_bridge_get_fps()/cemu_bridge_get_progress() equivalent), so it always
//    reads "-- FPS" rather than a fabricated value.
//
import SwiftUI
import MetalKit
import UniformTypeIdentifiers
import Melo_Controller

struct ContentView: View {
    @StateObject var gameManager = GameManager()
    @State private var selectedGame: GameMetadata?
    @State private var showingGameBrowser = true
    @State private var selectedSkin: WiiUControllerSkin = WiiUControllerSkin.standard

    var body: some View {
        ZStack {
            if showingGameBrowser {
                GameBrowserView(
                    gameManager: gameManager,
                    selectedGame: $selectedGame,
                    showingGameBrowser: $showingGameBrowser
                )
            } else if let game = selectedGame {
                switch gameManager.emulationState {
                case .loading, .running, .paused:
                    EmulatorViewOptimized(
                        game: game,
                        gameManager: gameManager,
                        isRunning: $showingGameBrowser,
                        controllerSkin: $selectedSkin
                    )
                case .error:
                    BootFailureView(
                        game: game,
                        message: gameManager.lastStatusMessage,
                        onDismiss: {
                            gameManager.stopEmulation()
                            showingGameBrowser = true
                        }
                    )
                case .idle:
                    Color.clear.onAppear { showingGameBrowser = true }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { gameManager.loadGames() }
    }
}

struct BootFailureView: View {
    let game: GameMetadata
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(MuffinTheme.blushPink)

                Text("Couldn't start \(game.title)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(message.isEmpty ? "The engine didn't report a reason." : message)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 480)

                Button(action: onDismiss) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back to games")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(MuffinSecondaryButtonStyle())
                .padding(.top, 4)
            }
            .padding(32)
        }
    }
}

struct GameBrowserView: View {
    @ObservedObject var gameManager: GameManager
    @Binding var selectedGame: GameMetadata?
    @Binding var showingGameBrowser: Bool
    @State private var showingFavorites = false
    @State private var searchText = ""
    @State private var showingIconPicker = false
    @State private var showingSettings = false
    @State private var gameOptionsTarget: GameMetadata?
    @ObservedObject private var perGameSettings = PerGameSettingsStore.shared

    private static let fileImportTypes: [UTType] = [.item]
    private static let folderImportTypes: [UTType] = [.folder]

    @State private var romImportErrorMessage: String?

    var filteredGames: [GameMetadata] {
        let gamesToShow = showingFavorites ? gameManager.favorites : gameManager.games
        return searchText.isEmpty
            ? gamesToShow
            : gamesToShow.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack {
            MuffinTheme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    Button(action: { showingIconPicker = true }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Muffin")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(MuffinTheme.sparkleCream)

                            Text("EMU")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(MuffinTheme.pixelBlue)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(MuffinTheme.sparkleCream.opacity(0.8))
                        }
                        .frame(width: 44, height: 44)
                        .background(MuffinTheme.sparkleCream.opacity(0.15))
                        .cornerRadius(14)

                        Button(action: { showingFavorites.toggle() }) {
                            Image(systemName: showingFavorites ? "heart.fill" : "heart")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(showingFavorites ? MuffinTheme.blushPink : MuffinTheme.sparkleCream.opacity(0.8))
                        }
                        .frame(width: 44, height: 44)
                        .background(MuffinTheme.sparkleCream.opacity(0.15))
                        .cornerRadius(14)

                        Menu {
                            Button {
                                beginImport(contentTypes: Self.fileImportTypes)
                            } label: {
                                Label("Game file (.wux, .wud, .wua, .iso, .rpx, .elf, .wuhb)", systemImage: "doc")
                            }
                            Button {
                                beginImport(contentTypes: Self.folderImportTypes)
                            } label: {
                                Label("Game folder (code/content/meta)", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(MuffinTheme.sparkleCream.opacity(0.8))
                                .frame(width: 44, height: 44)
                                .background(MuffinTheme.sparkleCream.opacity(0.15))
                                .cornerRadius(14)
                        }

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(filteredGames.count)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(MuffinTheme.sparkleCream)
                            Text("games")
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                .foregroundColor(MuffinTheme.sparkleCream.opacity(0.7))
                        }
                    }
                }
                .padding(20)

                VStack(spacing: 12) {
                    SearchBarPolished(text: $searchText)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    if gameManager.isLoading {
                        LoadingView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredGames.isEmpty {
                        EmptyGamesView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 140), spacing: 16)],
                                spacing: 20
                            ) {
                                ForEach(filteredGames) { game in
                                    GameCardOptimized(
                                        game: game,
                                        onTap: {
                                            selectedGame = game
                                            gameManager.launchGame(game)
                                            showingGameBrowser = false
                                        },
                                        onFavoriteTap: {
                                            gameManager.toggleFavorite(game)
                                        }
                                    )
                                    .contextMenu {
                                        Button {
                                            gameManager.toggleFavorite(game)
                                        } label: {
                                            Label(game.isFavorite ? "Remove favorite" : "Add favorite",
                                                  systemImage: game.isFavorite ? "heart.slash" : "heart")
                                        }
                                        Button {
                                            gameOptionsTarget = game
                                        } label: {
                                            Label("Game options", systemImage: "slider.horizontal.3")
                                        }
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(
                    MuffinTheme.cream
                        .clipShape(RoundedCorner(radius: 28, corners: [.topLeft, .topRight]))
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .sheet(isPresented: $showingIconPicker) {
            IconPickerView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(gameManager: gameManager)
        }
        .sheet(item: $gameOptionsTarget) { game in
            GameOptionsView(game: game, store: perGameSettings)
        }
        .alert("Couldn't import ROM", isPresented: .constant(romImportErrorMessage != nil), presenting: romImportErrorMessage) { _ in
            Button("OK") { romImportErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func beginImport(contentTypes: [UTType]) {
        DocumentImport.present(contentTypes: contentTypes) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    try await gameManager.importROM(from: url)
                } catch {
                    romImportErrorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            romImportErrorMessage = error.localizedDescription
        }
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

struct GameCardOptimized: View {
    let game: GameMetadata
    let onTap: () -> Void
    let onFavoriteTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(MuffinTheme.muffinTopGradient)

                if let coverPath = game.coverPath,
                   let uiImage = UIImage(contentsOfFile: coverPath) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .cornerRadius(16)
                } else {
                    VStack {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 28))
                            .foregroundColor(MuffinTheme.sparkleCream)
                    }
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: onFavoriteTap) {
                            Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(game.isFavorite ? MuffinTheme.blushPink : MuffinTheme.sparkleCream)
                                .frame(width: 32, height: 32)
                                .background(MuffinTheme.brownDarkest.opacity(0.35))
                                .cornerRadius(10)
                        }
                        .padding(8)
                    }
                    Spacer()
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)

            VStack(alignment: .leading, spacing: 8) {
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .foregroundColor(MuffinTheme.brownDarkest)

                HStack(spacing: 8) {
                    Label(game.region, systemImage: "globe")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(MuffinTheme.brownMid)
                    Spacer()
                }

                Button(action: onTap) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Play")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MuffinPrimaryButtonStyle())
            }
            .padding(12)
            .background(MuffinTheme.cream)
        }
        .background(MuffinTheme.cream)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MuffinTheme.wrapper, lineWidth: 1)
        )
        .shadow(color: MuffinTheme.shadow.opacity(0.15), radius: 8, x: 0, y: 4)
    }
}

struct SearchBarPolished: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(MuffinTheme.brownMid)

            TextField("Search games...", text: $text)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .textFieldStyle(.plain)
                .foregroundColor(MuffinTheme.brownDarkest)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(MuffinTheme.brownMid)
                }
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .background(MuffinTheme.wrapper.opacity(0.5))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(MuffinTheme.wrapper, lineWidth: 1)
        )
    }
}

struct LoadingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .semibold))
                .foregroundColor(MuffinTheme.muffinTopDark)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Text("Loading games...")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(MuffinTheme.brownDarkest)
        }
    }
}

struct EmptyGamesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 56, weight: .regular))
                .foregroundColor(MuffinTheme.muffinTopDark.opacity(0.5))

            VStack(spacing: 8) {
                Text("No Games Found")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(MuffinTheme.brownDarkest)

                VStack(alignment: .center, spacing: 4) {
                    Text("Add .wux, .wud, .wua, .rpx, .elf, .wuhb, or .iso files")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(MuffinTheme.brownMid)

                    Text("to Documents/Roms/ on your device")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(MuffinTheme.brownMid)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum LaunchLogSettings {
    static let showKey = "muffin.showLaunchLog"
}

struct EmulatorViewOptimized: View {
    let game: GameMetadata
    @ObservedObject var gameManager: GameManager
    @Binding var isRunning: Bool
    @Binding var controllerSkin: WiiUControllerSkin
    @State private var showSkinSelector = false
    @State private var isEditingControlLayout = false
    @AppStorage(ControllerLayoutSettings.scaleKey)
    private var controlScale = ControllerLayoutSettings.defaultScale
    @AppStorage(ControllerLayoutSettings.opacityKey)
    private var controlOpacity = ControllerLayoutSettings.defaultOpacity
    @AppStorage(ControllerLayoutSettings.joystickKey)
    private var joystickMode = ControllerLayoutSettings.defaultJoystick
    @AppStorage(ControllerLayoutSettings.individualEditModeKey)
    private var individualEditMode = ControllerLayoutSettings.defaultIndividualEditMode
    @AppStorage(ControllerLayoutSettings.deadzoneKey)
    private var stickDeadzone = ControllerLayoutSettings.defaultDeadzone
    @AppStorage(ControllerLayoutSettings.stickCurveKey)
    private var stickCurve = ControllerLayoutSettings.defaultStickCurve
    @AppStorage(ControllerLayoutSettings.stickGateKey)
    private var stickGateRaw = ControllerLayoutSettings.defaultStickGateRaw

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: {
                        gameManager.stopEmulation()
                        isRunning = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                    }
                    .buttonStyle(MuffinSecondaryButtonStyle())

                    VStack(alignment: .center, spacing: 2) {
                        Text(game.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(controllerSkin.name)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(MuffinTheme.pixelBlue)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        Button(action: { showSkinSelector.toggle() }) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(MuffinSecondaryButtonStyle())

                        // No pause button here - see this file's header note: MeloCafe's
                        // CafeSystem has no PauseTitle()/ResumeTitle() to call.
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEditingControlLayout.toggle()
                            }
                            releaseAllVirtualButtons()
                        }) {
                            Image(systemName: isEditingControlLayout
                                  ? "checkmark.circle.fill"
                                  : "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(MuffinSecondaryButtonStyle())

                        HStack(spacing: 6) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 12, weight: .semibold))
                            Text(gameManager.progress.hudText(wholeFramesPerSecond: gameManager.frameRate))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundColor(MuffinTheme.blushPink)
                        .frame(height: 40)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.5))
                .borderBottom(width: 0.5, color: Color.white.opacity(0.1))

                if showSkinSelector {
                    OrganizedControllerSkinSelector(selectedSkin: $controllerSkin)
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                MetalViewIOS(gameManager: gameManager)
                    .ignoresSafeArea()
                    .clipped()
            }

            OptimizedControlPanel(
                skin: controllerSkin,
                onInput: { label, pressed in
                    setVirtualButton(cemuButton(forLabel: label), pressed: pressed)
                },
                onStick: { stick, position in
                    ControllerManager.shared.virtualController.setThumbstick(
                        CGPoint(x: position.x, y: -position.y), right: stick == 1
                    )
                },
                isEditingLayout: $isEditingControlLayout
            )

            if gameManager.emulationState == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Booting…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }

            if isEditingControlLayout {
                VStack {
                    VStack(spacing: 10) {
                        Picker("Edit mode", selection: $individualEditMode) {
                            Text("Grouped").tag(false)
                            Text("Individual").tag(true)
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 10) {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                            Slider(
                                value: $controlScale,
                                in: ControllerLayoutSettings.minScale...ControllerLayoutSettings.maxScale
                            )
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                            Slider(value: $controlOpacity, in: 0.2...1.0)
                            Image(systemName: "circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }

                        Toggle(isOn: $joystickMode) {
                            Text("Joystick instead of d-pad")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .tint(MuffinTheme.brownDarkest)

                        HStack(spacing: 12) {
                            Button("Reset layout") { ControllerLayoutSettings.reset() }
                                .buttonStyle(MuffinSecondaryButtonStyle())

                            Button("Done") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isEditingControlLayout = false
                                }
                            }
                            .buttonStyle(MuffinSecondaryButtonStyle())
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 420)
                    .background(Color.black.opacity(0.82))
                    .cornerRadius(14)
                    .padding(.top, 12)

                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .onDisappear {
            releaseAllVirtualButtons()
        }
    }
}

/// Translates the on-screen pad's label ("up", "A", "ZL"...) into MeloCafe's own
/// `Melo_Controller.VirtualControllerButton`, mirroring
/// `VirtualController.updateState()`'s bit mapping (Core/Controller/
/// VirtualController.swift) - the real source of truth for which button is which.
private func cemuButton(forLabel label: String) -> VirtualControllerButton {
    switch label {
    case "up":    return .dPadUp
    case "down":  return .dPadDown
    case "left":  return .dPadLeft
    case "right": return .dPadRight

    case "A": return .A
    case "B": return .B
    case "X": return .X
    case "Y": return .Y

    case "L":  return .leftShoulder
    case "R":  return .rightShoulder
    case "ZL": return .leftTrigger
    case "ZR": return .rightTrigger

    case "plus":  return .start
    case "minus": return .back

    case "L3": return .leftStick
    case "R3": return .rightStick

    default: return .A
    }
}

private func setVirtualButton(_ button: VirtualControllerButton, pressed: Bool) {
    let controller = ControllerManager.shared.virtualController
    if pressed {
        controller.pressButton(button)
    } else {
        controller.releaseButton(button)
    }
}

/// Adapts cemu_bridge_release_all_buttons() (Muffin's global "let go of everything"
/// call) - MeloCafe's VirtualController has no single release-all, so this releases
/// each button VirtualController.updateState() knows about instead.
private func releaseAllVirtualButtons() {
    let controller = ControllerManager.shared.virtualController
    let all: [VirtualControllerButton] = [
        .A, .B, .X, .Y, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
        .back, .start, .leftStick, .rightStick, .dPadUp, .dPadDown, .dPadLeft, .dPadRight,
    ]
    for button in all {
        controller.releaseButton(button)
    }
    controller.setThumbstick(.zero, right: false)
    controller.setThumbstick(.zero, right: true)
}

struct BorderBottomModifier: ViewModifier {
    let width: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            Divider()
                .frame(height: width)
                .background(color)
        }
    }
}

extension View {
    func borderBottom(width: CGFloat, color: Color) -> some View {
        self.modifier(BorderBottomModifier(width: width, color: color))
    }
}

func installJITTrapHandler() {
    var sa = sigaction()
    sa.sa_flags = SA_SIGINFO
    sa.__sigaction_u.__sa_sigaction = { sig, info, context in
        guard let context else { return }
        let uc = context.bindMemory(to: ucontext_t.self, capacity: 1)
        uc.pointee.uc_mcontext.pointee.__ss.__pc += 4
        uc.pointee.uc_mcontext.pointee.__ss.__x.0 = 0
    }
    sigaction(SIGTRAP, &sa, nil)
}
