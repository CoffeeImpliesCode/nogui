from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


IMPORTER_PATH = Path(__file__).with_name("import_taffy_v013_fixtures.py")
IMPORTER_SPEC = importlib.util.spec_from_file_location(
    "nogui_import_taffy_v013_fixtures",
    IMPORTER_PATH,
)
if IMPORTER_SPEC is None or IMPORTER_SPEC.loader is None:
    raise RuntimeError(f"cannot load importer from {IMPORTER_PATH}")
importer = importlib.util.module_from_spec(IMPORTER_SPEC)
IMPORTER_SPEC.loader.exec_module(importer)

FIXTURE_SOURCE = "test_fixtures/leaf/minimal.html"
VARIANTS = (
    "border_box_ltr",
    "content_box_ltr",
    "border_box_rtl",
    "content_box_rtl",
)


class ImportTaffyFixturesTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)

        self.root = Path(temporary.name)
        self.source = self.root / "taffy"
        self.output = self.root / "output"
        self._write_source_tree()

    def _write_source_tree(self) -> None:
        fixture_path = self.source / FIXTURE_SOURCE
        fixture_path.parent.mkdir(parents=True)
        fixture_path.write_text(
            "<!doctype html><div id=\"test-root\"></div>\n",
            encoding="utf-8",
        )

        xml_directory = self.source / "tests" / "xml" / "leaf"
        xml_directory.mkdir(parents=True)
        for width, variant in enumerate(VARIANTS, start=1):
            xml = f"""\
<test use-rounding="true">
  <viewport width="320" height="240" />
  <input>
    <node direction="ltr" />
  </input>
  <expectations>
    <node x="0" y="0" width="{width}" height="1" />
  </expectations>
</test>
"""
            (xml_directory / f"minimal__{variant}.xml").write_text(
                xml,
                encoding="utf-8",
            )

    def _run_import(self, *selection: str) -> None:
        arguments = [
            "--source",
            str(self.source),
            "--out",
            str(self.output),
            *selection,
        ]
        with mock.patch.object(importer, "verify_revision"):
            self.assertEqual(importer.main(arguments), 0)

    def _read_json(self, relative_path: str) -> dict[str, object]:
        return json.loads((self.output / relative_path).read_text(encoding="utf-8"))

    def test_parse_number_accepts_px_and_rejects_other_units(self) -> None:
        path = Path("fixture.xml")
        self.assertEqual(
            importer.parse_number("400px", path=path, attribute="width"),
            400.0,
        )
        with self.assertRaises(importer.ImportError):
            importer.parse_number("2em", path=path, attribute="width")

    def test_import_preserves_all_xml_input_attributes(self) -> None:
        variant = "border_box_ltr"
        xml_path = (
            self.source
            / "tests"
            / "xml"
            / "leaf"
            / f"minimal__{variant}.xml"
        )
        xml_path.write_text(
            """\
<test use-rounding="true">
  <viewport width="800" height="600" />
  <input>
    <node
      overflow="hidden"
      data-layout-case="verbatim-token"
      width="400px"
      display="grid"
      writing-mode="vertical-rl"
      height="50%"
      border-top="3px"
      grid-template-columns="12px minmax(0, 1fr)"
      direction="rtl"
    />
  </input>
  <expectations>
    <node x="0" y="0" width="400px" height="300px" />
  </expectations>
</test>
""",
            encoding="utf-8",
        )

        self._run_import(
            "--fixture",
            FIXTURE_SOURCE,
            "--variant",
            variant,
        )

        corpus = self._read_json("normalized/cases.json")
        node = corpus["cases"][0]["nodes"][0]
        self.assertEqual(
            node["attributes"],
            {
                "border-top": "3px",
                "data-layout-case": "verbatim-token",
                "direction": "rtl",
                "display": "grid",
                "grid-template-columns": "12px minmax(0, 1fr)",
                "height": "50%",
                "overflow": "hidden",
                "width": "400px",
                "writing-mode": "vertical-rl",
            },
        )
        self.assertEqual(node["kind"], "node")
        self.assertEqual(node["child_count"], 0)
        self.assertEqual(node["writing_mode"], "vertical-rl")
        self.assertEqual(
            node["style"],
            {
                "direction": "rtl",
                "border_top": "3px",
                "border_right": "0px",
                "border_bottom": "0px",
                "border_left": "0px",
            },
        )

    def test_seed_import_records_explicit_fixture_and_variant_selection(self) -> None:
        selected_variant = "border_box_ltr"

        self._run_import(
            "--fixture",
            FIXTURE_SOURCE,
            "--variant",
            selected_variant,
        )

        corpus = self._read_json("normalized/cases.json")
        manifest = self._read_json("MANIFEST.json")
        cases = corpus["cases"]
        self.assertIsInstance(cases, list)
        self.assertEqual(len(cases), 1)
        self.assertEqual(cases[0]["source"], FIXTURE_SOURCE)
        self.assertEqual(cases[0]["variant"], selected_variant)
        self.assertEqual(manifest["case_count"], 1)
        self.assertEqual(
            manifest["selection"],
            {"source": FIXTURE_SOURCE, "variant": selected_variant},
        )

    def test_full_import_writes_all_four_variants_without_selection(self) -> None:
        self._run_import()

        corpus = self._read_json("normalized/cases.json")
        manifest = self._read_json("MANIFEST.json")
        cases = corpus["cases"]
        self.assertIsInstance(cases, list)
        self.assertEqual(len(cases), 4)
        self.assertCountEqual(
            (case["variant"] for case in cases),
            VARIANTS,
        )
        self.assertEqual({case["source"] for case in cases}, {FIXTURE_SOURCE})
        self.assertEqual(manifest["case_count"], 4)
        self.assertNotIn("selection", manifest)

    def test_verify_revision_rejects_dirty_consumed_inputs(self) -> None:
        consumed_paths = (
            FIXTURE_SOURCE,
            "tests/xml/leaf/minimal__border_box_ltr.xml",
        )

        for dirty_path in consumed_paths:
            with self.subTest(dirty_path=dirty_path):
                def git_run(
                    command: list[str],
                    *args: object,
                    **kwargs: object,
                ) -> subprocess.CompletedProcess[str]:
                    del args, kwargs
                    if "rev-parse" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            f"{importer.PINNED_COMMIT}\n",
                            "",
                        )
                    if "status" in command or "ls-files" in command:
                        return subprocess.CompletedProcess(
                            command,
                            0,
                            f" M {dirty_path}\n",
                            "",
                        )
                    if "diff" in command:
                        return subprocess.CompletedProcess(
                            command,
                            1 if "--quiet" in command else 0,
                            f"{dirty_path}\n",
                            "",
                        )
                    raise AssertionError(f"unexpected Git command: {command!r}")

                with mock.patch.object(
                    importer.subprocess,
                    "run",
                    side_effect=git_run,
                ):
                    with self.assertRaises(importer.ImportError):
                        importer.verify_revision(self.source)


if __name__ == "__main__":
    unittest.main()
