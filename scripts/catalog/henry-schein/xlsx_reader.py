"""Small, dependency-free XLSX reader for deterministic catalog imports.

It intentionally supports only the value types used by the Henry Schein source
workbooks. Formula cells and Excel error cells are rejected instead of being
silently coerced.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import re
from typing import Any
from xml.etree import ElementTree as ET
from zipfile import ZipFile


MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"


@dataclass(frozen=True)
class XlsxRecord:
    sheet_name: str
    row_number: int
    values: dict[str, Any]


class XlsxWorkbook:
    def __init__(self, path: Path) -> None:
        self.path = path
        with ZipFile(path) as archive:
            self._shared_strings = self._read_shared_strings(archive)
            self._sheet_paths = self._read_sheet_paths(archive)

    @property
    def sheet_names(self) -> list[str]:
        return list(self._sheet_paths)

    def read_table(self, sheet_name: str) -> list[XlsxRecord]:
        rows = self.read_rows(sheet_name)
        if not rows:
            raise ValueError(f"Sheet {sheet_name!r} is empty in {self.path}")

        header_row_number, header_values = rows[0]
        headers: list[str] = []
        for value in header_values:
            if value is None:
                raise ValueError(
                    f"Blank header in {sheet_name!r} row {header_row_number}"
                )
            header = str(value)
            if header in headers:
                raise ValueError(f"Duplicate header {header!r} in {sheet_name!r}")
            headers.append(header)

        records: list[XlsxRecord] = []
        for row_number, values in rows[1:]:
            padded = values + [None] * (len(headers) - len(values))
            if any(value is not None for value in padded[: len(headers)]):
                records.append(
                    XlsxRecord(
                        sheet_name=sheet_name,
                        row_number=row_number,
                        values=dict(zip(headers, padded[: len(headers)])),
                    )
                )
        return records

    def read_rows(self, sheet_name: str) -> list[tuple[int, list[Any]]]:
        try:
            sheet_path = self._sheet_paths[sheet_name]
        except KeyError as exc:
            raise ValueError(
                f"Missing sheet {sheet_name!r} in {self.path.name}"
            ) from exc

        with ZipFile(self.path) as archive:
            root = ET.parse(archive.open(sheet_path)).getroot()

        result: list[tuple[int, list[Any]]] = []
        for row in root.findall(f".//{{{MAIN_NS}}}row"):
            row_number = int(row.attrib.get("r", len(result) + 1))
            values_by_column: dict[int, Any] = {}
            for cell in row.findall(f"{{{MAIN_NS}}}c"):
                reference = cell.attrib.get("r", "A1")
                column_index = self._column_index(reference)
                values_by_column[column_index] = self._cell_value(cell)
            if not values_by_column:
                continue
            width = max(values_by_column) + 1
            values = [values_by_column.get(index) for index in range(width)]
            if any(value is not None for value in values):
                result.append((row_number, values))
        return result

    def _cell_value(self, cell: ET.Element) -> Any:
        formula = cell.find(f"{{{MAIN_NS}}}f")
        if formula is not None:
            raise ValueError(
                f"Formula cell encountered in {self.path.name}; source must be values-only"
            )

        cell_type = cell.attrib.get("t")
        if cell_type == "inlineStr":
            return "".join(
                text.text or "" for text in cell.findall(f".//{{{MAIN_NS}}}t")
            )

        value_node = cell.find(f"{{{MAIN_NS}}}v")
        if value_node is None or value_node.text is None:
            return None
        raw_value = value_node.text

        if cell_type == "s":
            return self._shared_strings[int(raw_value)]
        if cell_type == "b":
            return raw_value == "1"
        if cell_type in {"str", "d"}:
            return raw_value
        if cell_type == "e":
            raise ValueError(
                f"Excel error cell {raw_value!r} encountered in {self.path.name}"
            )
        try:
            if re.fullmatch(r"[-+]?\d+", raw_value):
                return int(raw_value)
            return float(raw_value)
        except ValueError:
            return raw_value

    @staticmethod
    def _column_index(reference: str) -> int:
        match = re.match(r"([A-Z]+)", reference)
        if not match:
            raise ValueError(f"Invalid XLSX cell reference: {reference!r}")
        index = 0
        for character in match.group(1):
            index = index * 26 + (ord(character) - ord("A") + 1)
        return index - 1

    @staticmethod
    def _read_shared_strings(archive: ZipFile) -> list[str]:
        if "xl/sharedStrings.xml" not in archive.namelist():
            return []
        root = ET.parse(archive.open("xl/sharedStrings.xml")).getroot()
        return [
            "".join(text.text or "" for text in item.findall(f".//{{{MAIN_NS}}}t"))
            for item in root.findall(f"{{{MAIN_NS}}}si")
        ]

    @staticmethod
    def _read_sheet_paths(archive: ZipFile) -> dict[str, str]:
        workbook = ET.parse(archive.open("xl/workbook.xml")).getroot()
        relationships = ET.parse(
            archive.open("xl/_rels/workbook.xml.rels")
        ).getroot()
        relationship_targets = {
            relationship.attrib["Id"]: relationship.attrib["Target"]
            for relationship in relationships.findall(f"{{{PKG_REL_NS}}}Relationship")
        }

        paths: dict[str, str] = {}
        for sheet in workbook.findall(f".//{{{MAIN_NS}}}sheet"):
            name = sheet.attrib["name"]
            relationship_id = sheet.attrib[f"{{{REL_NS}}}id"]
            target = relationship_targets[relationship_id]
            if target.startswith("/"):
                path = target.lstrip("/")
            else:
                path = str(PurePosixPath("xl") / target)
            paths[name] = str(PurePosixPath(path))
        return paths
