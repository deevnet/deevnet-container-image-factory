# deevnet-container-image-factory

Builds container images **from source** for software the substrate runs but does not write.

## Why this exists, and why it is not somewhere else

The estate already had two ways to get software onto a host, and neither fits.

| | What it does | Why not this |
|---|---|---|
| `deevnet-image-factory` | Bakes **OS** images with Packer — Raspberry Pi `.img` files and Proxmox VM templates | A different build system, a different artifact and a different cadence. An OS image is a machine you clone; a container image is a service you run. |
| `ansible-collection-deevnet.builder`, role `artifacts` | **Pulls** an upstream container image and `podman save`s it — minio, postgres, pdns-auth, the Omada controller | It pulls. It cannot help when the upstream binary is one we may not use. |

This factory is for the third case: **software whose source we may use but whose binaries we may
not.** The build recipe is then the artifact, and it needs a commit history of its own — because
the upstream version alone no longer says which image is running.

VerneMQ is the first case of it and the reason this repo exists (ADR-0012 §8). Its 2.2.0 release
notes state: *"VerneMQ binary software distribution packages and Docker images are covered by the
VerneMQ EULA."* The source is Apache-2.0. So we compile it.

## Layout

```
images/<name>/
  Containerfile    the build, taking ARG VERSION
  version          the upstream release to build, one line
```

Adding an image means adding that directory. The Makefile discovers it.

## Use

```bash
make list                      # what this factory can build, and at which version
make image IMAGE=vernemq       # podman build
make stage IMAGE=vernemq       # build, then save under the artifact root (sudo)
```

`make stage` writes `/srv/deevnet-http/container-images/<name>/<name>-<version>.tar` and a
`<name>-latest.tar` symlink, which is the layout `podman_service` reads.

**Images are pushed, not pulled.** Platform and IoT Backend have no route back to the artifact
server under the zone policy, so an Ansible role copies the tarball to the host and loads it there.
Staging only puts it where the control node can find it.

## Provenance

`make stage` refuses a dirty or untracked tree.

The version in `images/<name>/version` is **upstream's**, not a tag of this repository, so it does
not identify the recipe. The factory commit does, and every image carries it as
`org.opencontainers.image.revision`:

```bash
podman inspect localhost/deevnet-vernemq:2.2.0 \
  --format '{{index .Labels "org.opencontainers.image.revision"}}'
```

That is the answer to "which commit produced the broker that is running".

## Upgrading an image

Change `images/<name>/version`, commit, `make stage`, then bump the version the Ansible role pins
and deploy. The old tarball stays on the artifact server, so a rollback is a version bump back.
