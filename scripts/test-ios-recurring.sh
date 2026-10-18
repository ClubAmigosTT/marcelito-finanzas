#!/bin/bash
set -euo pipefail
recurring_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
recurring_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/marcelito-recurring.XXXXXX")"
trap 'rm -rf "$recurring_test_dir"' EXIT
recurring_developer_dir="$(xcode-select -p)"
recurring_platform_dir="$recurring_developer_dir/Platforms/MacOSX.platform/Developer"
cat > "$recurring_test_dir/main.swift" <<'SWIFT'
import Foundation
import XCTest
let suite = XCTestSuite(forTestCaseClass: RecurringPatternTests.self)
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { fatalError("No recurrence tests discovered") }
print("Executed", run.executionCount, "failures", run.totalFailureCount)
exit(run.totalFailureCount == 0 ? 0 : 1)
SWIFT
cd "$recurring_repo_root"
swiftc -module-cache-path "$recurring_test_dir/cache" \
    -I "$recurring_platform_dir/usr/lib" -L "$recurring_platform_dir/usr/lib" -lXCTestSwiftSupport \
    -F "$recurring_platform_dir/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$recurring_platform_dir/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$recurring_platform_dir/usr/lib" \
    apps/ios/Cauce/RecurringPattern.swift apps/ios/Tests/RecurringPatternTests.swift \
    "$recurring_test_dir/main.swift" -o "$recurring_test_dir/recurring-tests"
"$recurring_test_dir/recurring-tests"
