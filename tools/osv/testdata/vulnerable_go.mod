module example.com/wrangle/osv-e2e-fixture

// Fixture for the opt-in osv-scanner e2e test in tools/osv/test.bats.
// Pins a known-vulnerable, frozen package version so osv-scanner always
// reports at least one advisory under network access — the CVE-2021-3121
// disclosure against github.com/gogo/protobuf <1.3.2. Anchoring on a
// dependency (rather than relying on Go stdlib advisories that shift
// across releases) keeps the e2e assertion deterministic.
go 1.20

require github.com/gogo/protobuf v1.3.1
