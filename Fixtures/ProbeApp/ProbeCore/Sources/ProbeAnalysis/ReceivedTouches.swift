import Foundation
import ProbeCore

/// One contact as the probe received it, rebuilt from log events or from a gesture readout.
public struct ReceivedContact: Codable, Sendable, Equatable {
    /// The probe's contact index in its session.
    public var contact: Int
    /// Normalised position at `began`; nil when the `began` lies outside the evidence.
    public var from: NormalizedPoint?
    /// Last known normalised position (at `ended`/`cancelled` when the contact finished).
    public var to: NormalizedPoint?
    /// `UITouch.timestamp` of `began` (device uptime; only differences are meaningful).
    public var began: Double?
    /// Seconds from `began` to `ended`/`cancelled`, by device timestamps.
    public var duration: Double?
    /// `ended`, `cancelled`, or nil when the contact was still down at the end of the evidence.
    public var end: String?
    public var moves: Int
    /// The `began` event was part of the evidence.
    public var sawBegan: Bool

    public init(contact: Int, from: NormalizedPoint?, to: NormalizedPoint?, began: Double?, duration: Double?,
                end: String?, moves: Int, sawBegan: Bool) {
        self.contact = contact
        self.from = from
        self.to = to
        self.began = began
        self.duration = duration
        self.end = end
        self.moves = moves
        self.sawBegan = sawBegan
    }
}

/// Contacts from a first `began` until none remain down, the probe's own gesture definition.
public struct ReceivedGesture: Codable, Sendable, Equatable {
    /// In order of first appearance.
    public var contacts: [ReceivedContact]
    /// Highest `active` the probe reported during the gesture (contacts down at once).
    public var maxActive: Int
    /// False when the evidence ended while a contact was still down.
    public var complete: Bool
    public var firstSeq: Int?
    public var lastSeq: Int?
}

public enum ReceivedTouches {
    /// Split events (already restricted to one window, in `seq` order) into gestures.
    /// A moved/ended/cancelled event for a contact whose `began` is not in the window
    /// starts a contact with `sawBegan == false`.
    public static func gestures(from events: [TouchEventRecord]) -> [ReceivedGesture] {
        var gestures: [ReceivedGesture] = []
        var contacts: [Int: ReceivedContact] = [:]
        var order: [Int] = []
        var open = Set<Int>()
        var maxActive = 0
        var firstSeq: Int?
        var lastSeq: Int?

        func close(complete: Bool) {
            guard !order.isEmpty else { return }
            gestures.append(ReceivedGesture(contacts: order.compactMap { contacts[$0] }, maxActive: maxActive,
                                            complete: complete, firstSeq: firstSeq, lastSeq: lastSeq))
            contacts = [:]
            order = []
            open = []
            maxActive = 0
            firstSeq = nil
            lastSeq = nil
        }

        for event in events {
            let point = NormalizedPoint(event.nx, event.ny)
            if firstSeq == nil { firstSeq = event.seq }
            lastSeq = event.seq
            maxActive = max(maxActive, event.active)
            if contacts[event.contact] == nil { order.append(event.contact) }
            var contact = contacts[event.contact]
                ?? ReceivedContact(contact: event.contact, from: nil, to: nil, began: nil, duration: nil,
                                   end: nil, moves: 0, sawBegan: false)
            switch event.phase {
            case .began:
                if !contact.sawBegan {
                    contact.sawBegan = true
                    contact.from = point
                    contact.began = event.t
                }
                contact.to = point
                open.insert(event.contact)
            case .moved:
                contact.moves += 1
                contact.to = point
                open.insert(event.contact)
            case .ended, .cancelled:
                contact.to = point
                contact.end = event.phase.rawValue
                contact.duration = contact.began.map { ProbeJSON.round(event.t - $0, 6) }
                open.remove(event.contact)
            }
            contacts[event.contact] = contact
            if open.isEmpty { close(complete: true) }
        }
        close(complete: false)
        return gestures
    }

    /// The `probe.touch.last-gesture` readout as a received gesture.
    public static func gesture(from readout: LastGestureReadout) -> ReceivedGesture {
        gesture(contacts: readout.contacts, maxActive: readout.maxActive)
    }

    /// One entry of the `probe.touch.recent-gestures` readout as a received gesture.
    public static func gesture(from entry: RecentGesture) -> ReceivedGesture {
        gesture(contacts: entry.contacts, maxActive: entry.maxActive)
    }

    private static func gesture(contacts: [GestureContact], maxActive: Int) -> ReceivedGesture {
        func point(_ pair: [Double]) -> NormalizedPoint? { pair.count == 2 ? NormalizedPoint(pair[0], pair[1]) : nil }
        return ReceivedGesture(
            contacts: contacts.map {
                ReceivedContact(contact: $0.c, from: point($0.from), to: point($0.to), began: $0.began,
                                duration: $0.duration, end: $0.end, moves: $0.moves, sawBegan: true)
            },
            maxActive: maxActive, complete: true, firstSeq: nil, lastSeq: nil)
    }
}
