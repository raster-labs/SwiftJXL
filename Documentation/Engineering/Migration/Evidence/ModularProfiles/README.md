# Modular profile qualification evidence

Synthetic fixtures and new harness source are Apache-2.0, like the repository.
See qualification.json and the adjacent engineering note for scope and limitations.

The archive contains final and initial run logs, xUnit results, source hashes,
native streams, independent PAM decodes, memory observations and harness source.
Initial failures are retained; their reports describe the executed source hashes.
The initial counter missed argument-case starts; the aggregate report recounts them.

Exact commands and environment are in each run report. Paths are host-specific:
adapt repo, work, scratch and oracle paths before reproducing. Tests are the
repository's ModularProfileTests and ModularProfileLifetimeTests. Set
SWIFTJXL_ORACLE_BIN to a directory containing djxl to require independent decoding.
SWIFTJXL_ORACLE_OUTPUT preserves those outputs. No oracle executable is in the archive.

The ordinary memory probe links the PR30 core library whose current source and
library hashes are in memory-build-final.json. The prior core build manifest and
build script are included for rebuilding; adapt their paths and select this report's
base revision. Existing libraries/executables and build caches are not archived.
memory.py and validate.py reused previous-run command manifests during this run;
the fully resolved commands are retained in their reports.

manifest.json hashes every archived entry except itself. SHA-256 of the complete
archive is in archive.json alongside it. This archive is evidence, not a portable
one-command benchmark package or a production readiness claim.
