# dworkenv

On-demand Discourse development containers for Git worktrees.

`dworkenv` is a prototype for running Discourse and its tests in a separate
Docker container for each local checkout or Git worktree. Editors and coding
agents stay on the host and edit the mounted source files directly.

## Install

Requirements: Ruby 3.1 or newer, Git, and a running local Docker-compatible
runtime. OrbStack provides HTTPS preview URLs on macOS. No additional Ruby gems
are required by this command.

From the dworkenv repository, add its `bin` directory to your shell's PATH:

```sh
export PATH="$PWD/bin:$PATH"
dworkenv --help
```

For permanent setup, add the resolved `bin` directory to PATH in your shell
configuration. GUI-launched agents may need an absolute executable path if they
do not inherit your shell's PATH.

## Getting started

Run these commands from a **Discourse or plugin checkout/worktree**, not from the
dworkenv repository:

```sh
dworkenv up
dworkenv test spec/models
dworkenv url
dworkenv stop
```

The first `up`, `exec`, `test`, or `qunit` creates a container, installs dependencies, and migrates
its development and test databases. `up` also starts `bin/dev`, waits for an HTTP
response, and prints the preview URL. On OrbStack this is the stable, port-free
`https://<container-name>.orb.local` address. On other runtimes it is a localhost
URL with a free host port assigned by Docker.
New development databases include an active, approved administrator: username
`admin`, password `passwordpassword`, email `admin@localhost.local`. Setup leaves
an existing `admin` account unchanged and does not reset its password on restart.

Subsequent commands reuse the container. Changes to dependency lockfiles or core
migrations trigger setup again. Adding workspace packages requires recreating
the environment so their dependency directories receive separate mounts.

Commands after `exec --` run as the `discourse` user and preserve their exit
status. To set an environment variable, use `env` inside the container:

```sh
dworkenv exec -- env RAILS_ENV=test bin/rake db:migrate
dworkenv exec -- bash
dworkenv exec -- tail -f log/workenv-web.log
```

`test` runs RSpec. Paths are relative to the checkout root; plugin paths are
automatically mapped into Discourse. With no paths, it runs that checkout's
`spec` directory. Put RSpec options after `--`:

```sh
dworkenv test spec/models -- --format documentation
dworkenv test spec/system
dworkenv qunit
dworkenv qunit --filter "Some test name"
```

System specs and `qunit` install Chromium and its system dependencies automatically
and start the development server. `qunit` selects the current plugin's JavaScript
suite, or core when invoked from a Discourse checkout. Additional QUnit arguments
use Discourse's runner syntax and paths relative to the Discourse root.

Parallel RSpec workers additionally need `RAILS_ENV=test bin/rake parallel:create
parallel:migrate` through `exec`.

## Reviewing a plugin PR

Have your harness check out the PR into a Git worktree, then run:

```sh
dworkenv up
dworkenv test spec/models
dworkenv qunit
```

A repository with a top-level `plugin.rb` is detected automatically. Its `# name:`
metadata determines the plugin directory, even when the harness gives its worktree
an unrelated name. Each plugin worktree gets its own downloaded Discourse checkout,
database, dependencies, and preview URL. Plugin edits on the host are visible live
inside Discourse. Dependency changes and plugin migrations trigger setup again.

The managed Discourse checkout starts at `main` and stays pinned to the downloaded
commit. To select another branch, tag, or commit, set `DWORKENV_DISCOURSE_REF` before
first startup. `DWORKENV_DISCOURSE_REPOSITORY` selects a different Git remote.
Changing these variables does not update an existing checkout: run `destroy`
first to recreate it, which also deletes the environment's databases and volumes.

Managed checkouts live under `$XDG_CACHE_HOME/dworkenv`, defaulting to
`~/.cache/dworkenv`. `DWORKENV_CACHE_HOME` overrides that directory; keep its value
consistent across commands for an existing environment.

`exec` always runs from the Discourse root. In plugin environments, `LOAD_PLUGINS=1`
is set and `DWORKENV_PLUGIN_PATH` contains the mounted plugin directory:

```sh
dworkenv exec -- bash -c 'cd "$DWORKENV_PLUGIN_PATH" && pwd'
```

Only the current plugin is mounted automatically. Additional plugin repositories
required by a plugin must be configured separately.

## Lifecycle and isolation

Containers are named `discourse-<branch>`, or `discourse-PR-1234` for branches
such as `pr-1234` or `pull/1234`. Plugin names include the plugin, for example
`discourse-login-PR-123`. Detached worktrees use their directory name. Slashes
and other punctuation become hyphens; a short path hash resolves name collisions.
Startup renames existing containers to match, including after branch changes,
so their OrbStack URLs change with the name.

