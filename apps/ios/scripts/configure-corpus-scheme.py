"""Forward private corpus settings to XCTest without committing them."""
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

KEYS = (
    "MARCELITO_PDF_CORPUS_DIR",
    "MARCELITO_PDF_CORPUS_MANIFEST",
    "MARCELITO_PDF_ROW_MANIFEST",
    "MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED",
    "MARCELITO_PDF_CORPUS_EXPORT_PRIVATE_DIAGNOSTICS",
    "MARCELITO_PDF_CORPUS_PRIVATE_EXPORT",
    "MARCELITO_PDF_CORPUS_IMPORT_PRIVATE_EXPORT",
)


def configure(path, environ):
    tree = ET.parse(path)
    action = tree.getroot().find("TestAction")
    if action is None:
        raise ValueError("The generated scheme has no TestAction")
    action.set("shouldUseLaunchSchemeArgsEnv", "NO")
    variables = action.find("EnvironmentVariables")
    if variables is None:
        variables = ET.SubElement(action, "EnvironmentVariables")
    for entry in list(variables):
        if entry.get("key") in KEYS:
            variables.remove(entry)
    for key in KEYS:
        value = environ.get(key, "").strip()
        if not value:
            continue
        flag_key = key in {
        "MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED",
        "MARCELITO_PDF_CORPUS_EXPORT_PRIVATE_DIAGNOSTICS",
        }
        if not flag_key and not value.startswith("app-documents://"):
            value = str(Path(value).expanduser().resolve(strict=key not in {
                "MARCELITO_PDF_CORPUS_PRIVATE_EXPORT",
                "MARCELITO_PDF_CORPUS_IMPORT_PRIVATE_EXPORT",
            }))
        ET.SubElement(variables, "EnvironmentVariable", {
            "key": key, "value": value, "isEnabled": "YES",
        })
    tree.write(path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    configure(sys.argv[1], os.environ)
