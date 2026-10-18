import ProjectDescription

let project = Project(
    name: "MacRemoteServer",
    targets: [
        .target(
            name: "MacRemoteServer",
            destinations: .macOS,
            product: .app,
            bundleId: "com.pedrocid.MacRemoteServer",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "MacRemote Server",
                "CFBundleShortVersionString": "1.1",
                "CFBundleVersion": "2",
                "LSUIElement": true,
                "NSHighResolutionCapable": true,
                "NSBonjourServices": .array(["_macremote._tcp"]),
                "NSLocalNetworkUsageDescription": "MacRemote uses the local network to communicate with iOS devices"
            ]),
            sources: [
                "Sources/**",
                "../Shared/**"
            ],
            resources: [
                "Resources/**"
            ],
            entitlements: .dictionary([
                "com.apple.security.app-sandbox": .boolean(false),
                "com.apple.security.network.server": .boolean(true),
                "com.apple.security.network.client": .boolean(true)
            ]),
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "5.9",
                    // No accent colour set exists; stop actool looking for one.
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    // Every build, Debug included, is signed with the same Developer ID so
                    // macOS sees one app across rebuilds and keeps Accessibility, Screen
                    // Recording and Keychain grants. Ad-hoc signing would reset them each time.
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "Developer ID Application",
                    "DEVELOPMENT_TEAM": "TJ3ALYQV5G",
                    "OTHER_CODE_SIGN_FLAGS": "--timestamp",
                    "ENABLE_HARDENED_RUNTIME": "YES"
                ]
            )
        ),
        .target(
            name: "MacRemoteServerTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.pedrocid.MacRemoteServerTests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [
                .target(name: "MacRemoteServer")
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "5.9",
                    // Must match the app: a hardened-runtime host only loads test bundles from its own team.
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "Developer ID Application",
                    "DEVELOPMENT_TEAM": "TJ3ALYQV5G"
                ]
            )
        )
    ]
)
