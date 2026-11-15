import ProjectDescription

// Marks the Tuist root for the touch probe so Tuist does not search upward
// (into the enclosing repository or another checkout). Local generation only:
// no account, server URL or full handle is configured.
// Generation refuses any other selected Xcode, so results stay comparable.
let tuist = Tuist(project: .tuist(compatibleXcodeVersions: ["27.2"]))
