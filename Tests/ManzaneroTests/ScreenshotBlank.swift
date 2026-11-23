import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Manzanero

/// A black screenshot says so, with the cause it can narrow down to.
struct ScreenshotBlankTests {
    /// A PNG of `width` × `height`, black but for one bright rectangle.
    private static func png(_ name: String, width: Int = 1920, height: Int = 1080, bright: CGRect? = nil) throws -> URL {
        let directory = URL(fileURLWithPath: "tmp/screenshot-blank-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.01, green: 0.01, blue: 0.01, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let bright {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(bright)
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func annotated(_ power: String, image: URL?) throws -> [String: Any] {
        let receipt = try JSONSerialization.data(withJSONObject: ["result": ["path": "a.png"], "displayPower": power])
        return try #require(JSONSerialization.jsonObject(with: ScreenshotBlank.annotate(receipt, image: image)) as? [String: Any])
    }

    @Test func anEntirelyBlackPictureIsBlankAndAnyBrightPartIsNot() throws {
        let black = try Self.png("black"), text = try Self.png("text", bright: CGRect(x: 100, y: 900, width: 300, height: 20))
        defer { try? FileManager.default.removeItem(at: black); try? FileManager.default.removeItem(at: text) }
        #expect(ScreenshotBlank.isBlank(black) == true)
        // A line of small bright text, such as a caption, is not blank.
        #expect(ScreenshotBlank.isBlank(text) == false)
        #expect(ScreenshotBlank.isBlank(URL(fileURLWithPath: "tmp/screenshot-blank-tests/missing.png")) == nil)
    }

    @Test func theNoteNamesProtectedVideoOnAnAppleTVAndDefersToTheDisplayOffNote() throws {
        let black = try Self.png("black"), picture = try Self.png("picture", bright: CGRect(x: 0, y: 0, width: 1920, height: 540))
        defer { try? FileManager.default.removeItem(at: black); try? FileManager.default.removeItem(at: picture) }
        let television = try Self.annotated(DeviceUIReadiness.externalPower, image: black)
        #expect(television["blankImage"] as? Bool == true && television["blankNote"] as? String == ScreenshotBlank.externalNote)
        let phone = try Self.annotated("on", image: black)
        #expect(phone["blankImage"] as? Bool == true && phone["blankNote"] as? String == ScreenshotBlank.displayNote)
        // A display reported off has its own note; no second one.
        let off = try Self.annotated("off", image: black)
        #expect(off["blankImage"] as? Bool == true && off["blankNote"] == nil)
        let drawn = try Self.annotated(DeviceUIReadiness.externalPower, image: picture)
        #expect(drawn["blankImage"] as? Bool == false && drawn["blankNote"] == nil)
        // No image to read: the receipt is left as it was.
        let unread = try Self.annotated("on", image: nil)
        #expect(unread["blankImage"] == nil)
    }

    private static func tree(_ nodes: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["nodes": nodes]) }

    /// The markers read from Apple's player on a tvOS simulator.
    @Test func applesPlayerIsToldByItsClassesOrItsTransportBar() throws {
        let playing = try Self.tree([["id": "n1", "nativeAttributes": ["5003": "UIWindow"]],
                                     ["id": "n2", "nativeAttributes": ["5003": "__AVPlayerLayerView"]]])
        let paused = try Self.tree([["id": "n1", "identifier": "Media Controls", "value": "17 seconds elapsed"]])
        let home = try Self.tree([["id": "n1", "label": "Probe TV", "identifier": "AppCell", "nativeAttributes": ["5003": "UIView"]]])
        #expect(ScreenshotBlank.showsPlayer(playing) == true && ScreenshotBlank.showsPlayer(paused) == true)
        #expect(ScreenshotBlank.showsPlayer(home) == false && ScreenshotBlank.showsPlayer(Data("{}".utf8)) == nil)
    }

    @Test func aBlankAppleTVPictureReadsOneTreeAndNothingElseDoes() async throws {
        func receipt(_ power: String, blank: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["displayPower": power, "blankImage": blank, "blankNote": "x"])
        }
        func decoded(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        let player = try Self.tree([["id": "n1", "nativeAttributes": ["5003": "_AVPlayerViewControllerContainerView"]]])
        let withPlayer = try decoded(await ScreenshotBlank.annotatePlayer(try receipt(DeviceUIReadiness.externalPower, blank: true)) { player })
        #expect(withPlayer["playerOnScreen"] as? Bool == true && withPlayer["blankNote"] as? String == ScreenshotBlank.playerNote)
        let without = try decoded(await ScreenshotBlank.annotatePlayer(try receipt(DeviceUIReadiness.externalPower, blank: true)) {
            try Self.tree([["id": "n1", "label": "Settings"]])
        })
        #expect(without["playerOnScreen"] as? Bool == false && without["blankNote"] as? String == "x")
        let refused = try decoded(await ScreenshotBlank.annotatePlayer(try receipt(DeviceUIReadiness.externalPower, blank: true)) {
            throw CommandFailure(.unsupportedOperation, "An Apple TV's accessibility needs the tool's own tunnel.", inputSent: .none)
        })
        #expect(refused["playerOnScreen"] == nil && (refused["playerCheckUnavailable"] as? String)?.contains("own tunnel") == true)
        // A phone's black picture, or a picture that is not black: no tree.
        for (power, blank) in [("on", true), (DeviceUIReadiness.externalPower, false)] {
            let original = try receipt(power, blank: blank)
            #expect(await ScreenshotBlank.annotatePlayer(original) { Issue.record("Tree read"); return Data() } == original)
        }
    }

    @Test func theDestinationIsReadFromThePlannedArguments() {
        #expect(ScreenshotBlank.destination(["devicectl", "device", "capture", "screenshot", "--destination", "tmp/a.png", "--device", "x"])?.path.hasSuffix("tmp/a.png") == true)
        #expect(ScreenshotBlank.destination(["devicectl", "--destination"]) == nil)
    }
}
