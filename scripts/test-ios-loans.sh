#!/bin/bash
set -euo pipefail
loan_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
loan_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/marcelito-loans.XXXXXX")"
trap 'rm -rf "$loan_test_dir"' EXIT
loan_developer_dir="$(xcode-select -p)"
loan_platform_dir="$loan_developer_dir/Platforms/MacOSX.platform/Developer"
cat > "$loan_test_dir/main.swift" <<'SWIFT'
import Foundation
import XCTest
let suite = XCTestSuite(forTestCaseClass: LoanBookTests.self)
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { fatalError("No loan tests discovered") }
print("Executed", run.executionCount, "failures", run.totalFailureCount)
exit(run.totalFailureCount == 0 ? 0 : 1)
SWIFT
cd "$loan_repo_root"
swiftc -module-cache-path "$loan_test_dir/cache" \
    -I "$loan_platform_dir/usr/lib" -L "$loan_platform_dir/usr/lib" -lXCTestSwiftSupport \
    -F "$loan_platform_dir/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$loan_platform_dir/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$loan_platform_dir/usr/lib" \
    apps/ios/Cauce/LoanModels.swift apps/ios/Cauce/LoanBook.swift \
    apps/ios/Cauce/LoanPaymentResolver.swift apps/ios/Cauce/ITAMPDFText.swift \
    apps/ios/Cauce/LoanPDFReader.swift apps/ios/Tests/LoanBookTests.swift \
    "$loan_test_dir/main.swift" -o "$loan_test_dir/loan-tests"
"$loan_test_dir/loan-tests"
