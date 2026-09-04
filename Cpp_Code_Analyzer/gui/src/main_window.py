"""
main_window.py — The single window that makes up the whole GUI: an
options form on the left, a log + report tabs on the right.
"""

from __future__ import annotations

import json
import os
import signal
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
from .runner import InspectorServerClient, RunOptions


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Cpp Inspector GUI")

        self._script_path: Path | None = config.find_inspector_script()
        self._perl_binary: str | None = config.find_perl_binary()
        self._server: InspectorServerClient | None = None
        self._current_options: RunOptions | None = None
        self._collect_request_id: int | None = None
        self._collect_job_pid: str | None = None
        self._render_request_id: int | None = None

        self._last_project_loaded: str | None = None

        self._build_ui()
        self._check_environment()

    def closeEvent(self, event) -> None:
        if self._server is not None:
            self._server.stop()
        super().closeEvent(event)

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

        project_label = QLabel("Project dir (--in)")
        project_label.setToolTip("Project directory (Required)")
        self.project_edit = QLineEdit()
        self.project_edit.setPlaceholderText("Path to C/C++ project")
        self.project_edit.textChanged.connect(self._sync_new_project)
        self.project_edit.textChanged.connect(
            lambda txt: self.project_edit.setToolTip(txt)
        )
        project_row = self._path_row(self.project_edit, self._browse_project)
        paths_form.addRow(project_label, project_row)

        output_label = QLabel("Output dir (--out)")
        output_label.setToolTip("Directory where the reports will be saved")
        self.output_edit = QLineEdit()
        self.output_edit.setPlaceholderText("Path for reports")
        self.output_edit.textChanged.connect(
            lambda txt: self.output_edit.setToolTip(txt)
        )
        output_row = self._path_row(self.output_edit, self._browse_output)
        paths_form.addRow(output_label, output_row)

        layout.addWidget(paths_box)

        # --- Config file (config.json) ------------------------------------
        config_box = QGroupBox("Configuration (config.json)")
        config_form = QFormLayout(config_box)

        config_dir_label = QLabel("Config dir (--config)")
        config_dir_label.setToolTip(
            "Directory where config.json will be loaded from/saved to\n"
            "Same as the project directory by default"
        )
        self.config_dir_edit = QLineEdit()
        self.config_dir_edit.setPlaceholderText("Project dir (default)")
        config_dir_row = self._path_row(self.config_dir_edit, self._browse_config_dir)
        self.config_dir_edit.editingFinished.connect(
            lambda: self._maybe_autoload_config(self.config_dir_edit.text().strip())
        )
        self.config_dir_edit.textChanged.connect(
            lambda txt: self.config_dir_edit.setToolTip(txt)
        )
        config_form.addRow(config_dir_label, config_dir_row)

        self.ignore_config_check = QCheckBox("Ignore config.json (--ignore_config)")
        self.ignore_config_check.toggled.connect(self.config_dir_edit.setDisabled)
        self.ignore_config_check.toggled.connect(
            lambda checked: config_dir_row.setDisabled(checked)
        )
        self.ignore_config_check.setToolTip(
            "Skips reading config.json from the directory"
        )
        config_form.addRow("", self.ignore_config_check)

        layout.addWidget(config_box)

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

        self.save_config_button = QPushButton("Save options to config.json")
        self.save_config_button.clicked.connect(self._on_save_config_clicked)
        layout.addWidget(self.save_config_button)

        self.load_config_button = QPushButton("Load options from config.json")
        self.load_config_button.clicked.connect(self._on_load_config_clicked)
        layout.addWidget(self.load_config_button)

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

        if path == self._last_project_loaded and path is not None:
            QMessageBox.warning(
                self, "Alert", "The chosen directory is the same!\nChange ignored!"
            )
            return

        if path:
            self._last_project_loaded = path
            self.project_edit.setText(path)

    def _browse_output(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "Select output directory")
        if path:
            self.output_edit.setText(path)

    def _browse_config_dir(self) -> None:
        path = QFileDialog.getExistingDirectory(
            self, "Select directory containing config.json"
        )
        if path:
            self.config_dir_edit.setText(path)
            self._maybe_autoload_config(path)

    def _sync_new_project(self) -> None:
        self._sync_default_output(self.project_edit.text())
        self._sync_default_config_dir(self.project_edit.text())

        # Clear analysis
        self.log_view.clear()
        self.run_button.setEnabled(True)
        self.stop_button.setEnabled(False)
        self.open_output_button.setEnabled(False)
        self.open_codequery_button.setEnabled(False)
        self.statusBar().showMessage(f"Current project: {path}")

    def _sync_default_config_dir(self, project_path: str) -> None:
        # Mirrors the script's own default (--config falls back to --in).
        if project_path:
            self.config_dir_edit.setText(project_path)
            self.ignore_config_check.setChecked(False)
            self._maybe_autoload_config(project_path)

    def _maybe_autoload_config(self, config_dir: str) -> None:
        """If config_dir has a config.json, load its values into the
        checkboxes so the UI reflects what the script will actually
        apply — mirrors --config's own default lookup, just done ahead
        of time so the user sees it before clicking Run."""
        if not config_dir:
            return
        config_path = Path(config_dir) / "config.json"
        if not config_path.is_file():
            return
        try:
            data = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            self.statusBar().showMessage(f"Could not read {config_path}: {exc}")
            return

        if isinstance(data.get("kind"), str):
            selected = set(data["kind"])
            for letter, cb in self.kind_checks.items():
                cb.setChecked(letter in selected)
        if "no_label" in data:
            self.no_label_check.setChecked(bool(data["no_label"]))
        if "no_line" in data:
            self.no_line_check.setChecked(bool(data["no_line"]))
        if "no_call" in data:
            self.no_call_check.setChecked(bool(data["no_call"]))

        self.statusBar().showMessage(f"Loaded options from {config_path}")

    def _sync_default_output(self, project_path: str) -> None:
        # Only auto-fill; never clobber a value the user typed themselves.
        if project_path:
            self.output_edit.setText(str(Path(project_path) / "output"))

    # ------------------------------------------------------------------
    # Run / stop — collect() then render() over the persistent --serve
    # connection (see runner.InspectorServerClient).
    # ------------------------------------------------------------------
    def _ensure_server(self) -> InspectorServerClient:
        if self._server is None:
            self._server = InspectorServerClient(
                self._perl_binary, self._script_path, self
            )
            self._server.job_started.connect(self._on_job_started)
            self._server.event_received.connect(self._on_event_received)
            self._server.response_received.connect(self._on_response_received)
            self._server.raw_output_received.connect(self._append_log)
            self._server.start_failed.connect(self._on_server_start_failed)
            self._server.server_exited.connect(self._on_server_exited)
        return self._server

    def _on_run_clicked(self) -> None:
        options = self._collect_options()
        if options is None:
            return
        if self._script_path is None or self._perl_binary is None:
            QMessageBox.critical(self, "Environment not ready", self.env_label.text())
            return

        # The server's collect endpoint expects the output dir question
        # already settled (see RunOptions.to_collect_params: yes=True) —
        # creating it here keeps that promise true instead of relying on
        # a confirmation round-trip the protocol doesn't need for the GUI.
        Path(options.output_dir).mkdir(parents=True, exist_ok=True)

        self.log_view.clear()
        self.tabs.setCurrentWidget(self.log_view)
        self.run_button.setEnabled(False)
        self.stop_button.setEnabled(True)
        self.open_output_button.setEnabled(False)
        self.open_codequery_button.setEnabled(False)
        self.statusBar().showMessage("Collecting…")

        server = self._ensure_server()
        self._current_options = options
        self._collect_job_pid = None
        self._render_request_id = None
        self._collect_request_id = server.send("collect", options.to_collect_params())

    def _on_stop_clicked(self) -> None:
        # collect() runs in a forked child on the Perl side; job_started
        # hands us that child's PID, so we can stop just the job instead
        # of tearing down the whole persistent server process.
        if self._collect_job_pid:
            try:
                os.kill(int(self._collect_job_pid), signal.SIGTERM)
                self._append_log(
                    f"[!] Sent stop signal to job (pid {self._collect_job_pid})."
                )
            except (ValueError, ProcessLookupError, PermissionError) as exc:
                self._append_log(f"[!] Could not stop job: {exc}")
        self._reset_run_controls()
        self.statusBar().showMessage("Stopped.")

    def _append_log(self, line: str) -> None:
        self.log_view.appendPlainText(line)

    def _reset_run_controls(self) -> None:
        self.run_button.setEnabled(True)
        self.stop_button.setEnabled(False)

    # --- server signal handlers ----------------------------------------
    def _on_job_started(self, request_id: int, job_id: str) -> None:
        if request_id == self._collect_request_id:
            self._collect_job_pid = job_id

    def _on_event_received(self, request_id: int, event: dict) -> None:
        if request_id != self._collect_request_id:
            return  # not this run (e.g. a leftover event after Stop)

        level = event.get("level", "info")
        if level == "tool_output":
            # Mirrors emit_cli_event() in cpp_inspector.pl: caller_query
            # tool_output comes from find_callers()'s internal cscope -L -3
            # query, run once per symbol — that's raw source lines, not
            # progress, and the CLI hides it too.
            if event.get("context") == "caller_query":
                return
            for line in (event.get("data") or "").splitlines():
                self._append_log(line)
            return

        step, total = event.get("step"), event.get("total")
        message = event.get("message", "")
        if step and total:
            self._append_log(f"[{step}/{total}] {message}")
        elif level in ("warning", "error"):
            self._append_log(f"[!] {message}")
        else:
            self._append_log(message)

    def _on_response_received(self, request_id: int, message: dict) -> None:
        if request_id == self._collect_request_id:
            self._handle_collect_response(message)
        elif request_id == self._render_request_id:
            self._handle_render_response(message)

    def _handle_collect_response(self, message: dict) -> None:
        if not message.get("ok"):
            self._append_log(
                f"[!] collect failed: {message.get('error', 'Unknown error')}"
            )
            self._reset_run_controls()
            self.statusBar().showMessage("Failed.")
            return

        model = (message.get("data") or {}).get("model")
        if model is None:
            self._append_log("[!] collect succeeded but returned no model.")
            self._reset_run_controls()
            self.statusBar().showMessage("Failed.")
            return

        self.statusBar().showMessage("Rendering reports…")
        server = self._ensure_server()
        render_options = self._current_options.to_render_options()
        self._render_request_id = server.send(
            "render", {"model": model, "options": render_options}
        )

    def _handle_render_response(self, message: dict) -> None:
        self._reset_run_controls()
        if not message.get("ok"):
            self._append_log(
                f"[!] render failed: {message.get('error', 'Unknown error')}"
            )
            self.statusBar().showMessage("Failed.")
            return

        data = message.get("data") or {}
        artifact_paths = data.get("artifact_paths") or {}
        self.statusBar().showMessage("Done.")
        self._load_reports(artifact_paths)
        self.open_output_button.setEnabled(True)
        db_path = artifact_paths.get("db")
        self.open_codequery_button.setEnabled(bool(db_path) and Path(db_path).exists())

    def _on_server_start_failed(self, message: str) -> None:
        self._append_log(f"[!] Failed to start perl --serve: {message}")
        self._reset_run_controls()
        self.statusBar().showMessage("Failed to start.")

    def _on_server_exited(self, exit_code: int, status: str) -> None:
        self._append_log(f"[!] Server process {status} (exit code {exit_code}).")
        self._server = None
        self._reset_run_controls()
        self.statusBar().showMessage("Server stopped.")

    # ------------------------------------------------------------------
    # Report loading
    # ------------------------------------------------------------------
    def _load_reports(self, artifact_paths: dict) -> None:
        """artifact_paths comes straight from the render() response — the
        actual paths the script just wrote — so there's no filename
        guessing to keep in sync with report_filename() on the Perl side."""
        widget_for_key = {
            "text": "txt",
            "csv": "csv",
            "json": "json",
            "svg": "svg",
        }
        for key, widget_name in widget_for_key.items():
            raw_path = artifact_paths.get(key)
            if raw_path and Path(raw_path).exists():
                self.report_widgets[widget_name].load(Path(raw_path))

        self.tabs.setCurrentWidget(self.report_widgets["txt"])

    def _collect_options(self) -> RunOptions | None:
        project_dir = self.project_edit.text().strip()
        output_dir = self.output_edit.text().strip() or str(
            Path(project_dir) / "output"
        )

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
            kinds=kinds,
            no_label=self.no_label_check.isChecked(),
            no_line=self.no_line_check.isChecked(),
            no_call=self.no_call_check.isChecked(),
            config_dir=self.config_dir_edit.text().strip(),
            ignore_config=self.ignore_config_check.isChecked(),
        )

    # ------------------------------------------------------------------
    # Misc actions
    # ------------------------------------------------------------------
    def _on_load_config_clicked(self) -> None:
        config_dir = self.config_dir_edit.text().strip()
        config_path = Path(config_dir) / "config.json" if config_dir else None
        if not config_dir or not config_path.is_file():
            QMessageBox.information(
                self, "No config.json", f"No config.json found in '{config_dir}'."
            )
            return
        self._maybe_autoload_config(config_dir)

    def _on_save_config_clicked(self) -> None:
        options = self._collect_options()
        if options is None:
            return

        config_path = Path(self.config_dir_edit.text())
        if not config_path.is_dir:
            config_path = Path(options.project_dir)
        config_path /= "config.json"

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
