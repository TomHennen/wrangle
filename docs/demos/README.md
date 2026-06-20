# Demos

Terminal-recording sources for the GIFs shown in wrangle's docs. These are a
maintainer/contributor aid, not part of CI or wrangle's supply chain — the
committed GIF is the reviewed artifact, and regeneration is a manual step.

| Demo | Source | Rendered output | Shown in |
|---|---|---|---|
| VSA verification (consumer `ampel verify`) | `vsa_verification.tape` + `vsa_verify_demo.sh` | `../../assets/images/vsa_verification.gif` | [`docs/verifying_artifacts.md`](../verifying_artifacts.md) |

The `.tape` types a real consumer command; the output is staged by the
companion `*_demo.sh` (symlinked in as the named tool during rendering), so the
GIF is illustrative — the command, policy locator, collector, and checks mirror
the build-type READMEs, but no live verification runs.

## Rendering

Requires [VHS](https://github.com/charmbracelet/vhs) and its runtime
dependencies `ttyd` and `ffmpeg`. VHS drives headless Chromium, which refuses
to run as root — render as a non-root user.

```bash
cd docs/demos
vhs vsa_verification.tape   # writes ../../assets/images/vsa_verification.gif
```

Rendered images live in `assets/images/` alongside the other doc screenshots;
each `.tape` sets its own `Output` path there.
