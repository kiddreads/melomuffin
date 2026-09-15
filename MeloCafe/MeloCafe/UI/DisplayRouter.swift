//
//  DisplayRouter.swift
//  melomuffin
//
//  Adapted from cemu-ios-muffin's src/ios/App/DisplayRouter.swift.
//
//  MELOMUFFIN ADAPTATION NOTE:
//  Muffin's original router registered raw UIViews directly against its own bridge
//  (`cemu_bridge_register_render_surface` / `cemu_bridge_register_pad_render_surface`
//  / `cemu_bridge_resize_render_surface` / `cemu_bridge_has_pad_render_surface` /
//  `cemu_bridge_release_pad_render_surface`), none of which exist in MeloCafe.
//
//  MeloCafe's own window bridge (src/gui/uikit/WindowSystem.mm, declared in
//  Core/MeloCafe-Bridging-Header.h) is real and already does the same job, shaped
//  differently:
//    - it wants a `MetalView` (Core/RenderBridge/MetalView.swift) - MeloCafe's own
//      CAMetalLayer-backed UIView, which also forwards pad touches
//      (CemuUIKit_SetPadTouch) - not a bare UIView, and it resizes itself from its
//      own bounds/layoutSubviews rather than taking explicit width/height/scale.
//    - registration is CemuUIKit_SetMainView/SetPadView + CemuUIKit_InitializeLayer,
//      not one register call.
//    - releasing the pad surface is CemuUIKit_ShutdownLayer(false).
//    - "is a pad surface open" had no getter at all until this port added
//      CemuUIKit_IsPadOpen() (see WindowSystem.mm) - a thin wrapper over the
//      already-real WindowSystem::IsPadWindowOpen().
//
//  Muffin's own dual-screen/AirPlay placement logic (the actual point of this file)
//  is untouched below - only the calls at the bottom, into the bridge, are adapted.
//
import Foundation
#if os(iOS)
import UIKit

@MainActor
final class DisplayRouter {
    static let shared = DisplayRouter()

    enum Placement: Equatable {
        case deviceOnly
        case deviceMirrored
        case dualScreen
    }

    private(set) var placement: Placement = .deviceOnly

    /// MeloCafe's own MetalView, configured as the TV (main) surface. Using
    /// MeloCafe's real render-bridge view here (rather than a bare UIView, as
    /// Muffin's version did against its own bridge) is what lets
    /// CemuUIKit_UpdateMainWindowSize/SetPadTouch keep working unmodified.
    private var tvRenderViewStorage: MetalView?

    var tvRenderView: MetalView {
        if let existing = tvRenderViewStorage {
            return existing
        }
        let view = MetalView()
        view.configure(main: true)
        tvRenderViewStorage = view
        return view
    }

    private var padRenderView: MetalView?
    private weak var deviceContainer: UIView?
    private var externalWindow: UIWindow?
    private var observing = false
    private var tvSurfaceRegistered = false
    private var isReparentingTV = false
    private var lastDeviceContainerLayoutSize: CGSize?

    private init() {}

    // MARK: - Lifecycle

