import Foundation

// RTCP wire/statistics reference: AXe PhysicalDisplayRTCP.swift at
// 4b622d4436fc441534e6ee8c7196728cd762dbff, Copyright (c) 2025 Cameron Cooke.
// MIT attribution is retained in ThirdParty/AXe-LICENSE.txt.
/// Single negotiated unicast source: RFC 3550 RR/SDES and sender-report timing.
/// Scheduling uses the peer's negotiated interval, not a multiparty session model.
struct MediaRTCPReceiver {
    let sender: UInt32
    let receiver: UInt32
    let payloadType: UInt8
    private let cname: Data
    private let interval: UInt64
    private var nextReport: UInt64
    private var sequences = Sequences()
    private var previousArrival: UInt64?
    private var previousTimestamp: UInt32?
    private var jitter = 0.0
    private var senderReport: (middleNTP: UInt32, arrival: UInt64)?
    private(set) var senderReportsObserved: UInt64 = 0

    init(sender: UInt32, receiver: UInt32, payloadType: UInt8, cname: String,
         intervalSeconds: Double, now: UInt64) throws {
        guard sender != 0, receiver != 0, sender != receiver, payloadType <= 127,
              !(64...95).contains(payloadType), (1...255).contains(cname.utf8.count),
              intervalSeconds.isFinite, (0.2...10).contains(intervalSeconds) else {
            throw CommandFailure(description: "Invalid owned unicast RTCP profile.")
        }
        self.sender = sender; self.receiver = receiver; self.payloadType = payloadType
        self.cname = Data(cname.utf8)
        interval = UInt64(intervalSeconds * 1_000_000_000)
        nextReport = min(now, UInt64.max - interval) + interval
    }

    mutating func observe(_ datagram: Data, now: UInt64) throws {
        guard (2...65_535).contains(datagram.count) else { return }
        let bytes = Array(datagram)
        if bytes[0] >> 6 == 2, (192...223).contains(bytes[1]) {
            observeControl(bytes, now: now)
            return
        }
        guard let packet = MediaRTPPacket(datagram, payloadType: payloadType) else { return }
        guard packet.source == sender else { throw CommandFailure(description: "RTP source differs from the negotiated RTCP sender.") }
        let generation = sequences.generation
        guard sequences.observe(packet.sequence) else { return }
        if generation != sequences.generation { previousArrival = nil; previousTimestamp = nil; jitter = 0 }
        if let arrival = previousArrival, let timestamp = previousTimestamp, now >= arrival {
            let arrivalTicks = Double(now - arrival) * 90_000 / 1_000_000_000 // RFC 7798 HEVC clock
            let mediaTicks = Double(Int32(bitPattern: packet.timestamp &- timestamp))
            jitter += (abs(arrivalTicks - mediaTicks) - jitter) / 16
        }
        previousArrival = now; previousTimestamp = packet.timestamp
    }

    mutating func reportIfDue(now: UInt64) -> Data? {
        guard now >= nextReport else { return nil }
        nextReport = min(now, UInt64.max - interval) + interval
        let loss = sequences.report()
        var report = Data([loss == nil ? 0x80 : 0x81, 201])
        report.rtcpAppend(UInt16(loss == nil ? 1 : 7))
        report.rtcpAppend(receiver)
        if let loss {
            report.rtcpAppend(sender)
            report.append(loss.fraction)
            let lost = UInt32(bitPattern: loss.total)
            for shift in [16, 8, 0] { report.append(UInt8(truncatingIfNeeded: lost >> shift)) }
            report.rtcpAppend(loss.highest)
            report.rtcpAppend(UInt32(min(jitter, Double(UInt32.max))))
            report.rtcpAppend(senderReport?.middleNTP ?? 0)
            let delay = senderReport.map { now >= $0.arrival ? Double(now - $0.arrival) * 65_536 / 1_000_000_000 : 0 } ?? 0
            report.rtcpAppend(UInt32(min(delay, Double(UInt32.max))))
        }
        let size = 4 + 4 + 2 + cname.count + 1
        let padding = (4 - size % 4) % 4
        report.append(contentsOf: [0x81, 202])
        report.rtcpAppend(UInt16((size + padding) / 4 - 1))
        report.rtcpAppend(receiver)
        report.append(contentsOf: [1, UInt8(cname.count)])
        report.append(cname)
        report.append(contentsOf: repeatElement(0, count: 1 + padding))
        return report
    }

    private mutating func observeControl(_ bytes: [UInt8], now: UInt64) {
        guard bytes.count <= 65_535 else { return }
        var offset = 0, packets = 0
        var candidate: UInt32?
        var matchingReports: UInt64 = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4, bytes[offset] >> 6 == 2, (192...223).contains(bytes[offset + 1]), packets < 128 else { return }
            let length = ((Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) + 1) * 4
            guard length >= 4, length <= bytes.count - offset else { return }
            var effective = length
            if bytes[offset] & 32 != 0 {
                let padding = Int(bytes[offset + length - 1])
                guard offset + length == bytes.count, padding > 0, padding <= length - 4 else { return }
                effective -= padding
            }
            if bytes[offset + 1] == 200 {
                guard effective >= 28 + Int(bytes[offset] & 31) * 24 else { return }
                if Self.word(bytes, offset + 4) == sender {
                    candidate = Self.word(bytes, offset + 8) << 16 | Self.word(bytes, offset + 12) >> 16
                    matchingReports += 1
                }
            }
            offset += length; packets += 1
        }
        if let candidate { senderReport = (candidate, now); senderReportsObserved += matchingReports }
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private struct Sequences {
        private var base: UInt16?
        private var highest: UInt16 = 0
        private var cycles: UInt64 = 0
        private var received: UInt64 = 0
        private var expectedBefore: UInt64 = 0
        private var receivedBefore: UInt64 = 0
        private var restart: UInt16?
        private(set) var generation: UInt64 = 0

        mutating func observe(_ value: UInt16) -> Bool {
            if base == nil { reset(value) }
            else {
                let delta = Int(value &- highest)
                if delta < 3000 {
                    if value < highest { cycles += 65_536 }
                    highest = value; restart = nil
                } else if delta <= 65_536 - 100 {
                    guard restart == value else { restart = value &+ 1; return false }
                    reset(value)
                }
            }
            received += 1
            return true
        }

        mutating func report() -> (fraction: UInt8, total: Int32, highest: UInt32)? {
            guard let base else { return nil }
            let extended = cycles + UInt64(highest)
            let expected = extended - UInt64(base) + 1
            let interval = expected - expectedBefore
            let lost = Int64(interval) - Int64(received - receivedBefore)
            let fraction = interval > 0 && lost > 0 ? min(255, UInt64(lost) * 256 / interval) : 0
            expectedBefore = expected; receivedBefore = received
            return (UInt8(fraction), Int32(min(8_388_607, max(-8_388_608, Int64(expected) - Int64(received)))), UInt32(truncatingIfNeeded: extended))
        }

        private mutating func reset(_ value: UInt16) {
            base = value; highest = value; cycles = 0; received = 0
            expectedBefore = 0; receivedBefore = 0; restart = nil; generation += 1
        }
    }
}

private extension Data {
    mutating func rtcpAppend<T: FixedWidthInteger>(_ value: T) {
        var network = value.bigEndian
        Swift.withUnsafeBytes(of: &network) { append(contentsOf: $0) }
    }
}
