# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`deevnet-container-image-factory` builds container images **from source** for third-party software
the substrate runs. It is the sibling of `deevnet-image-factory`, which bakes OS images with
Packer; this bakes service images with podman.

It exists for one specific case: software whose **source** we may use but whose **binaries** we may
not. Anything that can simply be pulled belongs in the builder collection's `artifacts` role
(`artifacts_podman_images`) instead, which is where minio, postgres, pdns-auth and the Omada
controller come from. Don't move those here.

## Commands

```bash
make list                   # images and their upstream versions
make image IMAGE=<name>     # podman build
make stage IMAGE=<name>     # build, then save under /srv/deevnet-http/container-images/<name> (sudo)
```

## Rules that are easy to get wrong

- **The version file holds UPSTREAM's version, not this repo's.** So it does not identify the
  recipe. `make stage` refuses a dirty tree and stamps the factory commit into
  `org.opencontainers.image.revision`, and that label is how a running image is traced back.
- **Base images are fully qualified** (`docker.io/library/...`). Podman refuses short names
  non-interactively, which is every build here.
- **The image carries no site configuration.** Config is templated from inventory by the Ansible
  role and mounted in (ADR-0009: inventory owns configuration). Do not bake a config file or an
  entrypoint script that reads `DOCKER_*` environment variables — that is a convention of
  upstream's own images, not of the software.
- **Verify licence claims against the release, not against memory.** This repo exists because of a
  licensing distinction, so the reasoning is recorded in each Containerfile's header with the
  upstream wording it rests on. Re-check it when bumping a version.
- **Runtime and build bases must share an ABI.** The releases here carry compiled NIFs. Check what
  the build image is `FROM` before choosing the runtime base.

## Images

| Image | Why from source |
|---|---|
| `vernemq` | ADR-0012 §8. Upstream's 2.2.0 release notes: *"VerneMQ binary software distribution packages and Docker images are covered by the VerneMQ EULA."* The source is Apache-2.0. |
