#!/bin/bash
set -euo pipefail
integrity_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
integrity_dir="$(mktemp -d "${TMPDIR:-/tmp}/marcelito-integrity.XXXXXX")"
trap 'rm -rf "$integrity_dir"' EXIT
cd "$integrity_repo_root"
python3 - "$integrity_dir/main.swift" <<'PY'
from pathlib import Path
import sys
actual = Path('apps/ios/Cauce/FinancialPlanning.swift').read_text().replace('import Observation','').replace('@Observable ', '').replace('@ObservationIgnored ', '')
Path(sys.argv[1]).write_text(Path('tests/fixtures/ios-planning-adapter.swift').read_text()+actual+'\n'+Path('apps/ios/Cauce/PlanningHistory.swift').read_text()+'\n'+Path('tests/fixtures/ios-planning-integrity-scenarios.swift').read_text())
PY
xcrun swiftc -module-cache-path "$integrity_dir/cache" \
    apps/ios/Cauce/RecurringPattern.swift apps/ios/Cauce/LoanModels.swift \
    apps/ios/Cauce/FinanceBackup.swift "$integrity_dir/main.swift" -o "$integrity_dir/integrity"
"$integrity_dir/integrity"
