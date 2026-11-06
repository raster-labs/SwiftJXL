# Security policy and implementation requirements

Status: stable release `2.0.0` (`v2.0.0`); see [Documentation/RELEASE-v2.0.0.md](Documentation/RELEASE-v2.0.0.md) for executed qualification gates and explicitly disclosed physical-device exclusions. No fixed vulnerability response-time deadline is promised.

## Reporting

Report suspected vulnerabilities through [GitHub private vulnerability reporting](https://github.com/raster-labs/SwiftJXL/security/advisories/new). Private reporting was verified enabled for this repository on 4 November 2026. Reports go to repository maintainers; a GitHub account is required. Do not post exploitable payloads, credentials or patient information in a public issue. If the form is unavailable, ask a maintainer through an established private channel to restore access before sending sensitive details.

Include affected version/commit, platform, a minimal safe reproducer, expected/actual behaviour and impact. Use synthetic data where possible. Maintainers triage privately, coordinate a fix and disclosure with the reporter, and publish an advisory when appropriate. Do not assume a fixed acknowledgement, fix or disclosure deadline.

## Supported versions

Security fixes target the latest stable `2.0.x` release (`2.0.0`) and `main`. Older snapshots and predecessor `JXLSwift` releases receive no backport commitment under this repository's policy. Consumers should upgrade to the fixed release identified in any published advisory.

| Version | Security maintenance |
| --- | --- |
| `2.0.x` (latest: `2.0.0`) | Supported for security fixes; upgrade to the latest `2.0.x` release |
| Latest `main` | Reports accepted; fixes developed on `main` |
| Older development snapshots | No backport commitment; update to the latest release or revision |
| Predecessor JXLSwift releases | Outside this repository's maintenance policy |

## Threat model

Treat every compressed image, metadata field, interchange header and caller-supplied descriptor as untrusted. Attackers may attempt out-of-bounds access, integer overflow, decompression bombs, pathological entropy work, deeply nested containers, unbounded tasks/caches, malformed colour profiles, unsafe external references or leakage of previous frame memory. Core codecs do not access the network, spawn reference codecs or interpret embedded code.

Enforce the resource, deadline and ownership rules in the common contracts before allocating and while processing. Check slice indices and offset bases. Bound metadata, frame/component/tile counts and parse depth. Reject unsupported essential features. Do not use assertions/preconditions to validate hostile input. Do not emit success after partial decode or cancellation.

Use synthetic fixtures and sanitised diagnostics. Do not log raw images, patient fields, full filesystem paths or memory addresses by default. Initialise exported padding and prevent pool reuse while readers remain. Use scoped filesystem operations only in the CLI; reject detached input references/URLs in the initial stream profile. Atomic final-output publication and overwrite checks must not become path traversal or symlink vulnerabilities.

## Required verification

Run parser/descriptor mutation tests, bounded fuzzing, address/race checks on supported environments and allocation/cancellation stress. Record and fix crash/hang seeds. Review unsafe bridges and native kernels. Check third-party development tools/dependencies and pin reproducible versions. No unresolved severe memory-safety, data-corruption or input-triggered denial-of-service finding is acceptable at stable release.

Correctness and security gates cannot be waived by a benchmark improvement. See `Documentation/TESTING.md` and `Documentation/PERFORMANCE.md` for evidence requirements.
