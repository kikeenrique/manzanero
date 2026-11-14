import Foundation

/// One in-process decoded JPEG and its elapsed host emission time.
struct TimedVideoFrame: Sendable {
    let nanoseconds: UInt64
    let jpeg: Data
}
