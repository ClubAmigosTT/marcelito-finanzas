#!/usr/bin/env bash
set -euo pipefail

corpus_dir="${1:-${MARCELITO_PDF_CORPUS_DIR:-}}"
if [[ -z "$corpus_dir" || ! -d "$corpus_dir" ]]; then
  echo "Uso: MARCELITO_PDF_CORPUS_DIR=/ruta/a/estados ./scripts/run-native-corpus.sh" >&2
  exit 2
fi
corpus_dir="$(cd "$corpus_dir" && pwd)"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$script_dir"

# A real/private corpus can provide its own golden manifest without placing
# financial documents in the repository.  Resolve it before xcodebuild so the
# XCTest process receives an absolute path regardless of its working folder.
if [[ -n "${MARCELITO_PDF_CORPUS_MANIFEST:-}" ]]; then
  manifest_input="$MARCELITO_PDF_CORPUS_MANIFEST"
  if [[ "$manifest_input" != /* ]]; then
    manifest_input="$repo_root/$manifest_input"
  fi
  if [[ ! -f "$manifest_input" ]]; then
    echo "No se encontró el manifiesto privado del corpus: $manifest_input" >&2
    exit 2
  fi
  export MARCELITO_PDF_CORPUS_MANIFEST="$(cd "$(dirname "$manifest_input")" && pwd)/$(basename "$manifest_input")"
  echo "Manifiesto privado: $MARCELITO_PDF_CORPUS_MANIFEST"
fi

verify_enabled=0
manifest_path=""
if [[ "${MARCELITO_PDF_CORPUS_VERIFY:-}" =~ ^(1|true|yes)$ ]]; then
  verify_enabled=1
  manifest_path="${MARCELITO_PDF_CORPUS_MANIFEST:-$repo_root/tests/fixtures/pdf-corpus-attachments.json}"
  if [[ "$manifest_path" != /* ]]; then
    manifest_path="$repo_root/$manifest_path"
  fi
  if [[ ! -f "$manifest_path" ]]; then
    echo "No se encontró el manifiesto del corpus: $manifest_path" >&2
    exit 2
  fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Falta xcodegen. Instálalo con: brew install xcodegen" >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Este runner requiere macOS y xcodebuild." >&2
  exit 2
fi

xcodegen generate --spec project.yml

destination="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print "platform=iOS Simulator,id=" $2; exit}')"
if [[ -z "$destination" ]]; then
  echo "No hay un simulador iPhone disponible." >&2
  exit 2
fi

result_dir="$(mktemp -d "${TMPDIR:-/tmp}/marcelito-native-corpus.XXXXXX")"
result_bundle="$result_dir/MarcelitoCorpus.xcresult"
log_file="$result_dir/xcodebuild.log"

echo "Corpus: $corpus_dir"
echo "Destino: $destination"
echo "Resultados: $result_dir"

set +e
MARCELITO_PDF_CORPUS_DIR="$corpus_dir" \
  xcodebuild \
    -project Marcelito.xcodeproj \
    -scheme Marcelito \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$result_dir/DerivedData" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    test 2>&1 | tee "$log_file"
xcode_status="${PIPESTATUS[0]}"
set -e

verify_status=0
if [[ "$verify_enabled" -eq 1 ]]; then
  if ! command -v node >/dev/null 2>&1; then
    echo "No se encontró Node.js; no se pudo validar NATIVE_CORPUS_REPORT." >&2
    verify_status=2
  else
    reader_version="$(sed -n 's/.*static let readerVersion = "\([^"]*\)".*/\1/p' "$repo_root/apps/ios/Cauce/Models.swift" | head -n 1)"
    verify_args=(
      "$repo_root/scripts/verify-native-corpus-report.ts"
      --log "$log_file"
      --manifest "$manifest_path"
    )
    if [[ -n "$reader_version" ]]; then
      verify_args+=(--reader-version "$reader_version")
    fi
    if [[ "${MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED:-}" =~ ^(1|true|yes)$ ]]; then
      verify_args+=(--require-certified)
    fi
    echo "Validando informe nativo contra $manifest_path"
    set +e
    node --experimental-strip-types "${verify_args[@]}"
    verify_status="$?"
    set -e
  fi
fi

echo "NATIVE_CORPUS_RESULT_BUNDLE=$result_bundle"
echo "NATIVE_CORPUS_LOG=$log_file"
if [[ "$xcode_status" -ne 0 ]]; then
  echo "xcodebuild terminó con código $xcode_status." >&2
fi
if [[ "$verify_status" -ne 0 ]]; then
  echo "La verificación nativa terminó con código $verify_status." >&2
fi
if [[ "$xcode_status" -ne 0 ]]; then
  exit "$xcode_status"
fi
exit "$verify_status"
