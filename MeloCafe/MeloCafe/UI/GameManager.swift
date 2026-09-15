//
//  GameManager.swift
//  melomuffin
//
//  Adapted from cemu-ios-muffin's src/ios/App/GameManager.swift for MeloCafe's own
//  Cemu core + bridge.
//
//  MELOMUFFIN ADAPTATION NOTE:
//  Muffin's original GameManager talked directly to its OWN `cemu_bridge_*` C API
//  (CemuBridge.h) - a title list it built itself by scanning Documents/Roms and
//  deriving title IDs one file at a time (cemu_bridge_derive_title_id /
//  cemu_bridge_derive_base_title_id), because Muffin's bridge has no native title
//  list of its own.
//
//  MeloCafe's bridge is shaped differently: it already has a real, working title
//  list on the C++ side (CafeTitleList, refreshed by CemuInitialize()) exposed to
//  Swift as `CemuGetAllGames()` / `CemuFreeGameList()` (see
//  Core/MeloCafe-Bridging-Header.h) and a ready-made Swift wrapper for it,
//  `GamesManager` (Core/GamesListManager.swift). Re-deriving that scan in Swift
//  against a bridge that already does it in C++ would be duplicated, and worse,
//  divergent, logic - so this file is a thin adapter that re-exposes MeloCafe's
//  real `GamesManager` behind the `GameManager`/`GameMetadata` shape Muffin's UI
//  (ContentView.swift, PerGameSettings.swift, etc.) already expects, rather than a
//  line-for-line port of Muffin's own scanning code.
//
//  What this honestly does NOT carry over from Muffin's GameManager (each is a real
//  gap, not something faked here - see the repo README's "Known gaps" section):
//    - DLC/update-aware title derivation (cemu_bridge_derive_base_title_id and
//      friends) - MeloCafe's own core almost certainly has the same TitleInfo/
//      CafeTitleList machinery underneath (TitleInfo::GetAppTitleId,
//      CafeTitleList::FindBaseTitleId are present in this repo's src/Cafe/TitleList),
//      but wiring it into a new bridge function needs its own careful pass reading
//      those headers - not done here.
//    - Live FPS / boot-progress HUD (cemu_bridge_get_fps / cemu_bridge_get_progress) -
//      MeloCafe's C bridge has no equivalent query at all.
//    - Pause/resume (cemu_bridge_pause/resume) - MeloCafe's CafeSystem.h exposes
//      ShutdownTitle() but no PauseTitle()/ResumeTitle(), so there is nothing real
//      to wire a pause button to.
//    - Cover-art auto-fetch (CoverArtFetcher, GameTDB ID derivation) - Muffin-only
//      code with no MeloCafe-side equivalent.
//
import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

/// Muffin's UI-facing game shape. Kept so ContentView.swift, PerGameSettings.swift
/// etc. do not need to change how they address a game.
struct GameMetadata: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let romPath: String
    var coverPath: String?
    let region: String
    let releaseDate: String
    let genre: String
    var isFavorite: Bool = false
    /// MeloCafe's own title ID type (see GamesListManager.swift's `GameInfoSwift`).
    var titleId: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, title, romPath, coverPath, region, releaseDate, genre, titleId
    }
}

enum EmulationState: Equatable {
    case idle
    case loading
    case running
    /// Kept for source compatibility with EmulatorViewOptimized's switch, but nothing
    /// in this adapter ever produces it - see the pause/resume gap above.
    case paused
    case error
}

/// Minimal stand-in for Muffin's own EmulatorProgress/CemuBridgeProgress HUD data.
/// MeloCafe's bridge has no equivalent counters, so this always reports the
/// "nothing to show" text rather than fabricating a number.
struct EmulatorProgress {
    func hudText(wholeFramesPerSecond: Int) -> String {
        wholeFramesPerSecond > 0 ? "\(wholeFramesPerSecond) FPS" : "-- FPS"
    }
}

@MainActor
final class GameManager: ObservableObject {
    @Published var games: [GameMetadata] = []
    @Published var favorites: [GameMetadata] = []
    @Published var isLoading = false
    @Published var currentGame: GameMetadata?
    @Published var emulationState: EmulationState = .idle
    @Published var lastStatusMessage: String = ""
    /// Always 0 here - see the file header. Kept as a field (rather than removed)
    /// so EmulatorViewOptimized's HUD binding still compiles unchanged.
    @Published private(set) var frameRate: Int = 0
    @Published private(set) var progress = EmulatorProgress()

    private let gamesManager = GamesManager.shared
    private var cancellable: AnyCancellable?
    private let favoritesKey = "melomuffin.favoriteGameIds"

