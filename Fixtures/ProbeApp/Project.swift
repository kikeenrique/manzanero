import ProjectDescription

// Tuist manifest for the probe fixture app. Generate it with
// `mise run probe-app:generate`, which copies this manifest and Tuist.swift
// into tmp/probe-app/generated/ and generates there, so no Xcode project or
// Derived/ output is written next to the tracked sources. The task sets
// TUIST_PROBE_APP_FIXTURE to the fixture directory relative to that copy;
// without it, paths resolve next to this manifest. See docs/probe-app.md.

let fixture = Environment.probeAppFixture.getString(default: ".")

let swiftSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MARKETING_VERSION": "1.0",
    "CURRENT_PROJECT_VERSION": "1",
]

// Tuist writes `bundleId` into the target's build settings, which would
// override any xcconfig value. The variable defers it to the xcconfig: the
// tracked default lives in Config/ProbeApp.xcconfig and a person's own
// value in the untracked tmp/probe-app/Signing.xcconfig it includes.
let signingConfig: Path = .relativeToManifest("\(fixture)/Config/ProbeApp.xcconfig")

let project = Project(
    name: "ProbeApp",
    options: .options(automaticSchemesOptions: .disabled),
    packages: [.package(path: .relativeToManifest("\(fixture)/ProbeCore"))],
    settings: .settings(base: swiftSettings),
    targets: [
        .target(
            name: "ProbeApp",
            destinations: [.iPhone],
            product: .app,
            bundleId: "$(PROBE_APP_BUNDLE_ID)",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .dictionary([
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "Probe",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSRequiresIPhoneOS": true,
                "UILaunchScreen": [:],
                "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false],
                "UIStatusBarHidden": true,
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                // Lets the Documents directory (and touch-log.jsonl) be browsed and copied.
                "UIFileSharingEnabled": true,
            ]),
            sources: [.glob(.relativeToManifest("\(fixture)/App/**/*.swift"))],
            dependencies: [.package(product: "ProbeCore")],
            settings: .settings(configurations: [
                .debug(name: "Debug", xcconfig: signingConfig),
                .release(name: "Release", xcconfig: signingConfig),
            ])
        ),
        .target(
            name: "ProbeAppUITests",
            destinations: [.iPhone],
            product: .uiTests,
            bundleId: "com.lemambo.manzanero.probeapp.uitests",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .default,
            sources: [.glob(.relativeToManifest("\(fixture)/UITests/**/*.swift"))],
            dependencies: [.target(name: "ProbeApp")]
        ),
    ],
    schemes: [
        .scheme(
            name: "ProbeApp",
            buildAction: .buildAction(targets: ["ProbeApp"]),
            testAction: .targets(["ProbeAppUITests"]),
            runAction: .runAction(executable: "ProbeApp")
        ),
    ]
)
