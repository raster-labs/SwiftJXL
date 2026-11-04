# Security policy and implementation requirements

Status: development migration; release qualification is incomplete. No successor binary release exists and no vulnerability response time is promised here.

## Reporting

Use the repository's private vulnerability reporting option in its Security tab if it is enabled. Otherwise use an established private channel to a Raster-Lab organisation owner to arrange disclosure. Do not post exploitable payloads, credentials or patient information in a public issue. This document does not assert that GitHub private reporting or a dedicated security mailbox has already been configured.

Include affected version/commit, platform, a minimal safe reproducer, expected/actual behaviour and impact. Use synthetic data where possible. A maintainer must establish the reporting channel and supported-version policy before the first stable release.

## Threat model

Treat every compressed image, metadata field, interchange header and caller-supplied descriptor as untrusted. Attackers may attempt out-of-bounds access, integer overflow, decompression bombs, pathological entropy work, deeply nested containers, unbounded tasks/caches, malformed colour profiles, unsafe external references or leakage of previous frame memory. Core codecs do not access the network, spawn reference codecs or interpret embedded code.

Enforce the resource, deadline and ownership rules in the common contracts before allocating and while processing. Check slice indices and offset bases. Bound metadata, frame/component/tile counts and parse depth. Reject unsupported essential features. Do not use assertions/preconditions to validate hostile input. Do not emit success after partial decode or cancellation.

Use synthetic fixtures and sanitised diagnostics. Do not log raw images, patient fields, full filesystem paths or memory addresses by default. Initialise exported padding and prevent pool reuse while readers remain. Use scoped filesystem operations only in the CLI; reject detached input references/URLs in the initial stream profile. Atomic final-output publication and overwrite checks must not become path traversal or symlink vulnerabilities.

## Required verification

Run parser/descriptor mutation tests, bounded fuzzing, address/race checks on supported environments and allocation/cancellation stress. Record and fix crash/hang seeds. Review unsafe bridges and native kernels. Check third-party development tools/dependencies and pin reproducible versions. No unresolved severe memory-safety, data-corruption or input-triggered denial-of-service finding is acceptable at stable release.

Correctness and security gates cannot be waived by a benchmark improvement. See `Documentation/TESTING.md` and `Documentation/PERFORMANCE.md` for evidence requirements.
