# fixtures

Consumed by tests/test_build_kernel.sh (Task 4) via
`build-kernel.sh --patch-only --fake-source-tree <mini-tree> --patches-dir <dir>`.
Fixture trees are never mutated by the tests: the build copies mini-tree
into a temp dir first.

- `mini-tree/` — hello.c plus a debian/debian.env (`DEBIAN=debian.master`)
  and a one-entry debian.master/changelog, mirroring the two files the
  real build touches.
- `good-patches/` — full 3/3 context, applies at `--fuzz=0`.
- `fuzz-patches/` — same change with the outermost (last) context line
  altered; fails at `--fuzz=0`, applies from fuzz=1 up. These hunks have
  asymmetric context (2 leading / 4 trailing lines), and the altered line
  is the trailing outermost one. That asymmetry is an artifact of placing
  the insertion near the top of hello.c, not a general property of GNU
  patch: patch's leading-side fuzz allowance is `fuzz + prefix_context -
  context`, while trailing context is what it trims first. With true
  3/3-context hunks GNU patch trims both ends symmetrically, so either
  end's outermost line altered behaves the same at fuzz=0/1.
- `reject-patches/` — target line absent; fails at any fuzz, leaves a .rej.

Note: quilt prints its "with fuzz" diagnostics and writes rejects to
stdout, so failure tests must capture stdout. Each patch dir also carries
a `series` file so the dir can be used directly as QUILT_PATCHES.
