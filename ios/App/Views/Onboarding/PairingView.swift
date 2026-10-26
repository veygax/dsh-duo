import SwiftUI
import VisionKit

/// First run: install the companion plugin on the Mac, then scan its QR code.
struct PairingView: View {
    @Environment(HostStore.self) private var store
    @State private var scanning = false
    @State private var typing = false
    @State private var typedLink = ""
    @State private var invalid = false

    var body: some View {
        // Hero and steps form one arrangement: side by side on the open inner display
        // (each on its own side of the fold), stacked on the outer display.
        ArrangementView {
            hero
        } secondary: {
            steps
        }
        .arrangementViewStyle(.automatic)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                pair(code)
            }
            .ignoresSafeArea()
        }
        .alert("Paste Pairing Link", isPresented: $typing) {
            TextField("dshduo://pair?…", text: $typedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Pair") { pair(typedLink) }
            Button("Cancel", role: .cancel) { Haptics.tap() }
        } message: {
            Text("Run `dsh-duo pair` on your Mac to show the link.")
        }
        .alert("That isn't a pairing code", isPresented: $invalid) {
            Button("OK", role: .cancel) { Haptics.tap() }
        } message: {
            Text("Scan the QR code that dsh prints after the duo-remote plugin starts, or run `dsh-duo pair`.")
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Color.accentColor.gradient).frame(width: 104, height: 104)
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            Text("DSH Duo")
                .font(.largeTitle.bold())
            Text("Run DeepSeek Harness on your Mac. Steer it from anywhere.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var steps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StepRow(number: 1, title: "Install the companion plugin",
                        detail: "On your Mac:", code: "dsh plugin add dsh-plugin-duo-remote")
                StepRow(number: 2, title: "Start dsh",
                        detail: "A pairing QR code appears in the terminal. Lost it? Run:", code: "dsh-duo pair")
                StepRow(number: 3, title: "Scan it with this iPhone",
                        detail: "No VPN or port forwarding. Everything is end-to-end encrypted.", code: nil)

                VStack(spacing: 12) {
                    Button(action: tap { startScan() }) {
                        Label("Scan Pairing QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    PasteButton(payloadType: String.self) { strings in
                        Haptics.tap()
                        if let link = strings.first { pair(link) }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)

                    Button("Type the Link Instead", action: tap { typing = true })
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func startScan() {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            scanning = true
        } else {
            typing = true
        }
    }

    private func pair(_ link: String) {
        if !store.pair(link: link) {
            Haptics.error()
            invalid = true
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    let code: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.15), in: .circle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if let code {
                    HStack {
                        Text(code).font(.footnote.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy", systemImage: "doc.on.doc", action: tap { UIPasteboard.general.string = code })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.background, in: .rect(cornerRadius: 10))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
