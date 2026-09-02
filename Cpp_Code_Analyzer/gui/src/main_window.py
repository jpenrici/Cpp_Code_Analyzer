"""
main_window.py — The single window that makes up the whole GUI: an
options form on the left, a log + report tabs on the right.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QCheckBox,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QSplitter,
    QStatusBar,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from . import config
from .report_views import build_report_tabs
from .runner import InspectorRunner, RunOptions


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Cpp Inspector GUI")

        self._script_path: Path | None = config.find_inspector_script()
        self._perl_binary: str | None = config.find_perl_binary()
        self._runner: InspectorRunner | None = None

        self._build_ui()
        self._check_environment()

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.addWidget(self._build_form_panel())
        splitter.addWidget(self._build_output_panel())
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([340, 760])

        self.setCentralWidget(splitter)
        self.setStatusBar(QStatusBar())

    def _build_form_panel(self) -> QWidget:
        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setAlignment(Qt.AlignmentFlag.AlignTop)

        # --- Paths -----------------------------------------------------
        paths_box = QGroupBox("Project")
        paths_form = QFormLayout(paths_box)

        self.project_edit = QLineEdit()
        self.project_edit.setPlaceholderText("Path to C/C++ project")
        self.project_edit.textChanged.connect(self._sync_default_output)
        project_row = self._path_row(self.project_edit, self._browse_project)
        paths_form.addRow("Project dir (--in)", project_row)

        self.output_edit = QLineEdit()
        self.output_edit.setPlaceholderText("Where reports will be written")
        output_row = self._path_row(self.output_edit, self._browse_output)
        paths_form.addRow("Output dir (--out)", output_row)

        self.config_dir_edit = QLineEdit()
        self.config_dir_edit.setPlaceholderText("Path to configuration directory")
        config_row = self._path_row(self.config_dir_edit, self._browse_config)
        paths_form.addRow("Config dir (--config)", config_row)

        self.ignore_config_check = QCheckBox("Ignore config.json (--ignore_config)")
        self.ignore_config_check.toggled.connect(
            lambda checked: self.config_dir_edit.setEnabled(not checked)
        )

        layout.addWidget(paths_box)
        layout.addWidget(self.ignore_config_check)

        # --- Symbol kinds ------------------------------------------------
        kinds_box = QGroupBox("Symbol kinds (--kind)")
        kinds_layout = QHBoxLayout(kinds_box)
        self.kind_checks: dict[str, QCheckBox] = {}
        for letter in "fpmc":
            cb = QCheckBox(config.KIND_LABELS[letter])
            cb.setChecked(True)
            self.kind_checks[letter] = cb
            kinds_layout.addWidget(cb)
        layout.addWidget(kinds_box)

        # --- Report formatting flags ------------------------------------
        flags_box = QGroupBox("Report formatting")
        flags_layout = QVBoxLayout(flags_box)
        self.no_label_check = QCheckBox("Hide kind labels (--no_label)")
        self.no_line_check = QCheckBox("Hide line numbers (--no_line)")
        self.no_call_check = QCheckBox('Hide "Called by" sections (--no_call)')
        for cb in (self.no_label_check, self.no_line_check, self.no_call_check):
            flags_layout.addWidget(cb)
        layout.addWidget(flags_box)

        # --- Actions -----------------------------------------------------
        actions_layout = QHBoxLayout()
        self.run_button = QPushButton("▶ Run analysis")
        self.run_button.clicked.connect(self._on_run_clicked)
        self.stop_button = QPushButton("■ Stop")
        self.stop_button.setEnabled(False)
        self.stop_button.clicked.connect(self._on_stop_clicked)
        actions_layout.addWidget(self.run_button)
        actions_layout.addWidget(self.stop_button)
        layout.addLayout(actions_layout)

        self.save_config_button = QPushButton("Save current options to config.json")
        self.save_config_button.clicked.connect(self._on_save_config_clicked)
        layout.addWidget(self.save_config_button)

        # --- Environment status -------------------------------------------
        self.env_label = QLabel()
        self.env_label.setWordWrap(True)
        self.env_label.setStyleSheet("color: #a33;")
        layout.addWidget(self.env_label)

        layout.addStretch(1)
        return panel

    def _path_row(self, edit: QLineEdit, on_browse) -> QWidget:
        row = QWidget()
        row_layout = QHBoxLayout(row)
        row_layout.setContentsMargins(0, 0, 0, 0)
        browse_button = QPushButton("Browse…")
        browse_button.clicked.connect(on_browse)
        row_layout.addWidget(edit)
        row_layout.addWidget(browse_button)
        return row

    def _build_output_panel(self) -> QWidget:
        self.tabs = QTabWidget()

        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.tabs.addTab(self.log_view, "Log")

        self.report_widgets = build_report_tabs()
        self.tabs.addTab(self.report_widgets["txt"], "Text report")
        self.tabs.addTab(self.report_widgets["csv"], "CSV")
        self.tabs.addTab(self.report_widgets["json"], "JSON")
        self.tabs.addTab(self.report_widgets["svg"], "Call graph (SVG)")

        container = QWidget()
        layout = QVBoxLayout(container)
        layout.addWidget(self.tabs)

        bottom_actions = QHBoxLayout()
        self.open_output_button = QPushButton("Open output folder")
        self.open_output_button.clicked.connect(self._open_output_folder)
        self.open_codequery_button = QPushButton("Open in CodeQuery")
        self.open_codequery_button.clicked.connect(self._open_codequery)
        for btn in (self.open_output_button, self.open_codequery_button):
            btn.setEnabled(False)
            bottom_actions.addWidget(btn)
        bottom_actions.addStretch(1)
        layout.addLayout(bottom_actions)

        return container

    # ------------------------------------------------------------------
    # Environment checks
    # ------------------------------------------------------------------
    def _check_environment(self) -> None:
        problems = []
        if self._perl_binary is None:
            problems.append("perl was not found on PATH.")
        if self._script_path is None:
            problems.append(
                "cpp_inspector.pl was not found next to gui/. "
                "Place it at the repo root, or set its path manually below."
            )
        missing = config.missing_tools()
        if missing:
            problems.append(f"Missing analysis tool(s): {', '.join(missing)}.")

        if problems:
            self.env_label.setText("⚠ " + "  ".join(problems))
            self.run_button.setEnabled(False)
        else:
            self.env_label.setText(f"✓ Using: {self._script_path}")
            self.env_label.setStyleSheet("color: #2a7;")

    # ------------------------------------------------------------------
    # Path pickers
    # ------------------------------------------------------------------
    def _browse_project(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "Select C/C++ project directory")
        if path:
            self.project_edit.setText(path)
            self.project_edit.setToolTip(path)

    def _browse_output(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "Select output directory")
        if path:
            self.output_edit.setText(path)
            self.output_edit.setToolTip(path)

    def _browse_config(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "Select config directory")
        if path:
            self.config_dir_edit.setText(path)
            self.config_dir_edit.setToolTip(path)

    def _sync_default_output(self, project_path: str) -> None:
        # Only auto-fill; never clobber a value the user typed themselves.
        if project_path and not self.output_edit.text():
            self.output_edit.setText(str(Path(project_path) / "output"))
        if project_path and not self.config_dir_edit.text():
            self.config_dir_edit.setText(str(Path(project_path)))

    # ------------------------------------------------------------------
    # Run / stop
    # ------------------------------------------------------------------
    def _collect_options(self) -> RunOptions | None:
        project_dir = self.project_edit.text().strip()
        output_dir = self.output_edit.text().strip() or str(
            Path(project_dir) / "output"
        )
        config_dir = self.config_dir_edit.text().strip()

        if not project_dir:
            QMessageBox.warning(
                self, "Missing project", "Please choose a project directory first."
            )
            return None

        if not Path(project_dir).is_dir():
            QMessageBox.warning(
                self, "Invalid project", f"'{project_dir}' is not a directory."
            )
            return None

        if config_dir and not Path(config_dir).is_dir():
            QMessageBox.warning(
                self,
                "Invalid Config directory",
                f"Failed to use '{config_dir}'. Ignoring config.json.",
            )
            config_dir = ""

        kinds = "".join(
            letter for letter, cb in self.kind_checks.items() if cb.isChecked()
        )
        if not kinds:
            QMessageBox.warning(
                self, "No symbol kinds", "Select at least one symbol kind."
            )
            return None

        return RunOptions(
            project_dir=project_dir,
            output_dir=output_dir,
            config_dir=config_dir,
            kinds=kinds,
            no_label=self.no_label_check.isChecked(),
            no_line=self.no_line_check.isChecked(),
            no_call=self.no_call_check.isChecked(),
            ignore_config=self.ignore_config_check.isChecked(),
        )

    def _on_run_clicked(self) -> None:
        options = self._collect_options()
        if options is None:
            return
        if self._script_path is None or self._perl_binary is None:
            QMessageBox.critical(self, "Environment not ready", self.env_label.text())
            return

        Path(options.output_dir).mkdir(parents=True, exist_ok=True)

        self.log_view.clear()
        self.tabs.setCurrentWidget(self.log_view)
        self.run_button.setEnabled(False)
        self.stop_button.setEnabled(True)
        self.open_output_button.setEnabled(False)
        self.open_codequery_button.setEnabled(False)
        self.statusBar().showMessage("Running cpp_inspector.pl …")

        self._runner = InspectorRunner(self._perl_binary, self._script_path, self)
        self._runner.output_received.connect(self._append_log)
        self._runner.finished.connect(
            lambda code, status: self._on_run_finished(code, status, options)
        )
        self._runner.failed_to_start.connect(self._on_run_failed)
        self._runner.start(options)

    def _on_stop_clicked(self) -> None:
        if self._runner is not None:
            self._runner.stop()
        self.statusBar().showMessage("Stopped.")

    def _append_log(self, line: str) -> None:
        self.log_view.appendPlainText(line)

    def _on_run_failed(self, message: str) -> None:
        self._append_log(f"[!] Failed to start perl: {message}")
        self._reset_run_controls()
        self.statusBar().showMessage("Failed to start.")

    def _on_run_finished(
        self, exit_code: int, status: str, options: RunOptions
    ) -> None:
        self._reset_run_controls()
        if exit_code == 0 and status == "exited":
            self.statusBar().showMessage("Done.")
            self._load_reports(options)
            self.open_output_button.setEnabled(True)
            self.open_codequery_button.setEnabled(
                Path(options.output_dir, "codequery.db").exists()
            )
        else:
            self.statusBar().showMessage(
                f"cpp_inspector.pl {status} with exit code {exit_code}."
            )

    def _reset_run_controls(self) -> None:
        self.run_button.setEnabled(True)
        self.stop_button.setEnabled(False)

    # ------------------------------------------------------------------
    # Report loading
    # ------------------------------------------------------------------
    def _load_reports(self, options: RunOptions) -> None:
        out_dir = Path(options.output_dir)

        txt_path = self._resolve_report_path(out_dir, options, "txt")
        json_path = self._resolve_report_path(out_dir, options, "json")
        csv_path = out_dir / "cpp_relationships.csv"
        svg_path = out_dir / "cpp_call_graph.svg"

        if txt_path is not None:
            self.report_widgets["txt"].load(txt_path)
        else:
            self._append_log(
                "[!] No cpp_relationships*.txt found in the output directory — "
                "nothing to show in the Text report tab."
            )
        if csv_path.exists():
            self.report_widgets["csv"].load(csv_path)
        if json_path is not None:
            self.report_widgets["json"].load(json_path)
        else:
            self._append_log(
                "[!] No cpp_relationships*.json found in the output directory — "
                "nothing to show in the JSON tab."
            )
        if svg_path.exists():
            self.report_widgets["svg"].load(svg_path)

        self.tabs.setCurrentWidget(self.report_widgets["txt"])

    def _resolve_report_path(
        self, out_dir: Path, options: RunOptions, extension: str
    ) -> Path | None:
        """Finds the report file cpp_inspector.pl just wrote.

        Tries the exact name first (mirroring report_filename() in the
        Perl script). If that's missing — e.g. the project's own
        config.json (read relative to wherever the perl process's cwd
        is, not --in) silently overrode a flag the GUI thinks is off —
        falls back to the most recently modified cpp_relationships*.<ext>
        in the output directory, rather than leaving the tab blank with
        no explanation.
        """
        expected = out_dir / self._report_filename(options, extension)
        if expected.exists():
            return expected

        candidates = sorted(
            out_dir.glob(f"cpp_relationships*.{extension}"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if candidates:
            self._append_log(
                f"[!] Expected '{expected.name}' but found '{candidates[0].name}' instead "
                "(likely due to a project config.json overriding a flag) — showing that one."
            )
            return candidates[0]
        return None

    @staticmethod
    def _report_filename(options: RunOptions, extension: str) -> str:
        """Mirrors report_filename() in cpp_inspector.pl so the GUI finds
        the exact same file the script just wrote."""
        suffix = []
        if options.kinds != "fpmc":
            suffix.append("kind_" + options.kinds)
        if options.no_label:
            suffix.append("no_label")
        if options.no_line:
            suffix.append("no_line")
        if options.no_call:
            suffix.append("no_call")

        name = "cpp_relationships"
        if suffix:
            name += "__" + "__".join(suffix)
        return f"{name}.{extension}"

    # ------------------------------------------------------------------
    # Misc actions
    # ------------------------------------------------------------------
    def _on_save_config_clicked(self) -> None:
        options = self._collect_options()
        if options is None:
            return

        config_dir = self.config_dir_edit.text().strip()
        if not Path(config_dir).is_dir():
            config_dir = options.project_dir

        config_path = Path(config_dir) / "config.json"
        payload = {
            "out": options.output_dir,
            "kind": options.kinds,
            "no_line": options.no_line,
            "no_label": options.no_label,
            "no_call": options.no_call,
            "yes": False,
        }
        try:
            config_path.write_text(
                json.dumps(payload, indent=2) + "\n", encoding="utf-8"
            )
        except OSError as exc:
            QMessageBox.critical(self, "Could not save", str(exc))
            return
        QMessageBox.information(self, "Saved", f"Wrote {config_path}")

    def _open_output_folder(self) -> None:
        path = self.output_edit.text().strip()
        if path:
            QDesktopServices.openUrl(f"file://{path}")

    def _open_codequery(self) -> None:
        db_path = Path(self.output_edit.text().strip()) / "codequery.db"
        if not db_path.exists():
            QMessageBox.warning(self, "Not found", f"{db_path} does not exist.")
            return
        try:
            subprocess.Popen(["codequery", str(db_path)])
        except FileNotFoundError:
            QMessageBox.warning(
                self,
                "codequery not found",
                "The 'codequery' GUI is not installed or not on PATH.",
            )
