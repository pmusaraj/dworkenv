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

Run these commands from a **Discourse checkout or worktree**, not from the
dworkenv repository:

```sh
dworkenv up
dworkenv exec -- bin/rspec spec/lib/slug_spec.rb
dworkenv url
dworkenv stop
```

The first `up` or `exec` creates a container, installs dependencies, and migrates
its development and test databases. `up` also starts `bin/dev`, waits for an HTTP
response, and prints the preview URL. On OrbStack this is the stable, port-free
`https://<container-name>.orb.local` address. On other runtimes it is a localhost
URL with a free host port assigned by Docker.
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

For browser tests, install the browsers and their system dependencies once:

```sh
dworkenv exec -- pnpm playwright-install
dworkenv exec -- sudo pnpm exec playwright install-deps chromium
```

Parallel RSpec workers additionally need `RAILS_ENV=test bin/rake parallel:create
parallel:migrate`. Plugin migrations may need an explicit migration command.

## Lifecycle and isolation

Each environment is identified by a hash of its canonical checkout path. It has
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
Git metadata is mounted read-only so build tools can inspect it; commit and
branch operations belong on the host. This is development-environment isolation,
not an agent security sandbox.

The launcher uses the image named in `.devcontainer/devcontainer.json`, but calls
Docker directly. It does not interpret the rest of the Dev Containers format.
`DWORKENV_IMAGE` overrides the image for a newly created container. Existing
containers retain their original image until destroyed and recreated.

The prototype requires a local Docker daemon and supports the repository's
standard package layout. It does not configure external plugin symlinks, mail
preview, remote Docker hosts, idle shutdown, or automatic administrator creation.

## Harness integration

Any tool with shell access can run the same commands. For example, these optional
entries in `paseo.json` expose explicit start and stop actions:

```json
{
  "scripts": {
    "preview": { "command": "dworkenv up" },
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
> `dworkenv exec -- ...`. Start previews with `dworkenv up` and report the URL.
> Run these commands from the session's Discourse worktree. Stop the environment
> with `dworkenv stop` when finished; destroy it only when its data is no longer
> needed.

## Compatibility with the original workenv prototype

The command retains the `discourse-workenv-` container/volume names,
`org.discourse.workenv.path` label, `tmp/workenv` lock, and in-container service
and setup-marker paths. This lets it reuse existing environments and URLs.
`WORKENV_IMAGE` remains accepted as a fallback; `DWORKENV_IMAGE` takes precedence.

## Development

The implementation is a standalone Ruby script using the standard library and
Docker CLI. Keep process arguments as arrays and preserve child exit codes.

```sh
ruby -c bin/dworkenv
bin/dworkenv --help
```

For integration checks, invoke the script by absolute path from disposable
Discourse worktrees. Verify two previews and focused tests, independent data,
stop/restart persistence, simultaneous startup, and command argument/exit-code
preservation. Test HTTPS with certificate verification enabled on OrbStack.
