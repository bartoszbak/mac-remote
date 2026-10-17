import ProjectDescription

let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .all,
        swiftVersion: "6.0",
        generationOptions: .options(
            resolveDependenciesWithSystemScm: false,
            disablePackageVersionLocking: true
        )
    )
)
