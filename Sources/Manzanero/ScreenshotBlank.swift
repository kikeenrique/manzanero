import CoreGraphics
import Foundation
import ImageIO

/// Whether a screenshot came back entirely black, and what that can mean.
///
/// With FairPlay video on screen an Apple TV's screenshot was black
/// (an agent's report, 2026-11-23): the device leaves protected content
/// out of captures, and the interface layer alone cannot be had. The tool
/// cannot prove that cause, but it can narrow it: a sleeping Apple TV
/// refuses a screenshot outright (`AppleTVPower.isAsleep`), so a black
/// picture from one that gave a picture is a black screen or protected
/// video. A phone whose display is off already gets `displayNote`.
enum ScreenshotBlank {
    /// The longest side of the thumbnail that is measured; large enough
    /// that a line of small bright text still lifts some pixels.
    static let thumbnailSide = 256
    /// A pixel is dark when none of its channels is above this (of 255).
    static let darkLimit: UInt8 = 12

    static let externalNote = "The picture is entirely black. The Apple TV gave a picture, so it is not asleep: the screen is black, or protected content is on screen, which the device leaves out of screenshots, interface and all. Read the tree to see what is in front, and try frames --count 1: the device's video stream showed a layer that prevents capture whole on 2026-11-24 (FairPlay video untested)."
    static let displayNote = "The picture is entirely black while the display was not reported off: the screen is black, or protected video is on screen, which the device leaves out of captures. Read the tree to see what is in front."

    /// True when every pixel of the image's thumbnail is dark, false when
    /// one is not, nil when the file cannot be read as an image.
    static func isBlank(_ url: URL) -> Bool? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSide] as CFDictionary)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for index in stride(from: 0, to: pixels.count, by: 4)
        where pixels[index] > darkLimit || pixels[index + 1] > darkLimit || pixels[index + 2] > darkLimit {
            return false
        }
        return true
    }

    /// What marks Apple's player in a tvOS tree, read on an Apple TV
    /// simulator on 2026-11-23 with the tvOS probe's silent video: class
    /// names (native attribute 5003) while it plays with its controls
    /// hidden, and the transport bar's elements while they show. A player
    /// an app draws itself on a bare `AVPlayerLayer` may show none of them.
    static let playerClasses = ["AVPlayerViewControllerContainerView", "AVPlayerLayerView", "AVNowPlayingTransportBar"]
    static let playerIdentifiers = ["Media Controls", "Scrub Needle", "AXElapsedTime"]

    /// Whether a tree's JSON shows Apple's player; nil when it has no nodes.
    static func showsPlayer(_ tree: Data) -> Bool? {
        guard let root = (try? JSONSerialization.jsonObject(with: tree)) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else { return nil }
        return nodes.contains { node in
            if let identifier = node["identifier"] as? String, playerIdentifiers.contains(identifier) { return true }
            guard let name = (node["nativeAttributes"] as? [String: Any])?["5003"] as? String else { return false }
            return playerClasses.contains { name.contains($0) }
        }
    }

    static let playerNote = "Apple's video player is in front, so protected video is the likely cause: the device leaves it out of screenshots, interface and all. The tree still reads the player's controls while they show (Media Controls has the position), and frames --count 1 may show the picture: the device's video stream showed a layer that prevents capture whole on 2026-11-24 (FairPlay video untested)."

    /// Adds `playerOnScreen` after a blank Apple TV picture, from one tree
    /// read by `readTree`; a failed read adds `playerCheckUnavailable`
    /// instead. Any other receipt is left as it is and nothing is read.
    static func annotatePlayer(_ receipt: Data, isolation: isolated (any Actor)? = #isolation,
                               readTree: () async throws -> Data) async -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: receipt)) as? [String: Any],
              root["blankImage"] as? Bool == true, root["displayPower"] as? String == DeviceUIReadiness.externalPower else { return receipt }
        do {
            guard let player = showsPlayer(try await readTree()) else {
                throw CommandFailure(.internal, "The tree had no nodes.", inputSent: .none)
            }
            root["playerOnScreen"] = player
            if player { root["blankNote"] = playerNote }
        } catch {
            root["playerCheckUnavailable"] = CommandFailure.classify(error).description
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? receipt
    }

    static let framesNote = "Some saved frames are entirely black: the screen was black then, or protected content (FairPlay, or a layer that prevents capture) was on screen, which the device leaves out of its stream."

    /// `frames`' receipt with `blank: true` on each saved frame that is
    /// entirely black, `blankFrames` (how many), and `blankNote` when there
    /// are any. A frame that cannot be read is left unmarked.
    static func annotateFrames(_ receipt: [String: Any], directory: URL) -> [String: Any] {
        guard let frames = receipt["frames"] as? [[String: Any]] else { return receipt }
        var count = 0
        var marked = frames
        for index in marked.indices {
            guard let file = marked[index]["file"] as? String,
                  isBlank(directory.appendingPathComponent(file)) == true else { continue }
            marked[index]["blank"] = true
            count += 1
        }
        var receipt = receipt
        receipt["frames"] = marked
        receipt["blankFrames"] = count
        if count > 0 { receipt["blankNote"] = framesNote }
        return receipt
    }

    /// The `--destination` of a planned `devicectl` screenshot.
    static func destination(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--destination"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// Adds `blankImage` to a screenshot's receipt, and `blankNote` when it
    /// is true and the display was not reported off (that case has its own
    /// note). Reads the receipt's `displayPower`, so it runs after
    /// `DeviceUIReadiness.annotateScreenshot`. An unreadable image leaves the
    /// receipt as it is; this never fails a screenshot.
    static func annotate(_ receipt: Data, image: URL?) -> Data {
        guard let image, let blank = isBlank(image),
              var root = (try? JSONSerialization.jsonObject(with: receipt)) as? [String: Any] else { return receipt }
        root["blankImage"] = blank
        if blank {
            switch root["displayPower"] as? String {
            case "off": break
            case DeviceUIReadiness.externalPower: root["blankNote"] = externalNote
            default: root["blankNote"] = displayNote
            }
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? receipt
    }
}
