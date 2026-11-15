import Foundation
import Testing
@testable import Manzanero

struct DoctorTests {
    private static let coreDevicePath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"
    private static let tools = Doctor.tools.map { Doctor.ToolCheck(name: $0.name) }

    private static func host(_ major: Int = 27) -> DoctorHost {
        DoctorHost(macOS: OperatingSystemVersion(majorVersion: major, minorVersion: 2, patchVersion: 1), macOSBuild: "TESTBUILD",
                   xcodeVersion: "27.2", xcodeBuild: "27B52", coreDeviceVersion: "651.32")
    }

    private static func capabilities(coreDevice: Bool = true, missingSymbol: String? = nil) -> [PrivateCapability] {
        func symbol(_ name: String) -> PrivateInterfaceRequirement {
            .init(kind: .symbol, name: name, available: coreDevice && name != missingSymbol)
        }
        let prepare = [PrivateInterfaceRequirement(kind: .framework, name: coreDevicePath, available: coreDevice),
                       symbol("_coredevice_xpc_add_bundle"), symbol("_coredevice_xpc_init_services")]
        return [
            .init(identifier: "physical-input", summary: "Indigo", requirements: prepare + [symbol("xpc_remote_connection_send_message")]),
            .init(identifier: "media-inspection", summary: "Media", requirements: prepare + [symbol("xpc_remote_connection_send_message_with_reply")]),
            .init(identifier: "native-recording", summary: "Video", minimumMacOSMajor: 26, requirements: prepare + [
                .init(kind: .instanceMethod, name: "createOffer", owner: "AVCMediaStreamNegotiator", available: true),
                .init(kind: .classMethod, name: "negotiatorSettingsForMode:deviceRole:options:errorString:",
                      owner: "AVCMediaStreamNegotiatorSettings", available: true),
                .init(kind: .instanceMethod, name: "isRTCPFBEnabled", owner: "VCMediaNegotiatorResultsVideo", required: false, available: true)
            ]),
            .init(identifier: "keyed-archive-uid", summary: "UID", requirements: [
                .init(kind: .symbol, name: "_CFKeyedArchiverUIDGetValue", available: true)
            ])
        ]
    }

    private static func entries(_ output: CommandOutput) throws -> [String: [String: Any]] {
        let array = try #require(try JSONSerialization.jsonObject(with: output.data) as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: array.map { ($0["name"] as? String ?? "", $0) })
    }

