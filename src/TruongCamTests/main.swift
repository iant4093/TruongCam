import Foundation

// Standalone entry point for the local logic verifier.
//
// Compiled only by `scripts/verify-logic.sh` with `-D TC_TESTKIT_STANDALONE`
// together with the platform-independent app sources. It runs the exact same
// registered suites that the XCTest target runs, prints every check, and exits
// non-zero if any case fails.

#if TC_TESTKIT_STANDALONE

/// Diagnostic sink for the standalone runner. Writes to stderr, which is
/// unbuffered, so a hang or crash still shows where it happened.
func tcLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
func log(_ message: String) { tcLog(message) }



let arguments = Array(CommandLine.arguments.dropFirst())
var filter: String?
var listOnly = false
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--filter":
        if index + 1 < arguments.count { filter = arguments[index + 1]; index += 1 }
        else {
            FileHandle.standardError.write(Data("--filter requires a value\n".utf8))
            exit(2)
        }
    case "--list":
        listOnly = true
    default:
        FileHandle.standardError.write(Data("unknown argument: \(arguments[index])\n".utf8))
        exit(2)
    }
    index += 1
}

let suites = TruongCamTestSuites.all

if listOnly {
    for suite in suites {
        print("\(suite.id)  \(suite.title)")
        for testCase in suite.cases {
            print("  \(testCase.id)  [\(testCase.evidence.rawValue)]  \(testCase.title)")
        }
    }
    exit(0)
}

var totalCases = 0
var failedCases = 0
var totalChecks = 0
var failedChecks = 0
var failedDetail: [String] = []

let started = Date()

for suite in suites {
    var printedHeader = false
    for testCase in suite.cases {
        if let filter,
           !testCase.id.localizedCaseInsensitiveContains(filter),
           !testCase.title.localizedCaseInsensitiveContains(filter),
           !suite.id.localizedCaseInsensitiveContains(filter) {
            continue
        }
        if !printedHeader {
            print("== \(suite.id)  \(suite.title)")
            printedHeader = true
        }
        let recorder = TCRecorder()
        await testCase.body(recorder)
        let checks = recorder.checks
        totalCases += 1
        totalChecks += checks.count
        let failures = recorder.failures
        failedChecks += failures.count
        if failures.isEmpty {
            print("  PASS \(testCase.id)  \(testCase.title)  (\(checks.count) checks)")
        } else {
            failedCases += 1
            print("  FAIL \(testCase.id)  \(testCase.title)")
            for failure in failures {
                print("       - \(failure.name): \(failure.detail)")
                failedDetail.append("\(suite.id)/\(testCase.id) \(failure.name): \(failure.detail)")
            }
        }
    }
}

let elapsed = Date().timeIntervalSince(started)
guard totalCases > 0, totalChecks > 0 else {
    print("RESULT: FAIL (no test cases/checks executed; check the filter and suite registration)")
    fflush(stdout)
    exit(2)
}
print("")
print(String(format: "cases: %d run, %d failed", totalCases, failedCases))
print(String(format: "checks: %d run, %d failed", totalChecks, failedChecks))
print(String(format: "elapsed: %.3fs", elapsed))
print("evidence class: \(TCEvidenceClass.localHarness.rawValue)")
// The reason device acceptance is NOT_RUN is that it was never EXECUTED here,
// not an inventory claim. This text previously asserted "no connected iPhone",
// which contradicted the actual device list (a paired iPhone was available) and
// was simply a hardcoded string. LOCAL_HARNESS proves logic only.
print("device-dependent acceptance: NOT_RUN (no device session was executed in this run)")
print("evidence boundary: this binary proves logic/state machines only; iPhone camera")
print("capability, RAW resolution, provider retention and signing are device gates D01-D11.")
print(failedCases == 0 ? "RESULT: PASS" : "RESULT: FAIL")

// Terminate with an explicit status rather than returning from the top level.
// Structured-concurrency tasks spawned by the channel tests may still be
// suspended on an unbounded stream, and a top-level return would wait for the
// runtime to drain them; the verification result is already complete here.
fflush(stdout)
exit(failedCases == 0 ? 0 : 1)

#endif
