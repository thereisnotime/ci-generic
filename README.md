# ci-generic

A batteries-included [GitHub Actions runner](https://github.com/actions/runner)
image for [ARC](https://github.com/actions/actions-runner-controller) scale sets
running **without** `containerMode`.

```
ghcr.io/thereisnotime/ci-generic:latest
```

## What is in it

| | Version |
|---|---|
| actions/runner | 2.337.0 |
| Go | 1.27.1 |
| Node | 24.21.0 (LTS) |
| Python | 3.12 (noble) |
| PostgreSQL | 16 (noble), server + client |
| Terraform | 1.16.3 |
| OpenTofu | 1.12.6 |
| OpenBao | 2.6.2 |
| plus | build-essential, git, openssh-client, jq, curl, wget, zip/unzip, rsync, sudo |

`sudo` is NOPASSWD, so a workflow can install anything else it needs without
waiting for a new image:

```yaml
- run: sudo apt-get update && sudo apt-get install -y <pkg>
```

## What is deliberately NOT in it

**No Docker CLI, no buildx, no compose, no container hooks.** This image targets a
scale set in plain mode: there is no dind sidecar for a CLI to talk to and no
`containerMode: kubernetes` hooks to invoke. If you need those, you want a
different image.

## Replacing `services:`

Jobs that used a `services:` container cannot work without a Docker daemon.
Start a local PostgreSQL instead:

```yaml
    steps:
      - name: start postgres
        run: |
          sudo pg_ctlcluster 16 main start
          sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"
          sudo -u postgres createdb app_test
      # DATABASE_URL=postgres://postgres:postgres@localhost:5432/app_test
```

Each job runs in its own ephemeral pod, so the database is as isolated as a
service container was.

## Why the toolchains are baked in

The opposite choice — a minimal image plus `setup-go`/`setup-node` per job — is
defensible and keeps the image ~700MB. It costs 30-60s per job, because an
ephemeral runner starts with an empty toolcache every time.

This image trades size for that time. Containerd caches it per node, so the
~2.5GB is paid once per node per tag, not per job.

## Runner version

GitHub stops queueing jobs to a runner roughly 30 days after a newer release
ships, and ARC registers with `DisableUpdate=true`, so this image never
self-updates. The `# renovate:` annotations in the Dockerfile are what keep it
inside that window — do not remove them. The weekly scheduled build also picks
up base-image security updates.
