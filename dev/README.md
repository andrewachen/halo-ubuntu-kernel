# dev/

Local development helpers that are NOT part of the CI pipeline.

- `test-in-docker.sh` runs the full test suite inside a pre-baked
  `halo-dev:<series>.<bake>` toolchain container — the local twin of the CI
  test job, for hosts that lack the tooling (e.g. quilt) the suite needs.
  CI is the authoritative gate; this is a convenience, and it only accepts
  `noble`, matching CI's test container.

The toolchain images are baked outside the repo from a machine-local recipe
(cached upstream source trees, local base-image tags), so a fresh machine
cannot recreate them from this repo alone. No private material goes into
them — the recipe only installs the build-dependency toolchain on top of the
public source. On a machine that has the images, resolution is automatic —
the newest local `halo-dev:<series>.<bake>` tag wins; CI remains the
authoritative pass/fail regardless of what a local image contains. To pin an
image explicitly (or record it for other scripts), write `dev/images.env`
(git-ignored):

```
IMAGE_NOBLE=halo-dev:noble.4
IMAGE_RESOLUTE=halo-dev:resolute.1
```
