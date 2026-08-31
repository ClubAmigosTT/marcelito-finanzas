#!/usr/bin/env bash
set -euo pipefail

corpus_dir="${1:-${MARCELITO_PDF_CORPUS_DIR:-}}"
if [[ -z "$corpus_dir" || ! -d "$corpus_dir" ]]; then
  echo "Uso: MARCELITO_PDF_CORPUS_DIR=/ruta/a/estados ./scripts/run-native-corpus.sh" >&2
  exit 2
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

echo "NATIVE_CORPUS_RESULT_BUNDLE=$result_bundle"
echo "NATIVE_CORPUS_LOG=$log_file"
