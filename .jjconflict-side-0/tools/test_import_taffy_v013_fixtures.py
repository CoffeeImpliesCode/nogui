from __future__ import annotations

import importlib.util
import hashlib
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

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CHECKED_IN_CORPUS = REPOSITORY_ROOT / "testdata" / "taffy-v0.13.0"

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

    def test_import_vendors_exact_sources_and_prunes_only_previously_managed_files(
        self,
    ) -> None:
        source_bytes = b"<!doctype html>\r\n<div id=\"test-root\">exact bytes</div>\r\n"
        (self.source / FIXTURE_SOURCE).write_bytes(source_bytes)

        stale_relative = "test_fixtures/leaf/removed.html"
        stale_path = self.output / "upstream" / stale_relative
        stale_path.parent.mkdir(parents=True)
        stale_path.write_bytes(b"obsolete")
        unrelated_path = self.output / "upstream" / "local-note.txt"
        unrelated_path.write_bytes(b"keep")
        (self.output / "MANIFEST.json").write_text(
            json.dumps(
                {
                    "sources": [
                        {
                            "path": stale_relative,
                            "sha256": hashlib.sha256(b"obsolete").hexdigest(),
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

        self._run_import()

        vendored_path = self.output / "upstream" / FIXTURE_SOURCE
        self.assertEqual(vendored_path.read_bytes(), source_bytes)
        self.assertFalse(stale_path.exists())
        self.assertEqual(unrelated_path.read_bytes(), b"keep")
        manifest = self._read_json("MANIFEST.json")
        self.assertEqual(
            manifest["sources"],
            [
                {
                    "path": FIXTURE_SOURCE,
                    "sha256": hashlib.sha256(source_bytes).hexdigest(),
                }
            ],
        )

    def test_checked_in_upstream_sources_match_pinned_manifest(self) -> None:
        manifest = json.loads(
            (CHECKED_IN_CORPUS / "MANIFEST.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["upstream_commit"], importer.PINNED_COMMIT)
        self.assertEqual(manifest["source_count"], 1381)

        sources = manifest["sources"]
        self.assertIsInstance(sources, list)
        manifest_paths = [source["path"] for source in sources]
        self.assertEqual(len(manifest_paths), manifest["source_count"])
        self.assertEqual(len(set(manifest_paths)), manifest["source_count"])
        self.assertEqual(
            manifest_paths,
            sorted(manifest_paths, key=lambda path: path.encode()),
        )

        upstream = CHECKED_IN_CORPUS / "upstream"
        vendored_paths = sorted(
            (
                path.relative_to(upstream).as_posix()
                for path in upstream.rglob("*")
                if path.is_file()
            ),
            key=lambda path: path.encode(),
        )
        self.assertEqual(vendored_paths, manifest_paths)
        for source in sources:
            with self.subTest(path=source["path"]):
                digest = hashlib.sha256(
                    (upstream / source["path"]).read_bytes()
                ).hexdigest()
                self.assertEqual(digest, source["sha256"])

    def test_parse_number_accepts_px_and_rejects_other_units(self) -> None:
        path = Path("fixture.xml")
        self.assertEqual(
            importer.parse_number("400px", path=path, attribute="width"),
            400.0,
        )
        with self.assertRaises(importer.ImportError):
            importer.parse_number("2em", path=path, attribute="width")

    def test_import_normalizes_viewport_modes_and_v2_shape(self) -> None:
        viewport_by_variant = {
            "border_box_ltr": (
                "321.5px",
                "240.25px",
                {"width": 321.5, "height": 240.25},
                {"width": "definite", "height": "definite"},
            ),
            "content_box_ltr": (
                "min-content",
                "max-content",
                {"width": 800.0, "height": 600.0},
                {"width": "min_content", "height": "max_content"},
            ),
            "border_box_rtl": (
                "max-content",
                "min-content",
                {"width": 800.0, "height": 600.0},
                {"width": "max_content", "height": "min_content"},
            ),
            "content_box_rtl": (
                "640",
                "360",
                {"width": 640.0, "height": 360.0},
                {"width": "definite", "height": "definite"},
            ),
        }
        for variant, (width, height, _, _) in viewport_by_variant.items():
            xml_path = (
                self.source
                / "tests"
                / "xml"
                / "leaf"
                / f"minimal__{variant}.xml"
            )
            xml = xml_path.read_text(encoding="utf-8")
            xml_path.write_text(
                xml.replace(
                    '<viewport width="320" height="240" />',
                    f'<viewport width="{width}" height="{height}" />',
                ),
                encoding="utf-8",
            )

        self._run_import()

        corpus_path = self.output / "normalized" / "cases.json"
        manifest_path = self.output / "MANIFEST.json"
        corpus = self._read_json("normalized/cases.json")
        manifest = self._read_json("MANIFEST.json")
        self.assertEqual(corpus["schema"], 2)
        self.assertEqual(manifest["schema"], 2)
        self.assertEqual(manifest["generator_version"], 2)
        cases = {case["variant"]: case for case in corpus["cases"]}
        for variant, (_, _, expected_viewport, expected_mode) in viewport_by_variant.items():
            self.assertEqual(cases[variant]["viewport"], expected_viewport)
            self.assertEqual(cases[variant]["viewport_mode"], expected_mode)
            for node in cases[variant]["nodes"]:
                self.assertNotIn("style", node)

        first_outputs = (corpus_path.read_bytes(), manifest_path.read_bytes())
        self._run_import()
        self.assertEqual(first_outputs, (corpus_path.read_bytes(), manifest_path.read_bytes()))

    def test_parse_viewport_rejects_auto_without_shared_mode(self) -> None:
        root = importer.ET.fromstring(
            '<test><viewport width="auto" height="100" /></test>'
        )
        with self.assertRaisesRegex(
            importer.ImportError,
            "unsupported viewport width='auto'",
        ):
            importer.parse_viewport(root, Path("fixture.xml"))

    def test_parse_viewport_uses_pinned_max_content_defaults(self) -> None:
        root = importer.ET.fromstring("<test><viewport /></test>")
        viewport, mode = importer.parse_viewport(root, Path("fixture.xml"))
        self.assertEqual(viewport, {"width": 800.0, "height": 600.0})
        self.assertEqual(mode, {"width": "max_content", "height": "max_content"})

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
        self.assertNotIn("style", node)

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
