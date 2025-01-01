{
    _type: "https://in-toto.io/Statement/v1",
    subject: [{
        uri: "\($subjectRepo)/commit/\($subjectCommit)",
        digest: {gitCommit: $subjectCommit},
        annotations: {source_branches: [$subjectBranch]}
    }],
    predicateType: "https://slsa.dev/verification_summary/v1",
    predicate: {
        verifier: {
            id: "https://github.com/TomHennen/wrangle/slsa_source_verifier",
        },
        timeVerified: $timeVerified,
        resourceUri: "git+\($subjectRepo)",
        policy: {
            uri: "https://github.com/TomHennen/wrangle/source/tools/slsa_vsa",
        },
        verificationResult: "PASSED",
        verifiedLevels: ["SLSA_SOURCE_LEVEL_1"]
    }
}
