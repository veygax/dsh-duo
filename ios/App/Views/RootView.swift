import SwiftUI

struct RootView: View {
    @Environment(HostStore.self) private var store

    var body: some View {
        Group {
            if store.pairing == nil {
                PairingView()
                    .transition(.opacity)
            } else {
                MainSplitView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: store.pairing == nil)
        .overlay(alignment: .top) { BannerHost() }
        .tint(.accentColor)
    }
}

/// Sidebar of Sessions beside the open Session. On iPhone Duo this expands
/// across the inner display and collapses to one column on the outer display.
struct MainSplitView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var windowSize = CGSize.zero
    @State private var layoutEpoch = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            if let sessionId = store.selectedSessionId {
                SessionView(sessionId: sessionId)
                    .id(sessionId)
                    // Only the open inner display has room beside the chat once the sidebar is hidden.
                    .environment(\.sidebarHidden, sizeClass == .regular && columns == .detailOnly)
            } else {
                NoSessionView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.selectedSessionId) { _, _ in Haptics.selection() }
        .environment(\.layoutEpoch, layoutEpoch)
        .onGeometryChange(for: CGSize.self, of: \.size) { windowSize = $0 }
        .task(id: windowSize) {
            // Folding or unfolding moves the app to another display. Once the new size has settled,
            // transcripts lay themselves out again (see TranscriptView).
            guard windowSize != .zero else { return }
            try? await Task.sleep(for: .milliseconds(250))
            layoutEpoch += 1
        }
    }
}

extension EnvironmentValues {
    /// The sidebar is collapsed on the open inner display, leaving the session the whole width.
    @Entry var sidebarHidden = false
    /// Bumped after the window changes size (fold, unfold, rotation).
    @Entry var layoutEpoch = 0
}

struct NoSessionView: View {
    @Environment(HostStore.self) private var store
    @State private var creating = false

    var body: some View {
        ContentUnavailableView {
            Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Pick a session from the list, or start a new one on \(store.hostName).")
        } actions: {
            Button("New Session", systemImage: "square.and.pencil", action: tap { creating = true })
                .buttonStyle(.glassProminent)
                .disabled(store.connection != .online)
        }
        .sheet(isPresented: $creating) { NewSessionSheet() }
    }
}

/// Transient banner for command output, errors, and events from other Sessions.
struct BannerHost: View {
    @Environment(HostStore.self) private var store

    var body: some View {
        if let banner = store.banner {
            FoldAware { BannerCard(banner: banner) }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(banner.isError ? 6 : 4))
                    withAnimation(.snappy) { if store.banner?.id == banner.id { store.banner = nil } }
                }
                .onAppear { banner.isError ? Haptics.error() : Haptics.tap() }
        }
    }
}

private struct BannerCard: View {
    @Environment(HostStore.self) private var store
    let banner: HostStore.Banner

    var body: some View {
        Button {
            Haptics.tap()
            if let sessionId = banner.sessionId { store.selectedSessionId = sessionId }
            withAnimation(.snappy) { store.banner = nil }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.headline)
                    if let message = banner.message {
                        Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: 520)
            .glassEffect(.regular.interactive(), in: .rect(corners: .concentric(minimum: 22), isUniform: true))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Dismisses the message")
    }
}