    @Test func allAvailableKeepsToolEntriesAndReportsHost() throws {
        let output = try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: Self.capabilities())
        #expect(output.exitCode == 0)
        let entries = try Self.entries(output)
        for name in ["Xcode", "CoreDevice", "CoreSimulator"] {
            #expect(entries[name]?["status"] as? String == "available")
            #expect(entries[name]?["kind"] as? String == "tool")
        }
        let host = try #require(entries["Host"])
        #expect(host["macOSVersion"] as? String == "27.2.1")
        #expect(host["xcodeVersion"] as? String == "27.2")
        #expect(host["xcodeBuild"] as? String == "27B52")
        #expect(host["coreDeviceVersion"] as? String == "651.32")
        #expect(host["avConferenceVersion"] == nil)
        for name in ["physical-input", "media-inspection", "native-recording", "keyed-archive-uid"] {
            #expect(entries[name]?["status"] as? String == "available")
            #expect((entries[name]?["missing"] as? [String])?.isEmpty == true)
        }
        #expect(entries["native-recording"]?["minimumMacOS"] as? String == "26")
        #expect(entries["physical-input"]?["checked"] as? Int == 4)
    }

    @Test func oneMissingSymbolNamesItWithoutFailingExit() throws {
        let capabilities = Self.capabilities(missingSymbol: "xpc_remote_connection_send_message")
        let output = try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: capabilities)
        #expect(output.exitCode == 0)
        let entries = try Self.entries(output)
        #expect(entries["physical-input"]?["status"] as? String == "missing")
        #expect(entries["physical-input"]?["missing"] as? [String] == ["xpc_remote_connection_send_message"])
        #expect(entries["media-inspection"]?["status"] as? String == "available")
    }

    @Test func absentFrameworkMarksEveryDependentCapabilityMissing() throws {
        let output = try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: Self.capabilities(coreDevice: false))
        #expect(output.exitCode == 0)
        let entries = try Self.entries(output)
        for name in ["physical-input", "media-inspection", "native-recording"] {
            #expect(entries[name]?["status"] as? String == "missing")
            let missing = try #require(entries[name]?["missing"] as? [String])
            #expect(missing.first == Self.coreDevicePath)
            #expect(missing.contains("_coredevice_xpc_init_services"))
        }
        #expect(entries["keyed-archive-uid"]?["status"] as? String == "available")
    }

    @Test func optionalAndMethodNamesUseObjectiveCNotation() throws {
        let capability = PrivateCapability(identifier: "native-recording", summary: "Video", requirements: [
            .init(kind: .instanceMethod, name: "createOffer", owner: "AVCMediaStreamNegotiator", available: false),
            .init(kind: .classMethod, name: "negotiatorSettingsForMode:deviceRole:options:errorString:", owner: "AVCMediaStreamNegotiatorSettings", available: true),
            .init(kind: .instanceMethod, name: "isRTCPFBEnabled", owner: "VCMediaNegotiatorResultsVideo", required: false, available: false)
        ])
        let entries = try Self.entries(try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: [capability]))
        #expect(entries["native-recording"]?["missing"] as? [String] == ["-[AVCMediaStreamNegotiator createOffer]"])
        #expect(entries["native-recording"]?["optionalMissing"] as? [String] == ["-[VCMediaNegotiatorResultsVideo isRTCPFBEnabled]"])
        let degraded = PrivateCapability(identifier: "x", summary: "", requirements: [capability.requirements[1], capability.requirements[2]])
        #expect(degraded.status(macOSMajor: 27) == .degraded)
        #expect(PrivateInterfaceRequirement(kind: .classMethod, name: "a:", owner: "B", available: true).displayName == "+[B a:]")
    }

    @Test func oldMacOSReportsHostRequirementForNativeRecording() throws {
        let entries = try Self.entries(try Doctor.report(tools: Self.tools, host: Self.host(15), capabilities: Self.capabilities()))
        let recording = try #require(entries["native-recording"])
        #expect(recording["status"] as? String == "unsupported-host")
        #expect((recording["missing"] as? [String])?.isEmpty == true)
        #expect((recording["detail"] as? String)?.contains("macOS 26") == true)
        #expect(entries["physical-input"]?["status"] as? String == "available")
    }

    @Test func unavailableToolStillSetsExitCode() throws {
        var tools = Self.tools
        tools[1] = Doctor.ToolCheck(name: "CoreDevice", failure: "devicectl failed (1)")
        let output = try Doctor.report(tools: tools, host: Self.host(), capabilities: Self.capabilities(coreDevice: false))
        #expect(output.exitCode == 1)
        let entries = try Self.entries(output)
        #expect(entries["CoreDevice"]?["status"] as? String == "unavailable")
        #expect(entries["CoreDevice"]?["detail"] as? String == "devicectl failed (1)")
    }

    @Test func runUsesXcodeOutputAndInjectedCapabilities() throws {
        var invoked: [[String]] = []
        let output = try Doctor.run({ arguments in
            invoked.append(arguments)
            if arguments.first == "simctl" { throw CommandFailure(description: "simctl failed (1)") }
            return arguments.first == "xcodebuild" ? Data("Xcode 27.2\nBuild version 27B52\n".utf8) : Data("{}".utf8)
        }, capabilities: { Self.capabilities() })
        #expect(invoked.map(\.first) == ["xcodebuild", "devicectl", "simctl"])
        #expect(output.exitCode == 1)
        let entries = try Self.entries(output)
        #expect(entries["Host"]?["xcodeVersion"] as? String == "27.2")
        #expect(entries["Host"]?["xcodeBuild"] as? String == "27B52")
        #expect(entries["CoreSimulator"]?["status"] as? String == "unavailable")
    }

    private static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    private static let translationPath = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
    private static let dtuhiddPlist = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/Library/LaunchDaemons/com.apple.coredevice.dtuhidd.plist"

    /// The two simulator rows as the bridge table lists them, with the named
    /// interfaces reported unavailable.
    private static func simulatorCapabilities(missing: Set<String> = []) -> [PrivateCapability] {
        func requirement(_ kind: PrivateInterfaceRequirement.Kind, _ name: String, owner: String? = nil, required: Bool = true) -> PrivateInterfaceRequirement {
            .init(kind: kind, name: name, owner: owner, required: required, available: !missing.contains(name))
        }
        let device = [requirement(.framework, coreSimulatorPath), requirement(.objcClass, "SimServiceContext"),
                      requirement(.classMethod, "sharedServiceContextForDeveloperDir:error:", owner: "SimServiceContext"),
                      requirement(.instanceMethod, "lookup:error:", owner: "SimDevice"),
                      requirement(.instanceMethod, "name", owner: "SimDevice", required: false)]
        return [
            .init(identifier: "simulator-input", summary: "dtuhidd", requirements: device + [
                requirement(.symbol, "xpc_endpoint_create_mach_port_4sim"), requirement(.symbol, "xpc_connection_enable_sim2host_4sim"),
                requirement(.file, dtuhiddPlist)]),
            .init(identifier: "simulator-accessibility", summary: "AXP", requirements: device + [
                requirement(.instanceMethod, "sendAccessibilityRequestAsync:completionQueue:completionHandler:", owner: "SimDevice"),
                requirement(.framework, translationPath), requirement(.objcClass, "AXPTranslatorRequest"),
                requirement(.classMethod, "supportsSecureCoding", owner: "AXPTranslatorRequest")])
        ]
    }

    @Test func simulatorRowsAreAvailableWhenEveryNameResolves() throws {
        let entries = try Self.entries(try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: Self.simulatorCapabilities()))
        for name in ["simulator-input", "simulator-accessibility"] {
            #expect(entries[name]?["status"] as? String == "available")
            #expect(entries[name]?["kind"] as? String == "private-interface")
            #expect(entries[name]?["usedByCommands"] as? Bool == true)
        }
        #expect(entries["simulator-input"]?["checked"] as? Int == 8)
    }

    @Test func missingCoreSimulatorDisablesBothSimulatorRowsWithoutFailingExit() throws {
        let output = try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: Self.simulatorCapabilities(missing: [Self.coreSimulatorPath]))
        #expect(output.exitCode == 0)
        let entries = try Self.entries(output)
        for name in ["simulator-input", "simulator-accessibility"] {
            #expect(entries[name]?["status"] as? String == "missing")
            #expect((entries[name]?["missing"] as? [String])?.first == Self.coreSimulatorPath)
        }
    }

    @Test func simulatorRowsNameEachMissingInterface() throws {
        let entries = try Self.entries(try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: Self.simulatorCapabilities(
            missing: [Self.dtuhiddPlist, "xpc_connection_enable_sim2host_4sim", "supportsSecureCoding", "name"])))
        // A daemon plist absent from an older CoreSimulator disables input only.
        #expect(entries["simulator-input"]?["missing"] as? [String] == ["xpc_connection_enable_sim2host_4sim", Self.dtuhiddPlist])
        #expect(entries["simulator-input"]?["optionalMissing"] as? [String] == ["-[SimDevice name]"])
        #expect(entries["simulator-accessibility"]?["missing"] as? [String] == ["+[AXPTranslatorRequest supportsSecureCoding]"])
        #expect(entries["simulator-accessibility"]?["status"] as? String == "missing")
        let degraded = try Self.entries(try Doctor.report(tools: Self.tools, host: Self.host(), capabilities: Self.simulatorCapabilities(missing: ["name"])))
        #expect(degraded["simulator-input"]?["status"] as? String == "degraded")
        #expect(PrivateInterfaceRequirement(kind: .file, name: "/x.plist", available: true).displayName == "/x.plist")
    }

    @Test func parsesXcodeVersionOutput() {
        let parsed = DoctorHost.parseXcode(Data("Xcode 27.2\nBuild version 27B52\n".utf8))
        #expect(parsed.version == "27.2")
        #expect(parsed.build == "27B52")
        let empty = DoctorHost.parseXcode(Data("unexpected".utf8))
        #expect(empty.version == nil && empty.build == nil)
    }

    /// Runs the real host-only check. CI hosts may lack CoreDevice's private
    /// framework, so this asserts only the table's shape, not availability.
    @Test func liveCheckReturnsWellFormedTable() throws {
        let capabilities = PrivateInterfaces.check()
        let identifiers = capabilities.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
        for expected in ["physical-input", "multi-contact-input", "tunnel-assertion", "rsd-accessibility",
                         "media-inspection", "native-recording", "keyed-archive-uid", "simulator-input", "simulator-accessibility"] {
            #expect(capabilities.first { $0.identifier == expected }?.usedByCommands == true)
        }
        #expect(capabilities.first { $0.identifier == "native-recording" }?.minimumMacOSMajor == 26)
        for capability in capabilities {
            #expect(!capability.summary.isEmpty)
            for requirement in capability.requirements {
                #expect(!requirement.name.isEmpty)
                #expect((requirement.owner != nil) == [.instanceMethod, .classMethod].contains(requirement.kind))
            }
            // A framework row precedes the names it provides.
            if let framework = capability.requirements.firstIndex(where: { $0.kind == .framework }),
               let firstName = capability.requirements.firstIndex(where: { $0.kind != .framework }), framework > firstName {
                Issue.record("\(capability.identifier) lists a framework after names it provides")
            }
        }
        let entries = try Self.entries(try Doctor.report(tools: Self.tools, host: .current(xcodeOutput: nil), capabilities: capabilities))
        #expect(entries.count == 3 + 1 + capabilities.count)
    }
}
