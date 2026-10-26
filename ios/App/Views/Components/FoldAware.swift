import SwiftUI

/// Insets that keep a custom component clear of iPhone Duo reserved regions.
nonisolated struct ReservedInsets: Equatable, Sendable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    /// Shift the component wholly onto the wider side of a fold that crosses it, and
    /// away from occluding regions such as the active inner camera.
    init(_ proxy: GeometryProxy) {
        let bounds = CGRect(origin: .zero, size: proxy.size)
        for fold in proxy.reservedRegions(kind: .division) where fold.isActive {
            let frame = fold.frame
            guard frame.minX > bounds.minX, frame.maxX < bounds.maxX, frame.intersects(bounds) else { continue }
            let leadingSide = frame.minX - bounds.minX
            let trailingSide = bounds.maxX - frame.maxX
            if leadingSide >= trailingSide {
                trailing = max(trailing, bounds.maxX - frame.minX)
            } else {
                leading = max(leading, frame.maxX - bounds.minX)
            }
        }
        for region in proxy.reservedRegions(kind: .occlusion) where region.isActive && region.frame.intersects(bounds) {
            leading = max(leading, region.margins.leading)
            trailing = max(trailing, region.margins.trailing)
            top = max(top, region.margins.top)
            bottom = max(bottom, region.margins.bottom)
        }
    }

    init() {}
}

/// Hosts a floating, full-width custom component (banners, the composer) so that on a
/// partially folded iPhone Duo it sits on one side of the fold instead of across it.
/// System components adapt on their own; this covers the ones the app draws itself.
struct FoldAware<Content: View>: View {
    private let content: Content
    @State private var insets = ReservedInsets()

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .padding(.top, insets.top)
            .padding(.bottom, insets.bottom)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: ReservedInsets.self, of: ReservedInsets.init) { value in
                withAnimation(.smooth) { insets = value }
            }
    }
}
