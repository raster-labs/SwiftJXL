# Contributing

Start with `AGENTS.md` and `IMPLEMENTATION.md`. This repository has a Milestone 1 API/storage implementation; codec implementation remains staged. Keep pull requests focused and preserve independent package consumption. Application maintainers should use [MIGRATION.md](MIGRATION.md); update its mappings and runnable example when changing public APIs or capability status.

Every behavioural change needs relevant unit/regression tests. Parser or ownership changes need the matching security/lifetime checks; hot-path changes need controlled benchmark evidence. Public common API changes require the same contract revision in all four repositories and updated example/conformance tests. Codec-specific exceptions need an explicit reason.

New in-house contributions use MIT with SPDX identifier MIT where appropriate. Preserve accurate authorship and provenance. Declare third-party source/fixture/tool origins and licences; no unreviewed code import. Do not add private clinical data or secrets. British English is preferred for documentation.

PR descriptions state the problem, resulting behaviour, contract/source revisions, tests actually run, missing environments, memory/copy implications and measured performance where relevant. Do not copy predecessor success counts as successor evidence. Follow `SECURITY.md` for sensitive reports.
