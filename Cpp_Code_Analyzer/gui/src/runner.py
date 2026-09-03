"""
runner.py — Long-lived JSON-lines client for `perl cpp_inspector.pl --serve`.

The server protocol (see the script's --help / --serve section):

  Request:     {"id": N, "endpoint": "...", "params": {...}}
  Response:    {"id": N, "type": "response", "ok": true/false, "data"/"error": ...}
  Event:       {"id": N, "type": "event", "level": "...", "message": "...", ...}
  Job started: {"id": N, "type": "job_started", "job_id": "<pid>", "endpoint": "collect"}
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, Signal


@dataclass
class RunOptions:
    project_dir: str
    output_dir: str
    kinds: str = "fpmc"
    no_label: bool = False
    no_line: bool = False
    no_call: bool = False
    config_dir: str = ""
    ignore_config: bool = False

    def to_collect_params(self) -> dict:
        """Params for the 'collect' endpoint. The GUI always creates the
        output dir up front (see main_window), so yes=True just tells the
        script the directory question is already settled — nothing to
        confirm over a channel that's now JSON requests, not stdin."""
        params: dict = {
            "in": self.project_dir,
            "out": self.output_dir,
            "yes": True,
        }
        if self.ignore_config:
            params["ignore_config"] = True
        elif self.config_dir:
            params["config_dir"] = self.config_dir
        params.update(self._format_options())
        return params

    def to_render_options(self) -> dict:
        """Params for the 'options' field of the 'render' endpoint. Kept
        identical to the collect-time formatting flags so the model's own
        artifact_paths (computed during collect) and the paths render()
        actually writes to never disagree."""
        return self._format_options()

    def _format_options(self) -> dict:
        options: dict = {}
        if self.kinds and self.kinds != "fpmc":
            options["kind"] = self.kinds
        if self.no_label:
            options["no_label"] = True
        if self.no_line:
            options["no_line"] = True
        if self.no_call:
            options["no_call"] = True
        return options


class InspectorServerClient(QObject):
    """Wraps `perl cpp_inspector.pl --serve` as a persistent JSON-lines
    subprocess. One instance is created per MainWindow and reused across
    every request/run for the lifetime of the window."""

    # request_id, event dict (as sent by the server, e.g. progress/tool_output)
    event_received = Signal(int, dict)
    # request_id, {"ok": bool, "data": ...} or {"ok": False, "error": "..."}
    response_received = Signal(int, dict)
    # request_id, job_id (the forked collect job's PID, as a string)
    job_started = Signal(int, str)
    # a stdout line that wasn't valid JSON, or a stderr line — surfaced
    # rather than dropped, since it usually means something went wrong
    # before/outside the protocol (e.g. a die() during startup).
    raw_output_received = Signal(str)
    # perl itself could not be started at all (bad path, no exec bit, ...)
    start_failed = Signal(str)
    server_exited = Signal(int, str)  # exit_code, "exited"/"crashed"

    def __init__(
        self, perl_binary: str, script_path: Path, parent: QObject | None = None
    ):
        super().__init__(parent)
        self._perl_binary = perl_binary
        self._script_path = script_path
        self._process: QProcess | None = None
        self._next_id = 1
        self._stdout_buffer = ""

    def is_running(self) -> bool:
        return (
            self._process is not None
            and self._process.state() != QProcess.ProcessState.NotRunning
        )

    def start(self) -> None:
        if self.is_running():
            return

        proc = QProcess(self)
        proc.readyReadStandardOutput.connect(self._on_stdout)
        proc.readyReadStandardError.connect(self._on_stderr)
        proc.finished.connect(self._on_finished)
        proc.errorOccurred.connect(
            lambda _err: self.start_failed.emit(proc.errorString())
        )

        self._process = proc
        self._stdout_buffer = ""
        proc.start(self._perl_binary, [str(self._script_path), "--serve"])

    def stop(self) -> None:
        if self._process is not None and self.is_running():
            self._process.terminate()
            if not self._process.waitForFinished(2000):
                self._process.kill()
        self._process = None

    def send(self, endpoint: str, params: dict | None = None) -> int:
        """Sends a request; the id is returned immediately, results arrive
        later via the signals above (job_started/event_received for
        'collect', response_received for everything, including collect's
        own final response)."""
        if not self.is_running():
            self.start()

        request_id = self._next_id
        self._next_id += 1
        payload = {"id": request_id, "endpoint": endpoint, "params": params or {}}
        line = json.dumps(payload) + "\n"
        self._process.write(line.encode("utf-8"))
        return request_id

    def _on_stdout(self) -> None:
        proc = self._process
        if proc is None:
            return
        self._stdout_buffer += bytes(proc.readAllStandardOutput()).decode(
            "utf-8", errors="replace"
        )
        while "\n" in self._stdout_buffer:
            line, self._stdout_buffer = self._stdout_buffer.split("\n", 1)
            line = line.strip()
            if line:
                self._dispatch(line)

    def _dispatch(self, line: str) -> None:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            self.raw_output_received.emit(line)
            return
        if not isinstance(message, dict):
            self.raw_output_received.emit(line)
            return

        request_id = message.get("id")
        msg_type = message.get("type")

        if msg_type == "job_started":
            self.job_started.emit(request_id, str(message.get("job_id", "")))
        elif msg_type == "event":
            self.event_received.emit(request_id, message)
        elif msg_type == "response":
            self.response_received.emit(request_id, message)
        else:
            self.raw_output_received.emit(line)

    def _on_stderr(self) -> None:
        proc = self._process
        if proc is None:
            return
        data = bytes(proc.readAllStandardError()).decode("utf-8", errors="replace")
        for line in data.splitlines():
            if line.strip():
                self.raw_output_received.emit(line)

    def _on_finished(self, exit_code: int, exit_status) -> None:
        status_text = (
            "crashed" if exit_status == QProcess.ExitStatus.CrashExit else "exited"
        )
        self.server_exited.emit(exit_code, status_text)
        self._process = None
