# Repository instructions

Prefix shell commands with `rtk`. Use `rtk proxy` when unfiltered output is needed.

## Project

- Build `appledevicescmd`, a Swift CLI for Apple-device inspection and control, with optional MCP support sharing the same operations.
- Open-source third-party libraries such as `idevice` are permitted. Preserve licenses and attribution. Do not use proprietary device-control binaries as runtime dependencies.
- Keep platform-specific and private interfaces behind backend boundaries. Distinguish implemented features from verified device behavior.

## Dependencies

- Device operations must communicate with Apple frameworks/APIs from this project's code or use Apple-provided executables. Do not invoke non-Apple device-control executables, including AXe, idevice, or ipb helpers.
- Use third-party device projects as implementation references. Prefer existing Apple frameworks and maintained general-purpose libraries over custom infrastructure where appropriate.
- Ask the user before adding third-party dependencies that have not already been authorized. Preserve licenses and attribution.

## Workflow

- Commit each completed task separately with a descriptive message. Verify the change before committing. If Git writes fail, report the error and do not claim a commit exists.
- Keep research, plans, protocol notes, and verification records in `docs/`. Keep the root README as the entry point and maintain its links.
- Put downloads, extracted binaries, temporary tools, caches, and generated investigation artifacts under the visible local `tmp/` directory. Do not use `.tmp/` or `/tmp` for task artifacts. Keep `tmp/` out of version control.
- Never commit credentials, local device data, or downloaded commercial app binaries.

## Implementation and validation

- Use Swift 6.2 or later and preserve strict concurrency checking.
- Invoke external tools with argument arrays, without shell interpolation of user input. Keep CLI stdout suitable for the documented machine-readable format and diagnostics on stderr.
- Run applicable build checks through `xcsift`; use meaningful tests for protocol encoding, parsing, and process behavior.
- Check installed tool help or authoritative sources before relying on Apple tool flags or private protocol details.
- Record OS/tool versions and limitations for device integration checks. A successful build or dry run does not prove live-device functionality.
