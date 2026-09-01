"""
report_views.py — Small, focused widgets for browsing each artifact that
cpp_inspector.pl produces, without pulling in QtWebEngine or any other
heavy dependency.
"""
from __future__ import annotations

import csv
import json
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QFontDatabase
from PySide6.QtWidgets import (
    QHeaderView,
    QLabel,
    QPlainTextEdit,
    QScrollArea,
    QTableWidget,
    QTableWidgetItem,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

try:
    from PySide6.QtSvgWidgets import QSvgWidget
    HAS_SVG = True
except ImportError:  # QtSvgWidgets ships separately on some distros
    HAS_SVG = False


class TextReportView(QPlainTextEdit):
    """Renders cpp_relationships.txt verbatim, in a monospace font."""

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setReadOnly(True)
        self.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        # QFont("A, B, C") is NOT a font-fallback list — it's a single
        # (invalid) family name, which can make text resolve to a glyph-less
        # fallback font on some Linux/fontconfig setups (renders blank).
        # QFontDatabase's system fixed-pitch font is guaranteed valid.
        self.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))

    def load(self, path: Path) -> None:
        try:
            self.setPlainText(path.read_text(encoding="utf-8", errors="replace"))
        except OSError as exc:
            self.setPlainText(f"[!] Could not read {path}: {exc}")


class CsvReportView(QTableWidget):
    """Renders cpp_relationships.csv (callee,caller,file,line) as a table."""

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.setAlternatingRowColors(True)
        self.setSortingEnabled(True)

    def load(self, path: Path) -> None:
        self.clear()
        self.setRowCount(0)
        self.setColumnCount(0)
        try:
            with path.open(newline="", encoding="utf-8", errors="replace") as fh:
                rows = list(csv.reader(fh))
        except OSError as exc:
            self.setColumnCount(1)
            self.setRowCount(1)
            self.setHorizontalHeaderLabels(["Error"])
            self.setItem(0, 0, QTableWidgetItem(f"Could not read {path}: {exc}"))
            return

        if not rows:
            return

        header, *body = rows
        self.setColumnCount(len(header))
        self.setHorizontalHeaderLabels(header)
        self.setRowCount(len(body))
        for r, row in enumerate(body):
            for c, value in enumerate(row):
                self.setItem(r, c, QTableWidgetItem(value))
        self.resizeColumnsToContents()


class JsonReportView(QTreeWidget):
    """Renders cpp_relationships.json as a collapsible tree."""

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setHeaderLabels(["Key", "Value"])
        self.setColumnCount(2)
        # ResizeToContents (rather than a one-off resizeColumnToContents()
        # call at load time) keeps sizing correct even though this tab is
        # hidden the moment its content is populated — resizeColumnToContents
        # on a still-hidden widget can compute a 0px column on some
        # platforms/styles, making every row look empty until interacted with.
        header = self.header()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)

    def load(self, path: Path) -> None:
        self.clear()
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, json.JSONDecodeError) as exc:
            QTreeWidgetItem(self, ["Error", str(exc)])
            return
        self._populate(self.invisibleRootItem(), data)
        self.expandToDepth(1)

    def _populate(self, parent_item: QTreeWidgetItem, value) -> None:
        if isinstance(value, dict):
            for key, sub_value in value.items():
                self._add_node(parent_item, str(key), sub_value)
        elif isinstance(value, list):
            for index, sub_value in enumerate(value):
                self._add_node(parent_item, f"[{index}]", sub_value)
        else:
            parent_item.setText(1, self._scalar_text(value))

    def _add_node(self, parent_item: QTreeWidgetItem, label: str, value) -> None:
        item = QTreeWidgetItem(parent_item, [label])
        if isinstance(value, (dict, list)):
            count = len(value)
            item.setText(1, f"{{{count} items}}" if isinstance(value, dict) else f"[{count} items]")
            self._populate(item, value)
        else:
            item.setText(1, self._scalar_text(value))

    @staticmethod
    def _scalar_text(value) -> str:
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)


class SvgGraphView(QScrollArea):
    """Renders cpp_call_graph.svg. Falls back to a message if QtSvgWidgets
    isn't installed (it ships in the `PySide6-Addons` wheel)."""

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setWidgetResizable(True)
        self._svg_widget = None

        if HAS_SVG:
            self._svg_widget = QSvgWidget()
            self.setWidget(self._svg_widget)
        else:
            placeholder = QLabel(
                "QtSvgWidgets is not available.\n"
                "Install it with: pip install PySide6-Addons\n"
                "(or open the .svg file directly in a browser)."
            )
            placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
            self.setWidget(placeholder)

    def load(self, path: Path) -> None:
        if self._svg_widget is None:
            return
        self._svg_widget.load(str(path))
        # sizeHint() reflects the widget's *current* layout geometry, which
        # is unreliable while this tab is hidden (e.g. right after a run
        # finishes, before the user clicks the tab) — it can come back as
        # 0x0 or the QScrollArea's viewport size, making the SVG render
        # stretched/misaligned relative to its actual background/viewBox.
        # renderer().defaultSize() reads the size straight from the SVG
        # document itself, so it's correct regardless of widget visibility.
        native_size = self._svg_widget.renderer().defaultSize()
        if native_size.isValid() and native_size.width() > 0 and native_size.height() > 0:
            self._svg_widget.setFixedSize(native_size)


def build_report_tabs() -> dict[str, QWidget]:
    """Convenience factory used by MainWindow to build all four tabs at once."""
    return {
        "txt": TextReportView(),
        "csv": CsvReportView(),
        "json": JsonReportView(),
        "svg": SvgGraphView(),
    }
