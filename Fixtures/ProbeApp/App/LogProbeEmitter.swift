import Foundation
import os
import ProbeCore
import UIKit

/// `probe.log.emit`: emits one set when activated through accessibility
/// (Manzanero `press --id probe.log.emit`).
final class LogProbeEmitElement: UIAccessibilityElement {
    var activate: (@MainActor () -> Void)?
    var read: (@MainActor () -> String)?

    override var accessibilityValue: String? {
        get { read?() }
        set { _ = newValue }
    }

    override func accessibilityActivate() -> Bool {
        activate?()
        // Handled: UIKit must not fall back to a synthesized tap.
        return true
    }
}

/// Writes the log probe's lines (`LogProbe`) to the unified log, stdout and
/// stderr. Separate from the touch probe; it touches none of its state.
@MainActor
final class LogProbeEmitter {
    private let logger: Logger
    private var sequence = 0

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "probe") {
        logger = Logger(subsystem: subsystem, category: LogProbe.category)
    }

    /// At launch: one set, then the deliberate crash if `-probeCrash` asks for it.
    func launched(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let token = LogProbe.token(arguments: arguments)
        emit(token: token)
        guard let mode = LogProbe.crashMode(arguments: arguments) else { return }
        // A short delay lets the launch finish and the lines reach the log store.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [logger] in
            let line = LogProbe.crashLine(token: token, mode: mode)
            logger.error("\(line, privacy: .public)")
            print(line)
            fflush(stdout)
            switch mode {
            case .abort: abort()
            case .trap: fatalError(line)
            }
        }
    }

    /// Sets emitted in this process, shown as the emit element's value.
    var sets: Int { sequence }

    /// Adds the `probe.log.emit` element to an accessibility container that
    /// already lists its elements (the touch surface). It is an element, not
    /// a view, so it never receives touches; its frame does not overlap the
    /// touch probe's elements.
    func attach(to container: UIView) {
        let element = LogProbeEmitElement(accessibilityContainer: container)
        element.accessibilityIdentifier = LogProbe.emitIdentifier
        element.accessibilityLabel = "Emit probe logs"
        element.accessibilityTraits = .button
        element.accessibilityFrameInContainerSpace = CGRect(x: 16, y: 400, width: 180, height: 52)
        element.read = { [unowned self] in LogProbe.emitValue(sets: sets) }
        element.activate = { [unowned self] in emit(token: LogProbe.emitToken) }
        container.accessibilityElements = (container.accessibilityElements ?? []) + [element]
    }

    func emit(token: String) {
        sequence += 1
        for emission in LogProbe.emissions(token: token, sequence: sequence) {
            let text = emission.text
            switch emission.channel {
            case .log(.debug): logger.debug("\(text, privacy: .public)")
            case .log(.info): logger.info("\(text, privacy: .public)")
            case .log(.notice): logger.notice("\(text, privacy: .public)")
            case .log(.error): logger.error("\(text, privacy: .public)")
            case .log(.fault): logger.fault("\(text, privacy: .public)")
            case .logPrivate: logger.notice("\(text, privacy: .public)\(emission.privateValue ?? "", privacy: .private)")
            case .stdoutFlushed:
                print(text)
                fflush(stdout)
            case .stdoutUnflushed:
                print(text)
            case .stderr:
                FileHandle.standardError.write(Data((text + "\n").utf8))
            }
        }
    }
}
