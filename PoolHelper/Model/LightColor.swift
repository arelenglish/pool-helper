import SwiftUI

/// The color table for the pool light.
///
/// The controller reports `aux_1` as `type: 2, subtype: 4`. Community API references generally
/// map subtype 4 to Pentair IntelliBrite and subtype 1 to Jandy Color LED — but this fixture is
/// a **Jandy Color LED**, and these names were confirmed on 2026-08-13 by cycling the colors
/// and watching the water. So `subtype` is not a reliable way to identify the lamp.
///
/// Adapting this to another pool means checking the fixture rather than trusting the subtype.
/// Replace `all` below with the right table: the indices are what the API consumes, and
/// nothing else in the codebase depends on the names or swatches.
nonisolated struct LightColor: Identifiable, Equatable, Sendable {
    let id: Int          // the index sent as `light=` in set_light
    let name: String
    let swatch: [Color]  // one color = solid, several = an animated show
    var isShow: Bool { swatch.count > 1 }

    static let all: [LightColor] = [
        LightColor(id: 1,  name: "Alpine White",     swatch: [Color(white: 0.97)]),
        LightColor(id: 2,  name: "Sky Blue",         swatch: [Color(red: 0.45, green: 0.75, blue: 0.98)]),
        LightColor(id: 3,  name: "Cobalt Blue",      swatch: [Color(red: 0.11, green: 0.28, blue: 0.87)]),
        LightColor(id: 4,  name: "Caribbean Blue",   swatch: [Color(red: 0.15, green: 0.72, blue: 0.79)]),
        LightColor(id: 5,  name: "Spring Green",     swatch: [Color(red: 0.44, green: 0.89, blue: 0.42)]),
        LightColor(id: 6,  name: "Emerald Green",    swatch: [Color(red: 0.06, green: 0.65, blue: 0.35)]),
        LightColor(id: 7,  name: "Emerald Rose",     swatch: [Color(red: 0.06, green: 0.65, blue: 0.35),
                                                              Color(red: 0.93, green: 0.35, blue: 0.55)]),
        LightColor(id: 8,  name: "Magenta",          swatch: [Color(red: 0.88, green: 0.19, blue: 0.66)]),
        LightColor(id: 9,  name: "Violet",           swatch: [Color(red: 0.56, green: 0.27, blue: 0.90)]),
        LightColor(id: 10, name: "Color Splash",     swatch: [Color(red: 0.20, green: 0.55, blue: 0.95),
                                                              Color(red: 0.44, green: 0.89, blue: 0.42),
                                                              Color(red: 0.88, green: 0.19, blue: 0.66)]),
        LightColor(id: 11, name: "Fast Splash",      swatch: [Color(red: 0.95, green: 0.75, blue: 0.20),
                                                              Color(red: 0.20, green: 0.85, blue: 0.85),
                                                              Color(red: 0.75, green: 0.25, blue: 0.95)]),
        LightColor(id: 12, name: "USA!!!",           swatch: [Color(red: 0.85, green: 0.16, blue: 0.20),
                                                              Color(white: 0.97),
                                                              Color(red: 0.13, green: 0.25, blue: 0.72)]),
        LightColor(id: 13, name: "Fat Tuesday",      swatch: [Color(red: 0.55, green: 0.20, blue: 0.75),
                                                              Color(red: 0.95, green: 0.80, blue: 0.15),
                                                              Color(red: 0.10, green: 0.65, blue: 0.35)]),
        LightColor(id: 14, name: "Disco Tech",       swatch: [Color(red: 0.95, green: 0.25, blue: 0.35),
                                                              Color(red: 0.25, green: 0.75, blue: 0.95),
                                                              Color(red: 0.95, green: 0.85, blue: 0.25),
                                                              Color(red: 0.55, green: 0.30, blue: 0.90)]),
    ]

    static func named(_ index: Int?) -> LightColor? {
        guard let index else { return nil }
        return all.first { $0.id == index }
    }
}