    func startObserving() {
        guard !observing else { return }
        observing = true

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification,
            UIScreen.modeDidChangeNotification,
            UIScene.didActivateNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let noteName = note.name
                Task { @MainActor in
                    DisplayRouter.shared.handleScreenChange(noteName)
                }
            }
        }

        log("display routing armed; \(describeScreens())")
    }

    func attach(deviceContainer container: UIView) {
        guard deviceContainer !== container else { return }
        deviceContainer = container
        applyPlacement(reason: "the emulator view mounted")
    }

    /// Registers the TV surface with MeloCafe's real window bridge. `gameManager` is
    /// accepted (and ignored beyond the guard) purely so MetalViewIOS's call site -
    /// carried over unchanged from Muffin - still compiles; MeloCafe's
    /// CemuUIKit_InitializeLayer() needs a view, not a game.
    func registerSurfaces(with gameManager: GameManager) {
        guard !tvSurfaceRegistered else { return }

        let geometry = tvGeometry()
        let view = tvRenderView
        view.updateDrawableSize(scale: geometry.scale)

        CemuUIKit_SetMainView(view)
        CemuUIKit_InitializeLayer(true)

        tvSurfaceRegistered = true
        applyPlacement(reason: "the TV surface was registered")
        log("routing the Wii U TV screen to \(placement == .dualScreen ? "the external display" : "this device") at \(Int(geometry.size.width))x\(Int(geometry.size.height)) points, \(geometry.scale)x scale (placement=\(placementName))")

        syncPadSurface()
    }

    func titleStopped() {
        if tvSurfaceRegistered {
            CemuUIKit_ShutdownLayer(true)
        }
        tvRenderViewStorage?.removeFromSuperview()
        tvRenderViewStorage = nil
        padRenderView?.removeFromSuperview()
        padRenderView = nil
        externalWindow?.isHidden = true
        externalWindow = nil
        tvSurfaceRegistered = false
        log("title stopped; render surfaces will be rebuilt on the next launch")
    }

    // MARK: - Placement

    private var placementName: String {
        switch placement {
        case .deviceOnly: return "deviceOnly"
        case .deviceMirrored: return "deviceMirrored"
        case .dualScreen: return "dualScreen"
        }
    }

    private func handleScreenChange(_ name: Notification.Name) {
        applyPlacement(reason: "\(name.rawValue); \(describeScreens())")
    }

    private func applyPlacement(reason: String) {
        let external = externalScreen()
        let scene = external.flatMap { externalWindowScene(for: $0) }

        let desired: Placement
        if external != nil && scene != nil {
            desired = .dualScreen
        } else if external != nil {
            desired = .deviceMirrored
        } else {
            desired = .deviceOnly
        }

        let changed = desired != placement
        placement = desired

        switch desired {
        case .dualScreen:
            if let external, let scene {
                placeTVOnExternalDisplay(screen: external, scene: scene)
            }
        case .deviceMirrored, .deviceOnly:
            placeTVOnDevice()
        }

        syncPadSurface()

        if changed || !tvSurfaceRegistered {
            log("display change (\(reason)) -> placement=\(placementName)")
        }
    }

    private func placeTVOnDevice() {
        guard let container = deviceContainer else { return }
        guard let tvRenderView = tvRenderViewStorage else { return }
        if tvRenderView.superview !== container {
            isReparentingTV = true
            tvRenderView.removeFromSuperview()
            tvRenderView.frame = container.bounds
            container.addSubview(tvRenderView)
            isReparentingTV = false
            resizeTVSurfaceIfRegistered()
        }
        if let externalWindow {
            externalWindow.isHidden = true
            self.externalWindow = nil
        }
    }

    private func placeTVOnExternalDisplay(screen: UIScreen, scene: UIWindowScene) {
        if externalWindow?.screen !== screen {
            externalWindow?.isHidden = true
            externalWindow = nil
        }
        if externalWindow == nil {
            let window = UIWindow(windowScene: scene)
            window.frame = screen.bounds
            window.backgroundColor = .black
            let root = UIViewController()
            root.view.backgroundColor = .black
            window.rootViewController = root
            window.isHidden = false
            externalWindow = window
        }
        guard let host = externalWindow?.rootViewController?.view else { return }
        guard let tvRenderView = tvRenderViewStorage else { return }
        if tvRenderView.superview !== host {
            isReparentingTV = true
            tvRenderView.removeFromSuperview()
            tvRenderView.frame = host.bounds
            host.addSubview(tvRenderView)
            isReparentingTV = false
            resizeTVSurfaceIfRegistered()
        }
    }

    func deviceContainerDidLayout(_ container: UIView) {
        guard container === deviceContainer else { return }
        guard !isReparentingTV else { return }
        let size = container.bounds.size
        if let lastSize = lastDeviceContainerLayoutSize, lastSize == size { return }
        lastDeviceContainerLayoutSize = size
        resizeTVSurfaceIfRegistered()
        resizePadSurfaceIfRegistered()
    }

    private func resizeTVSurfaceIfRegistered() {
        guard tvSurfaceRegistered, let view = tvRenderViewStorage else { return }
        view.updateDrawableSize()
    }

    private func resizePadSurfaceIfRegistered() {
        guard CemuUIKit_IsPadOpen(), let view = padRenderView else { return }
        view.updateDrawableSize()
    }

    /// Creates or drops the GamePad surface depending on placement, mirroring
    /// Muffin's own logic. Real bridge calls: CemuUIKit_SetPadView +
    /// CemuUIKit_InitializeLayer(false) to create, CemuUIKit_ShutdownLayer(false) to
    /// release.
    private func syncPadSurface() {
        guard tvSurfaceRegistered else { return }
        let wantPad = (placement == .dualScreen)
        let havePad = CemuUIKit_IsPadOpen()

        if wantPad, !havePad, let container = deviceContainer {
            let view = MetalView()
            view.frame = container.bounds
            view.configure(main: false)
            container.addSubview(view)
            padRenderView = view

            CemuUIKit_SetPadView(view)
            CemuUIKit_InitializeLayer(false)
        } else if !wantPad, havePad {
            CemuUIKit_ShutdownLayer(false)
            padRenderView?.isHidden = true
            padRenderView = nil
        }
    }

    // MARK: - Screen discovery

    private func externalScreen() -> UIScreen? {
        UIScreen.screens.first { $0 !== UIScreen.main }
    }

    private func externalWindowScene(for screen: UIScreen) -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.screen === screen }
    }

    private func tvGeometry() -> (size: CGSize, scale: Double) {
        if placement == .dualScreen, let window = externalWindow {
            return (window.bounds.size, window.screen.effectiveRenderScale)
        }
        let containerSize = deviceContainer?.bounds.size ?? .zero
        let size = containerSize == .zero ? UIScreen.main.bounds.size : containerSize
        let scale = (deviceContainer?.window?.screen ?? UIScreen.main).effectiveRenderScale
        return (size, scale)
    }

    private func describeScreens() -> String {
        let parts = UIScreen.screens.map { screen -> String in
            let role = screen === UIScreen.main ? "main" : (screen.mirrored != nil ? "external (mirroring this device)" : "external")
            return "\(role) \(Int(screen.bounds.width))x\(Int(screen.bounds.height))@\(screen.scale)x"
        }
        return "screens: [\(parts.joined(separator: ", "))]"
    }

    private func log(_ message: String) {
        NSLog("[melomuffin display] %@", message)
    }
}
#endif
