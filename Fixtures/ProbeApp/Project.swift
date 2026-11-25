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

let tvSigningConfig: Path = .relativeToManifest("\(fixture)/Config/ProbeTV.xcconfig")

let watchSigningConfig: Path = .relativeToManifest("\(fixture)/Config/ProbeWatch.xcconfig")

let project = Project(
    name: "ProbeApp",
    options: .options(automaticSchemesOptions: .disabled),
    packages: [.package(path: .relativeToManifest("\(fixture)/ProbeCore"))],
    settings: .settings(base: swiftSettings),
    targets: [
        .target(
            name: "ProbeApp",
            // iPad as well, for coordinate measurements on an iPad simulator.
            destinations: [.iPhone, .iPad],
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
                // The probe normalizes by its window; keep that window the whole screen on iPad.
                "UIRequiresFullScreen": true,
                // The view controller follows the device into landscape unless
                // the probe is launched with -ProbeAllowRotation NO (portrait only).
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft",
                                                     "UIInterfaceOrientationLandscapeRight"],
                "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                                          "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                // The biometric probe (probe.biometrics.request) asks for Face ID.
                "NSFaceIDUsageDescription": "The probe checks that a Face ID prompt can be raised and answered.",
                // Lets the Documents directory (and touch-log.jsonl) be browsed and copied.
                "UIFileSharingEnabled": true,
                // The URL probe: `open-url manzanero-probe://…` reaches the app.
                "CFBundleURLTypes": [["CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleURLSchemes": ["manzanero-probe"]]],
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
            destinations: [.iPhone, .iPad],
            product: .uiTests,
            bundleId: "com.lemambo.manzanero.probeapp.uitests",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .default,
            sources: [.glob(.relativeToManifest("\(fixture)/UITests/**/*.swift"))],
            dependencies: [.target(name: "ProbeApp")]
        ),
        // The tvOS probe (docs/probe-app.md#tvos-probe): its own sources and
        // no dependency on ProbeCore.
        .target(
            name: "ProbeTV",
            destinations: [.appleTv],
            product: .app,
            bundleId: "$(PROBE_TV_BUNDLE_ID)",
            deploymentTargets: .tvOS("18.0"),
            infoPlist: .dictionary([
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "Probe TV",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                "UIUserInterfaceStyle": "Automatic",
                // `open-url manzanero-probe-tv://…` reaches the app.
                "CFBundleURLTypes": [["CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleURLSchemes": ["manzanero-probe-tv"]]],
            ]),
            sources: [.glob(.relativeToManifest("\(fixture)/TV/**/*.swift"))],
            settings: .settings(configurations: [
                .debug(name: "Debug", xcconfig: tvSigningConfig),
                .release(name: "Release", xcconfig: tvSigningConfig),
            ])
        ),
        // The watchOS probe (docs/probe-app.md#watchos-probe): a standalone
        // watch app with its own sources, so checks on a watch run inside an
        // app of this project's and show nothing of the wearer's.
        .target(
            name: "ProbeWatch",
            destinations: [.appleWatch],
            product: .app,
            bundleId: "$(PROBE_WATCH_BUNDLE_ID)",
            deploymentTargets: .watchOS("11.0"),
            infoPlist: .dictionary([
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "Probe Watch",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "WKApplication": true,
                "WKWatchOnly": true,
            ]),
            sources: [.glob(.relativeToManifest("\(fixture)/Watch/**/*.swift"))],
            settings: .settings(configurations: [
                .debug(name: "Debug", xcconfig: watchSigningConfig),
                .release(name: "Release", xcconfig: watchSigningConfig),
            ])
        ),
    ],
    schemes: [
        .scheme(
            name: "ProbeApp",
            buildAction: .buildAction(targets: ["ProbeApp"]),
            testAction: .targets(["ProbeAppUITests"]),
            runAction: .runAction(executable: "ProbeApp")
        ),
        .scheme(
            name: "ProbeTV",
            buildAction: .buildAction(targets: ["ProbeTV"]),
            runAction: .runAction(executable: "ProbeTV")
        ),
        .scheme(
            name: "ProbeWatch",
            buildAction: .buildAction(targets: ["ProbeWatch"]),
            runAction: .runAction(executable: "ProbeWatch")
        ),
    ]
)