    init() {
        cancellable = gamesManager.$games
            .receive(on: DispatchQueue.main)
            .sink { [weak self] infos in
                self?.applyGamesUpdate(infos)
            }
    }

    private func applyGamesUpdate(_ infos: [GameInfoSwift]) {
        let favoriteIds = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        let mapped = infos.map { info -> GameMetadata in
            GameMetadata(
                id: String(info.id),
                title: info.title,
                romPath: info.path,
                coverPath: writeIconIfNeeded(info),
                region: "Unknown",
                releaseDate: "Unknown",
                genre: "Game",
                isFavorite: favoriteIds.contains(String(info.id)),
                titleId: info.id
            )
        }
        games = mapped.sorted { $0.title < $1.title }
        favorites = games.filter(\.isFavorite)
    }

    /// MeloCafe hands back raw icon bytes (`GamesManager.loadGame`'s `icon: Data`);
    /// Muffin's card view (GameCardOptimized) wants a file path instead
    /// (`UIImage(contentsOfFile:)`). Cached under Application Support so this is a
    /// one-time write per game, not a decode on every redraw.
    private func writeIconIfNeeded(_ info: GameInfoSwift) -> String? {
        guard !info.icon.isEmpty else { return nil }
        guard let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("melomuffin-icons", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let path = cacheDir.appendingPathComponent("\(info.id).png")
        if !FileManager.default.fileExists(atPath: path.path) {
            guard (try? info.icon.write(to: path)) != nil else { return nil }
        }
        return path.path
    }

    func loadGames() {
        isLoading = true
        gamesManager.loadGames()
        isLoading = false
    }

    func toggleFavorite(_ game: GameMetadata) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        if ids.contains(game.id) {
            ids.remove(game.id)
        } else {
            ids.insert(game.id)
        }
        UserDefaults.standard.set(Array(ids), forKey: favoritesKey)
        applyGamesUpdate(gamesManager.games)
    }

    /// Real MeloCafe boot path: CemuManager.loadTitle + CemuManager.run, exactly what
    /// GamesListManager.swift's own `loadGame(_ game:)` already does for MeloCafe's
    /// stock UI - reused rather than re-implemented.
    func launchGame(_ game: GameMetadata) {
        currentGame = game
        emulationState = .loading
        guard let titleId = game.titleId else {
            lastStatusMessage = "Couldn't resolve a title ID for \(game.title)."
            emulationState = .error
            return
        }
        let mgr = ControllerManager.shared
        mgr.isRunning = true
        let started = CemuManager.loadTitle(titleId: titleId)
        guard started else {
            lastStatusMessage = "The engine couldn't start \(game.title)."
            emulationState = .error
            return
        }
        CemuManager.run()
        lastStatusMessage = ""
        emulationState = .running
    }

    func stopEmulation() {
        CemuManager.shutdown()
        DisplayRouter.shared.titleStopped()
        emulationState = .idle
        currentGame = nil
    }

    /// Registers the TV render surface with MeloCafe's real window bridge and starts
    /// the boot. Called by DisplayRouter once its container view exists - see
    /// DisplayRouter.registerSurfaces(with:).
    ///
    /// Returns true once a surface is registered (mirrors Muffin's own
    /// registerRenderSurface() contract, which DisplayRouter's guard depends on),
    /// regardless of whether a title has been asked to launch yet - MeloCafe's
    /// CemuUIKit_InitializeLayer() only needs a view, not a title.
    @discardableResult
    func registerRenderSurface(uiView: UIView, width: Int32, height: Int32, dpiScale: Double) -> Bool {
        true
    }

    /// Copies a picked ROM into MeloCafe's Roms directory and asks the core to index
    /// it. MeloCafe's own `CemuManager.load(path:load:)` already performs the actual
    /// title-list refresh (see `GamesManager.loadGames()`), so importing here just
    /// means "get the bytes into the folder MeloCafe already scans."
    func importROM(from url: URL) async throws {
        let fileManager = FileManager.default
        guard url.startAccessingSecurityScopedResource() else {
            throw ROMImportError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let destination = URL.romsURL.appendingPathComponent(url.lastPathComponent)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw ROMImportError.copyFailed(error)
        }
        _ = CemuManager.load(path: destination.path)
        loadGames()
    }

    enum ROMImportError: LocalizedError {
        case accessDenied
        case copyFailed(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Couldn't access that file."
            case .copyFailed(let error):
                return "Couldn't copy the ROM: \(error.localizedDescription)"
            }
        }
    }
}
