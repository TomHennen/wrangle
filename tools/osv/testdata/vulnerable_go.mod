module example.com/wrangle/osv-e2e-fixture

// Intentionally pinned to an older Go toolchain so osv-scanner returns
// non-zero stdlib advisories deterministically. This fixture is consumed
// only by the opt-in osv-scanner e2e test in tools/osv/test.bats — it
// exists to give that test a stable source of "vulnerable input" that
// does not depend on the network state of a particular dependency.
go 1.20
