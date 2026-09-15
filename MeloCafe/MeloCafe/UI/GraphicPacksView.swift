//
//  GraphicPacksView.swift
//  melomuffin
//
//  Adapted from cemu-ios-muffin's src/ios/App/GraphicPacksView.swift.
//
//  MELOMUFFIN ADAPTATION NOTE: Muffin's version talked to its own bridge
//  (cemu_bridge_graphic_packs_refresh/_list/_pack_set_enabled - a text-record wire
//  format over a static buffer). MeloCafe already has a real, working graphic-pack
//  surface of its own - `GraphicPackManager` (src/config/GraphicPackWrapper.h/.mm,
//  wrapping the same GraphicPack2 (Cafe/GraphicPack/) engine feature both projects
//  ultimately sit on) - so this view is rewritten against that instead of
//  reimplementing Muffin's own wire protocol against a bridge that does not exist
//  here.
//
import SwiftUI

struct GraphicPacksView: View {
    @State private var packs: [ObjCGraphicPackEntry] = []

    var body: some View {
        List {
            if packs.isEmpty {
                Section {
                    Text("No graphic packs found. Add them to \(GraphicPackManager.shared().graphicPacksBasePath()) - each pack is a folder with its own rules.txt inside, the same layout desktop Cemu uses.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(packs, id: \.normalizedPath) { pack in
                        Toggle(isOn: Binding(
                            get: { pack.enabled },
                            set: { newValue in
                                GraphicPackManager.shared().setEnabled(newValue, forPack: pack.normalizedPath)
                                reload()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name)
                                    .font(.system(size: 15, weight: .semibold))
                                if !pack.packDescription.isEmpty {
                                    Text(pack.packDescription)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                if !pack.titleIds.isEmpty {
                                    Text(pack.titleIds.count == 1 ? "1 game" : "\(pack.titleIds.count) games")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("This device has no mesh shader support, so packs that rely on geometry shaders or post-processing (RECTS) draws won't render correctly yet. Everything else works normally.")
                }
            }
        }
        .navigationTitle("Graphic Packs")
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        GraphicPackManager.shared().refreshPacks()
        packs = GraphicPackManager.shared().allPacks()
    }
}
