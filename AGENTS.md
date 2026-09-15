# Contributor guide

- This repository contains a standalone Ruby CLI for Discourse development environments.
- The target Discourse checkout is determined by the caller's working directory, never the executable's location.
- Use Ruby's standard library and invoke Docker/Git with argument arrays; preserve executed command exit codes.
- Preserve existing environment identifiers and volume labels unless implementing an explicit migration. Renaming the CLI must not orphan data.
- Keep startup lazy and reusable. Stop retains data; destroy explicitly deletes environment data.
- Agents and Git writes stay on the host. Container mounts isolate dependencies and runtime data per worktree.
- Update README.md for command, setup, or lifecycle changes.
- Run `ruby -c bin/dworkenv` and `bin/dworkenv --help` after edits. Verify behavior changes with a disposable Discourse worktree and a local Docker runtime.
- Do not run environment lifecycle commands from this repository; run them from the target Discourse checkout.
