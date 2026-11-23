import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct OpenURLPromptModifier: ViewModifier {
    private let system = LinuxSystem.shared

    @Environment(\.openURL) private var openURL
    @State private var qrCodeURL: URL?
    @State private var isShowingQRCode = false

    func body(content: Content) -> some View {
        content
            .alert("Open URL", isPresented: Binding {
                system.pendingOpenURL != nil
            } set: { _ in
                system.pendingOpenURL = nil
            }, presenting: system.pendingOpenURL) { url in
                Button("Open in Safari") {
                    openURL(url)
                }
                .keyboardShortcut(.defaultAction)
                Button("Copy") {
                    UIPasteboard.general.string = url.absoluteString
                }
                Button("Show QR Code") {
                    qrCodeURL = url
                    isShowingQRCode = true
                }
                Button("Cancel", role: .cancel) {}
            } message: { url in
                Text(verbatim: Self.message(for: url))
            }
            .sheet(isPresented: $isShowingQRCode) {
                if let qrCodeURL {
                    URLQRCodeSheet(url: qrCodeURL)
                }
            }
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

private struct URLQRCodeSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let qrCode {
                    Image(uiImage: qrCode)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(.white, in: .rect(cornerRadius: 16))
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var qrCode: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let image = filter.outputImage,
              let cgImage = CIContext().createCGImage(image, from: image.extent)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
