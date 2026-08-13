import CoreGraphics

/// Which arrangement the three cards take at a given width.
///
/// `UIRequiresFullScreen` is deprecated as of iOS 26 and will be ignored, so iPadOS can hand
/// this app a window of nearly any width — Split View, Slide Over, Stage Manager. Guided
/// Access keeps the kiosk full screen in normal use; this is what happens when it isn't on.
///
/// Kept as a plain value rather than inline `if`s in the view so the breakpoints can be
/// tested without rendering anything.
nonisolated enum CardLayout: Equatable {
    /// Lights | Heat | Jets — the intended kiosk layout.
    case threeColumn
    /// Lights | (Heat over Jets) — roughly a half-screen Split View.
    case twoColumn
    /// One scrolling column — Slide Over and other narrow windows.
    case stacked

    /// Full-screen landscape on every current iPad clears `threeColumn` comfortably; the
    /// narrowest is ~1024pt.
    static func forWidth(_ width: CGFloat) -> CardLayout {
        if width >= 1000 { return .threeColumn }
        if width >= 640 { return .twoColumn }
        return .stacked
    }
}
