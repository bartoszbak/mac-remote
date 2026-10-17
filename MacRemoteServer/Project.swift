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
                    "CODE_SIGN_STYLE": "Automatic",
                    "DEVELOPMENT_TEAM": "746CH7LGJ5",
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
                    "CODE_SIGN_STYLE": "Automatic",
                    "DEVELOPMENT_TEAM": "746CH7LGJ5"
                ]
            )
        )
    ]
)
