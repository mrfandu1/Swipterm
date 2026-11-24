import CoreImage.CIFilterBuiltins
import SafariServices
import SwiftUI
import UIKit

struct OpenURLPromptModifier: ViewModifier {
    private let system = LinuxSystem.shared

    @Environment(\.openURL) private var openURL
    @State private var webURL: URL?
    @State private var qrCodeImage: UIImage?
    @State private var isShowingQRCode = false

    func body(content: Content) -> some View {
        content
            .alert("Open URL", isPresented: Binding {
                system.pendingOpenURL != nil && !isShowingQRCode
            } set: { isPresented in
                if !isPresented, !isShowingQRCode {
                    system.pendingOpenURL = nil
                }
            }, presenting: system.pendingOpenURL) { url in
                let isWebURL = url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
                Button("Open") {
                    if isWebURL {
                        webURL = url
                    } else {
                        openURL(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
                if isWebURL {
                    Button("Open in Safari") {
                        openURL(url)
                    }
                }
                Button("Copy URL") {
                    UIPasteboard.general.string = url.absoluteString
                }
                Button("Show QR Code") {
                    system.pendingOpenURL = url
                    qrCodeImage = Self.qrCode(for: url)
                    isShowingQRCode = true
                }
                Button("Cancel", role: .cancel) {}
            } message: { url in
                Text(verbatim: Self.message(for: url))
            }
            .sheet(isPresented: Binding {
                webURL != nil
            } set: { isPresented in
                if !isPresented {
                    webURL = nil
                }
            }) {
                if let webURL {
                    SafariView(url: webURL)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                ZStack {
                    if isShowingQRCode, let qrCodeImage {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isShowingQRCode = false
                            }
                            .transition(.opacity)

                        URLQRCodePopup(qrCode: qrCodeImage) {
                            isShowingQRCode = false
                        }
                        .padding(20)
                        .transition(.scale(scale: 1.06).combined(with: .opacity))
                    }
                }
                .allowsHitTesting(isShowingQRCode)
                .animation(.easeOut(duration: 0.2), value: isShowingQRCode)
            }
            .onChange(of: system.pendingOpenURL) { _, url in
                if url == nil {
                    isShowingQRCode = false
                }
            }
    }

    private static func qrCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let image = filter.outputImage,
              let cgImage = CIContext().createCGImage(image, from: image.extent)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// UIAlertController ignores lineLimit in the message, and lays it out at least 238 points wide
    /// (a 270-point alert with 16-point insets) in a font no larger than subheadline.
    private static func message(for url: URL) -> String {
        let text = url.absoluteString
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        func fits(_ candidate: String) -> Bool {
            let bounds = (candidate as NSString).boundingRect(
                with: CGSize(width: 238, height: CGFloat.greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin,
                attributes: [.font: font],
                context: nil
            )
            return (bounds.height / font.lineHeight).rounded() <= 2
        }
        guard !fits(text) else { return text }
        var low = 0
        var high = text.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(text.prefix(middle) + "…") {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return text.prefix(low) + "…"
    }
}

private struct URLQRCodePopup: View {
    let qrCode: UIImage
    let onDismiss: () -> Void

    var body: some View {
        let content = VStack(spacing: 14) {
            Text("QR Code")
                .font(.headline)
            Image(uiImage: qrCode)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous))
        }
        .padding(.top, 20)
        .padding([.horizontal, .bottom], 16)
        .frame(maxWidth: 420)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            } else {
                content
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .onTapGesture {}
        .background {
            Button(action: onDismiss) {
                EmptyView()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
    }

    private var innerCornerRadius: CGFloat {
        if #available(iOS 26.0, *) {
            18
        } else {
            10
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
