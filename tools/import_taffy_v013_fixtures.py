#!/usr/bin/env python3
"""Import the enabled Taffy v0.13.0 HTML fixtures into normalized JSON."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

PINNED_COMMIT = "45a56299d366ddb383e593a1f0372158d00e8530"
UPSTREAM_REPOSITORY = "https://github.com/DioxusLabs/taffy"
UPSTREAM_TAG = "v0.13.0"
GENERATOR = "tools/import_taffy_v013_fixtures.py"
GENERATOR_VERSION = 1
FIXTURE_ROOT_NAME = "test_fixtures"
XML_ROOT_NAME = "tests/xml"
VARIANTS = (
    "border_box_ltr",
    "content_box_ltr",
    "border_box_rtl",
    "content_box_rtl",
)
DEFAULT_VIEWPORT = (800.0, 600.0)


class ImportError(RuntimeError):
    """Raised when a source checkout does not satisfy the importer contract."""


def fail(message: str) -> ImportError:
    return ImportError(message)


def verify_revision(source: Path) -> None:
    try:
        result = subprocess.run(
            ["git", "-C", os.fspath(source), "rev-parse", "--verify", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise fail(f"cannot invoke git for {source}: {exc}") from exc
    if result.returncode != 0:
        raise fail(f"source is not a Git checkout: {source}")
    revision = result.stdout.strip()
    if revision != PINNED_COMMIT:
        raise fail(
            f"source HEAD {revision!r} does not match pinned Taffy commit "
            f"{PINNED_COMMIT}"
        )
    try:
        status = subprocess.run(
            [
                "git",
                "-C",
                os.fspath(source),
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                FIXTURE_ROOT_NAME,
                XML_ROOT_NAME,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise fail(f"cannot inspect source checkout {source}: {exc}") from exc
    if status.returncode != 0:
        raise fail(f"cannot inspect source checkout: {source}")
    if status.stdout.strip():
        raise fail(
            "source has modified inputs under "
            f"{FIXTURE_ROOT_NAME} or {XML_ROOT_NAME}"
        )


def discover_fixtures(source: Path) -> list[tuple[str, Path]]:
    root = source / FIXTURE_ROOT_NAME
    if not root.is_dir():
        raise fail(f"missing fixture directory: {root}")

    paths: list[Path] = []
    for directory, directory_names, file_names in os.walk(root, topdown=True):
        directory_names[:] = sorted(
            (name for name in directory_names if name != "_scratch"),
            key=lambda name: os.fsencode(name),
        )
        for name in sorted(file_names, key=lambda value: os.fsencode(value)):
            if name.startswith("x") or not name.endswith(".html"):
                continue
            path = Path(directory) / name
            if path.is_file():
                paths.append(path)

    paths.sort(key=lambda path: os.fsencode(path.relative_to(source).as_posix()))
    fixtures: list[tuple[str, Path]] = []
    for path in paths:
        relative = path.relative_to(source).as_posix()
        fixtures.append((relative, path))
    return fixtures


def source_sha256(path: Path) -> str:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise fail(f"cannot read fixture {path}: {exc}") from exc
    return hashlib.sha256(data).hexdigest()


def parse_number(value: str, *, path: Path, attribute: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise fail(f"invalid {attribute}={value!r} in {path}") from exc
    if not math.isfinite(number):
        raise fail(f"non-finite {attribute} in {path}")
    return number


def parse_viewport(root: ET.Element, path: Path) -> dict[str, float]:
    viewport = root.find("./viewport")
    if viewport is None:
        raise fail(f"missing viewport in {path}")

    values: list[float] = []
    for attribute, fallback in zip(("width", "height"), DEFAULT_VIEWPORT):
        raw_value = viewport.get(attribute)
        if raw_value is None:
            values.append(fallback)
        elif raw_value in {"auto", "min-content", "max-content"}:
            values.append(fallback)
        else:
            values.append(parse_number(raw_value, path=path, attribute=attribute))
    return {"width": values[0], "height": values[1]}


def parse_rounding(root: ET.Element, path: Path) -> bool:
    raw_value = root.get("use-rounding", "true")
    if raw_value == "true":
        return True
    if raw_value == "false":
        return False
    raise fail(f"invalid use-rounding={raw_value!r} in {path}")


def parse_expected(element: ET.Element, path: Path) -> dict[str, float | None]:
    if element.tag != "node":
        raise fail(f"expected node element in {path}")
    required = ("x", "y", "width", "height")
    result: dict[str, float | None] = {
        attribute: parse_number(element.get(attribute, ""), path=path, attribute=attribute)
        for attribute in required
    }
    for attribute in ("scroll_width", "scroll_height"):
        raw_value = element.get(attribute)
        result[attribute] = (
            None
            if raw_value is None
            else parse_number(raw_value, path=path, attribute=attribute)
        )
    return result


def style_value(element: ET.Element, attribute: str) -> str:
    return element.get(attribute, "0px")


def normalize_node(
    input_element: ET.Element,
    expected_element: ET.Element,
    path: Path,
) -> tuple[list[dict[str, object]], list[dict[str, float | None]]]:
    input_children = list(input_element)
    expected_children = list(expected_element)
    if len(input_children) != len(expected_children):
        raise fail(f"input/expectation tree mismatch in {path}")

    kind = "text" if input_element.tag == "text" else input_element.tag
    node: dict[str, object] = {
        "kind": kind,
        "child_count": len(input_children),
        "style": {
            "direction": input_element.get("direction", "ltr"),
            "border_top": style_value(input_element, "border-top"),
            "border_right": style_value(input_element, "border-right"),
            "border_bottom": style_value(input_element, "border-bottom"),
            "border_left": style_value(input_element, "border-left"),
        },
    }
    text = (input_element.text or "").strip()
    if text:
        node["text"] = text
    writing_mode = input_element.get("writing-mode")
    if writing_mode:
        node["writing_mode"] = writing_mode

    nodes = [node]
    expected = [parse_expected(expected_element, path)]
    for child, expected_child in zip(input_children, expected_children):
        child_nodes, child_expected = normalize_node(child, expected_child, path)
        nodes.extend(child_nodes)
        expected.extend(child_expected)
    return nodes, expected


def parse_xml_case(
    source: Path,
    fixture_relative: str,
    source_digest: str,
    variant: str,
) -> dict[str, object]:
    fixture_path = Path(fixture_relative)
    relative_without_root = fixture_path.relative_to(FIXTURE_ROOT_NAME)
    xml_relative = relative_without_root.with_name(
        f"{relative_without_root.stem}__{variant}.xml"
    )
    xml_path = source / XML_ROOT_NAME / xml_relative
    if not xml_path.is_file():
        raise fail(f"missing generated XML fixture: {xml_path}")

    try:
        root = ET.parse(xml_path).getroot()
    except (ET.ParseError, OSError) as exc:
        raise fail(f"invalid XML fixture {xml_path}: {exc}") from exc
    if root.tag != "test":
        raise fail(f"invalid XML root in {xml_path}")

    input_root = root.find("./input/*")
    expected_root = root.find("./expectations/*")
    if input_root is None or expected_root is None:
        raise fail(f"missing input or expectations in {xml_path}")
    nodes, expected = normalize_node(input_root, expected_root, xml_path)

    source_id = fixture_relative.removeprefix(f"{FIXTURE_ROOT_NAME}/")
    return {
        "id": source_id,
        "source": fixture_relative,
        "source_sha256": source_digest,
        "variant": variant,
        "grid_feature": fixture_path.stem.startswith("grid"),
        "use_rounding": parse_rounding(root, xml_path),
        "viewport": parse_viewport(root, xml_path),
        "nodes": nodes,
        "expected": expected,
    }


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(value, temporary, ensure_ascii=False, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def import_fixtures(
    source: Path,
    output: Path,
    *,
    fixture: str | None = None,
    variant: str | None = None,
) -> None:
    source = source.resolve()
    output = output.resolve()
    verify_revision(source)
    fixtures = discover_fixtures(source)

    if fixture is None or variant is None:
        if fixture is not None or variant is not None:
            raise fail("--fixture and --variant must be provided together")
        selected_fixtures = fixtures
        selected_variants = VARIANTS
        selection = None
    else:
        if variant not in VARIANTS:
            raise fail(f"invalid fixture variant: {variant!r}")
        selected_fixture = next(
            (candidate for candidate in fixtures if candidate[0] == fixture),
            None,
        )
        if selected_fixture is None:
            raise fail(f"fixture is not enabled or does not exist: {fixture}")
        selected_fixtures = [selected_fixture]
        selected_variants = (variant,)
        selection = {"source": fixture, "variant": variant}

    sources: list[dict[str, str]] = []
    cases: list[dict[str, object]] = []
    seen_keys: set[tuple[str, str]] = set()
    for relative, path in selected_fixtures:
        digest = source_sha256(path)
        sources.append({"path": relative, "sha256": digest})
        for selected_variant in selected_variants:
            key = (relative, selected_variant)
            if key in seen_keys:
                raise fail(
                    f"duplicate fixture variant: {relative} / {selected_variant}"
                )
            seen_keys.add(key)
            cases.append(
                parse_xml_case(source, relative, digest, selected_variant)
            )

    normalized = {"schema": 1, "cases": cases}
    manifest = {
        "schema": 1,
        "upstream_repository": UPSTREAM_REPOSITORY,
        "upstream_tag": UPSTREAM_TAG,
        "upstream_commit": PINNED_COMMIT,
        "generator": GENERATOR,
        "generator_version": GENERATOR_VERSION,
        "source_count": len(sources),
        "case_count": len(cases),
        "sources": sources,
    }
    if selection is not None:
        manifest["selection"] = selection
    write_json(output / "normalized" / "cases.json", normalized)
    write_json(output / "MANIFEST.json", manifest)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--fixture")
    parser.add_argument("--variant", choices=VARIANTS)
    arguments = parser.parse_args(argv)
    if (arguments.fixture is None) != (arguments.variant is None):
        parser.error("--fixture and --variant must be provided together")
    return arguments


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        import_fixtures(
            arguments.source,
            arguments.out,
            fixture=arguments.fixture,
            variant=arguments.variant,
        )
    except ImportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
