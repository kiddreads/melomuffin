//
//  Binding+Map.swift
//  MeloCafe
//
//  SwiftUI's Binding has no built-in transform between value types; ConfigManager's
//  cpuMode/precompiledShaders bindings adapt an ObjC-bridged wrapper type to a plain
//  Swift one and need one. Ported alongside the UI swap - see ConfigManager.swift's
//  cpuModeBinding.map/precompiledShadersBinding.map for the two call sites.
//

import SwiftUI

extension Binding {
    func map<T>(get: @escaping (Value) -> T, set: @escaping (T) -> Value) -> Binding<T> {
        Binding<T> {
            get(self.wrappedValue)
        } set: { newValue in
            self.wrappedValue = set(newValue)
        }
    }
}
