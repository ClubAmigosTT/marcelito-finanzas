import tempfile
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
from importlib.util import spec_from_file_location, module_from_spec

spec = spec_from_file_location("configure", Path(__file__).with_name("configure-corpus-scheme.py"))
module = module_from_spec(spec)
spec.loader.exec_module(module)


class SchemeTests(unittest.TestCase):
    def test_paths_reach_test_host_and_stale_settings_are_removed(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "sample.xcscheme"
            path.write_text('<Scheme><TestAction shouldUseLaunchSchemeArgsEnv="YES">'
                            '<EnvironmentVariables><EnvironmentVariable key="OTHER" value="keep"/>'
                            '<EnvironmentVariable key="MARCELITO_PDF_CORPUS_MANIFEST" value="stale"/>'
                            '</EnvironmentVariables></TestAction></Scheme>')
            values = {"MARCELITO_PDF_CORPUS_DIR": root,
                      "MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED": "1"}
            module.configure(path, values)
            module.configure(path, values)
            action = ET.parse(path).getroot().find("TestAction")
            rows = list(action.find("EnvironmentVariables"))
            self.assertEqual(action.get("shouldUseLaunchSchemeArgsEnv"), "NO")
            self.assertEqual(len(rows), 3)
            env = {row.get("key"): row.get("value") for row in rows}
            self.assertEqual(env["MARCELITO_PDF_CORPUS_DIR"], str(Path(root).resolve()))
            self.assertNotIn("MARCELITO_PDF_CORPUS_MANIFEST", env)
            self.assertEqual(env["OTHER"], "keep")

    def test_missing_path_is_an_error(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "sample.xcscheme"
            path.write_text('<Scheme><TestAction/></Scheme>')
            with self.assertRaises(FileNotFoundError):
                module.configure(path, {"MARCELITO_PDF_ROW_MANIFEST": str(Path(root) / "missing")})


if __name__ == "__main__":
    unittest.main()
