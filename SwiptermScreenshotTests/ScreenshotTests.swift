import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

final class ScreenshotTests: XCTestCase {
    private static let locales = [
        "en": "en_US",
        "fa": "fa_IR",
        "ru": "ru_RU",
        "zh-Hans": "zh_CN",
        "zh-Hant": "zh_TW",
    ]

    private enum Screen: String, CaseIterable {
        case setup
        case terminal

        var attachmentName: String {
            switch self {
            case .setup: "01-Setup"
            case .terminal: "02-Terminal"
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStoreScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        let languages = (environment["SCREENSHOT_LANGUAGES"] ?? "en,fa,ru,zh-Hans,zh-Hant")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertFalse(languages.isEmpty, "SCREENSHOT_LANGUAGES must contain a supported language")

        let orientation: UIDeviceOrientation
        switch environment["SCREENSHOT_ORIENTATION"] ?? "portrait" {
        case "portrait": orientation = .portrait
        case "landscapeLeft": orientation = .landscapeLeft
        case let name:
            XCTFail("Unsupported screenshot orientation: \(name)")
            return
        }
        let expectedWidth = try expectedDimension("SCREENSHOT_WIDTH", in: environment)
        let expectedHeight = try expectedDimension("SCREENSHOT_HEIGHT", in: environment)
        XCUIDevice.shared.orientation = orientation

        for language in languages {
            let locale = try XCTUnwrap(Self.locales[language], "Unsupported screenshot language: \(language)")
            for screen in Screen.allCases {
                let app = XCUIApplication()
                app.launchArguments = [
                    "--store-screenshot", screen.rawValue,
                    "-AppleLanguages", "(\(language))",
                    "-AppleLocale", locale,
                ]
                app.launch()
                defer { app.terminate() }

                let identifier = "store-screenshot-\(screen.rawValue)"
                let landmark = switch screen {
                case .setup: app.textFields[identifier].firstMatch
                case .terminal: app.descendants(matching: .any)[identifier].firstMatch
                }
                XCTAssertTrue(landmark.waitForExistence(timeout: 15), "\(language) \(identifier) did not appear")

                let image = screenshot(of: app)
                let capturedWidth = Int((image.size.width * image.scale).rounded())
                let capturedHeight = Int((image.size.height * image.scale).rounded())
                // XCTest omits the leftmost column and bottom row of the iPhone Duo inner display.
                let extendEdges = expectedWidth == 2007 && expectedHeight == 2853
                    && capturedWidth == 2006 && capturedHeight == 2852
                let width = capturedWidth + (extendEdges ? 1 : 0)
                let height = capturedHeight + (extendEdges ? 1 : 0)
                let name = "\(language)__\(screen.attachmentName)"
                XCTAssertEqual(width > height, orientation.isLandscape, "\(name) is \(width) × \(height)")
                if let expectedWidth {
                    XCTAssertEqual(width, expectedWidth, "\(name) width")
                }
                if let expectedHeight {
                    XCTAssertEqual(height, expectedHeight, "\(name) height")
                }

                let attachment = try XCTAttachment(
                    data: opaquePNG(image, width: width, height: height, extendEdges: extendEdges),
                    uniformTypeIdentifier: UTType.png.identifier
                )
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func expectedDimension(_ name: String, in environment: [String: String]) throws -> Int? {
        guard let value = environment[name] else { return nil }
        let dimension = try XCTUnwrap(Int(value), "\(name) must be a positive integer")
        XCTAssertGreaterThan(dimension, 0, "\(name) must be a positive integer")
        return dimension
    }

    @MainActor
    private func screenshot(of app: XCUIApplication) -> UIImage {
        let window = app.windows.firstMatch.frame.size
        // The main screen refers to iPhone Duo's outer display even when its inner display is active.
        return XCUIScreen.screens.lazy.map { $0.screenshot().image }.first { image in
            abs(image.size.width - window.width) < 1 && abs(image.size.height - window.height) < 1
        } ?? XCUIScreen.main.screenshot().image
    }

    @MainActor
    private func opaquePNG(_ image: UIImage, width: Int, height: Int, extendEdges: Bool) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: image.scale, y: -image.scale)
        UIGraphicsPushContext(context)
        if extendEdges {
            let pixel = 1 / image.scale
            image.draw(at: CGPoint(x: 0, y: pixel))
            image.draw(at: CGPoint(x: pixel, y: pixel))
            image.draw(at: .zero)
            image.draw(at: CGPoint(x: pixel, y: 0))
        } else {
            image.draw(at: .zero)
        }
        UIGraphicsPopContext()

        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