Each environment is still identified by its canonical checkout path label, and
volume names retain the original path hash. It has
separate PostgreSQL, Redis, gems, browser cache, logs, temporary files, and pnpm
package dependency volumes. Native dependencies stay inside Linux, including
the `node_modules` directories of workspace packages.

`stop` preserves the container and its data. `up` resumes it. Restart after a
change that requires restarting the application. OrbStack URLs stay the same
after restart. On other runtimes the assigned port can change; use `url` to
retrieve it.

OrbStack's "Allow access to container domains & IPs" network setting must be
enabled. The launcher explicitly routes OrbStack's proxy to container port 3000,
allows the container's hostname in Rails, and configures Discourse's public URLs
for HTTPS on port 443. OrbStack handles certificates and TLS; the readiness check
uses its HTTP proxy. See the
[OrbStack domain documentation](https://docs.orbstack.dev/docker/domains).

To remove an environment and **delete its databases and dependency volumes**:

```sh
dworkenv destroy
```

Destroy the environment before removing its worktree. Moving a checkout changes
its identity. Source files are bind-mounted and survive environment destruction.
For plugins, `destroy` also removes the managed Discourse checkout, while retaining
the original plugin checkout. Git metadata is mounted read-only so build tools can inspect it; commit and
branch operations belong on the host. QUnit uses a separate writable Git object
cache when assembling assets. This is development-environment isolation,
not an agent security sandbox.

The launcher uses the image named in `.devcontainer/devcontainer.json`, but calls
Docker directly. It does not interpret the rest of the Dev Containers format.
`DWORKENV_IMAGE` overrides the image for a newly created container. A locally available configured image is
reused if it was built or successfully pulled within the last 48 hours. Otherwise,
Docker pulls that image before creating a container. Pull checks are shared across
worktrees under the cache directory and serialized to avoid duplicate pulls.
Existing containers retain their original image until destroyed and recreated.

The prototype requires a local Docker daemon and supports the repository's
standard package layout and standalone plugin repositories. It does not configure mail
preview, remote Docker hosts, or idle shutdown.

## Harness integration

Any tool with shell access can run the same commands. For example, these optional
entries in `paseo.json` expose explicit start and stop actions:

```json
{
  "scripts": {
    "preview": { "command": "dworkenv up" },
    "test": { "command": "dworkenv test" },
    "qunit": { "command": "dworkenv qunit" },
    "stop-preview": { "command": "dworkenv stop" }
  }
}
```

Startup stays on demand. These are ordinary scripts: the container owns the
long-running processes, and the launcher prints the environment's preview URL.
Paseo's service proxy is not configured by this prototype.

The `dworkenv` executable must be on the Paseo daemon's PATH, or its script
commands must use the absolute executable path. Paseo reads `paseo.json` from the
committed base branch. The dworkenv source itself does not need to be copied into
each Discourse worktree.

A reusable instruction for coding agents:

> Edit files and run Git on the host. Run tests and lint through
> `dworkenv test`, `dworkenv qunit`, or `dworkenv exec -- ...` for other commands.
> Start previews with `dworkenv up` and report the URL.
> Run these commands from the session's Discourse or plugin worktree. Stop the environment
> with `dworkenv stop` when finished; destroy it only when its data is no longer
> needed.

## Compatibility with the original workenv prototype

The command finds existing containers by their `org.discourse.workenv.path`
label and renames them on startup. It retains the `discourse-workenv-` volume
names, `tmp/workenv` lock, and in-container service and setup-marker paths.
Existing data is reused; OrbStack URLs adopt the new container names.
`WORKENV_IMAGE` remains accepted as a fallback; `DWORKENV_IMAGE` takes precedence.

## Development

The implementation is a standalone Ruby script using the standard library and
Docker CLI. Keep process arguments as arrays and preserve child exit codes.

```sh
ruby -c bin/dworkenv
bin/dworkenv --help
ruby test/project_test.rb
```

The regression tests require Minitest (`gem install minitest` if unavailable);
the launcher itself uses only Ruby's standard library. Tests use local Git fixtures
and do not require Docker or network access.

For integration checks, invoke the script by absolute path from disposable
Discourse and plugin worktrees. Verify automatic checkout creation, plugin Ruby
and browser tests, clean host Git status, two previews, independent data,
stop/restart persistence, simultaneous startup, and command argument/exit-code
preservation. Test HTTPS with certificate verification enabled on OrbStack.
