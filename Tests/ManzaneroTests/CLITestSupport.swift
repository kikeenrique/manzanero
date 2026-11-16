@testable import Manzanero

/// The argument vector the command service reads for a command line in the
/// CLI's grammar, as the CLI's parser produces it.
func legacy(_ arguments: [String]) throws -> [String] { try CLI.invocation(arguments).arguments }

/// The validated native physical input for a command line in the CLI's
/// grammar, such as `["long-press", "--device", udid, "--", "0.5", "0.5", "8"]`.
func physicalInput(_ arguments: [String]) throws -> CoreDeviceInput? {
    try CoreDeviceInput.parse(CoreDeviceInput.selectDefaultBackend(legacy(arguments)))
}
