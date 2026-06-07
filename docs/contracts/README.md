# Wrangle contracts

The durable interface contracts other components and adopters depend on. Each
doc is a tight list of **invariants**, and every invariant points at the test or
lint that enforces it — or is flagged `⚠ prose load-bearing` where nothing
mechanical does yet (those `⚠` are the enforcement backlog).

Detail loads here on demand; [`../SPEC.md`](../SPEC.md) stays the map. Rationale
("why we chose this") lives in SPEC.md §Design Decisions, not here — a contract
states the rule, not its history.

| Contract | What depends on it |
|---|---|
| [adapter.md](adapter.md) | scan tools in the adapter pattern (`tools/<name>/adapter.sh`) |
| [install_script.md](install_script.md) | tools that download a binary (`tools/<name>/install.sh`) |
| [verification.md](verification.md) | the cross-cutting integrity ladder every download passes |
| [orchestrator.md](orchestrator.md) | `run.sh` — tool-name validation, isolation, timeouts, exit codes |
| [composite_action.md](composite_action.md) | adopters calling `actions/scan` (copy-paste interface) |
| [reusable_workflow.md](reusable_workflow.md) | adopters calling the reusable workflows |
| [triggers.md](triggers.md) | `actions/preflight_guard` — the trigger-safety refusals |
| [metadata.md](metadata.md) | the on-disk `metadata/<type>/<shortname>/` layout adopters read |

## Maintaining these

A change to a component's behavior updates its contract doc in the same PR —
keeping them in sync is part of landing the change, not a follow-up. When you add
or move an invariant, update its `→ enforced by:` pointer too; a pointer to a
test that no longer asserts the rule is worse than no pointer.

Writing these surfaced ~15 places where the old monolithic `SPEC.md` prose had
silently drifted from the code (stale tool lists, files that no longer exist, an
env-isolation description weaker than the actual deny-all). The format earns its
keep by making that drift visible: an invariant with no honest `→ enforced by:`
pointer is a question, not a statement.
