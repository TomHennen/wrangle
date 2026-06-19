# Threat coverage

This page maps wrangle's controls to real software supply-chain incidents and
shows, honestly, where each control would and would *not* have helped.

It is **illustrative, not exhaustive, and not a guarantee.** wrangle is a
proof-of-concept with no external security review (see the
[FAQ](FAQ.md#doesnt-depending-on-wrangle-just-add-another-supply-chain-risk)).
Most of the incidents below chained more than one weakness; wrangle would have
broken several of them at more than one point, but a single control is never a
promise of immunity.

## How to read this

Controls fall into three strengths, and the table says which applies:

- **Prevents** — wrangle structurally removes the vector in the build and
  release path it runs (e.g. it never uses `pull_request_target`).
- **Warns** — wrangle surfaces the problem but can't stop it, because it lives
  in code wrangle doesn't control (e.g. zizmor flags an unpinned action in
  *your* other workflows).
- **Detects** — wrangle catches it only after the wider community has, e.g.
  once a malicious version reaches a vulnerability database.

Read each row's **Limit** before trusting it — that's where the row's real
scope lives.

## Coverage

| wrangle control | Strength | Incident(s) it maps to | How it would have helped | Limit |
|---|---|---|---|---|
| Never uses `pull_request_target`; zizmor flags it | Prevents / Warns | [Ultralytics](https://blog.pypi.org/posts/2024-12-11-ultralytics-attack-analysis/) and [Mini Shai-Hulud](https://www.akamai.com/blog/security-research/mini-shai-hulud-worm-returns-goes-public) (entry vector); pwn-requests such as [microsoft/symphony](https://www.praetorian.com/blog/pwn-request-hacking-microsoft-github-repositories-and-more/) and [spotipy](https://github.com/advisories/GHSA-h25v-8c87-rvm8) | Removes the "run untrusted PR code with a write token and secrets" entry point both worms used to get a foothold | Governs only the workflow that calls wrangle. zizmor warns about `pull_request_target` and expression injection in your other workflows, but cannot block them. |
| SHA-pins its own actions; ships its reusable workflow as an immutable tag; zizmor flags unpinned `uses:` | Prevents / Warns | [tj-actions/changed-files](https://github.com/advisories/GHSA-mrrh-fwg8-r2c3) (CVE-2025-30066); [reviewdog/action-setup](https://github.com/advisories/GHSA-qmg3-hpqr-gqvc) (CVE-2025-30154) | When an attacker moves a version tag to malicious code, a pinned consumer pulls nothing new | Protects the pin *you* set, to a commit reviewed *before* the attack. zizmor warns on unpinned actions in your workflows, but you have to act on it. |
| Cache-free release builds | Prevents | Cache poisoning in [Ultralytics](https://blog.pypi.org/posts/2024-12-11-ultralytics-attack-analysis/), [Mini Shai-Hulud](https://www.akamai.com/blog/security-research/mini-shai-hulud-worm-returns-goes-public), and [Angular's dev-infra](https://adnanthekhan.com/posts/angular-compromise-through-dev-infra/) | wrangle disables the shared caches (GitHub Actions, BuildKit, uv, setup-go) on release builds, so a cache poisoned by a lower-trust run can't reach the attested artifact | This is wrangle disabling caches, not the platform providing isolation: GitHub Actions caches don't meet SLSA's "Isolated" requirement on their own. PR and dev builds still cache (but produce no attested artifact). GitHub-hosted runners only, via wrangle's reusable workflows. |
| Trusted publishing with legacy token uploads disabled | Prevents | [Ledger connect-kit](https://www.ledger.com/blog/security-incident-report), [chalk/debug phishing](https://www.aikido.dev/blog/npm-debug-and-chalk-packages-compromised), [Shai-Hulud](https://www.cisa.gov/news-events/alerts/2025/09/23/widespread-supply-chain-compromise-impacting-npm-ecosystem), [eslint-scope](https://eslint.org/blog/2018/07/postmortem-for-malicious-package-publishes/), [ua-parser-js](https://github.com/advisories/GHSA-pjwm-rvh2-c87w); the direct-token stage of [Ultralytics](https://blog.pypi.org/posts/2024-12-11-ultralytics-attack-analysis/) | Short-lived OIDC credentials mean there's no standing token to phish, leak, or reuse to publish | Removes the *standing* credential, not in-job theft: code running in the publish job can still exfiltrate the short-lived OIDC token at runtime (as Mini Shai-Hulud did). You must remove the legacy token path, which the templates walk you through; npm's first publish of a package still needs a token. |
| SBOM (Syft / BuildKit) + OSV scan + dependency-review | Detects | Known-malicious or known-vulnerable dependency versions | Fails the build when a dependency matches a known advisory | **Reactive**: it only fires after public disclosure. It won't catch a compromise inside its live window, or one no one has reported yet. |

## What wrangle does not stop

A coverage table that only lists wins isn't honest. These are real attack
classes wrangle does little or nothing against:

- **Maintainer social engineering** — [XZ Utils](https://nvd.nist.gov/vuln/detail/CVE-2024-3094)
  (CVE-2024-3094). An attacker spent years earning a burned-out maintainer's
  trust, then committed a backdoor. No CI/CD control stops a change made by a
  trusted maintainer through the normal process.
- **Typosquatting and dependency confusion** — [W4SP](https://thehackernews.com/2022/11/researchers-uncover-29-malicious-pypi.html),
  [torchtriton](https://pytorch.org/blog/compromised-nightly-dependency/). These
  target what *you choose to install*, not how your artifact is built and
  released. OSV may flag a name once it's reported, but wrangle hardens your
  build and release path, not your dependency selection.
- **A compromise of wrangle itself.** Adopting wrangle means trusting it, like
  any action you depend on. Immutable release tags bound that trust, but they
  don't turn a proof-of-concept into something to put under a production
  release.
