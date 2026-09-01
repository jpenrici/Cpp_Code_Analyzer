"""
runner.py — Runs cpp_inspector.pl in the background via QProcess and
streams stdout/stderr back to the UI without blocking it.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, Signal


@dataclass
class RunOptions:
    project_dir: str
    output_dir: str
    kinds: str = "fpmc"          # any combination of f/p/m/c
    no_label: bool = False
    no_line: bool = False
    no_call: bool = False
    extra_args: list[str] = field(default_factory=list)

    def to_args(self, script_path: Path) -> list[str]:
        args = [str(script_path), f"--in={self.project_dir}", f"--out={self.output_dir}"]

        if self.kinds and self.kinds != "fpmc":
            args.append(f"--kind={self.kinds}")
        if self.no_label:
            args.append("--no_label")
        if self.no_line:
            args.append("--no_line")
        if self.no_call:
            args.append("--no_call")

        # The GUI always creates the output dir up front (see main_window),
        # so --yes just tells the script to skip its interactive prompt
        # instead of hanging while waiting on stdin.
        args.append("--yes")
        args.extend(self.extra_args)
        return args


class InspectorRunner(QObject):
    """Thin wrapper around QProcess for running `perl cpp_inspector.pl ...`."""

    output_received = Signal(str)   # one line of combined stdout/stderr
    finished = Signal(int, str)     # exit_code, exit_status_text
    failed_to_start = Signal(str)

    def __init__(self, perl_binary: str, script_path: Path, parent: QObject | None = None):
        super().__init__(parent)
        self._perl_binary = perl_binary
        self._script_path = script_path
        self._process: QProcess | None = None

    def is_running(self) -> bool:
        return self._process is not None and self._process.state() != QProcess.ProcessState.NotRunning

    def start(self, options: RunOptions) -> None:
        if self.is_running():
            return

        proc = QProcess(self)
        proc.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        proc.readyReadStandardOutput.connect(lambda: self._emit_output(proc))
        proc.finished.connect(self._on_finished)
        proc.errorOccurred.connect(lambda _err: self.failed_to_start.emit(proc.errorString()))

        args = options.to_args(self._script_path)
        self._process = proc
        proc.start(self._perl_binary, args)

    def stop(self) -> None:
        if self._process is not None and self.is_running():
            self._process.kill()

    def _emit_output(self, proc: QProcess) -> None:
        data = bytes(proc.readAllStandardOutput()).decode("utf-8", errors="replace")
        for line in data.splitlines():
            self.output_received.emit(line)

    def _on_finished(self, exit_code: int, exit_status) -> None:
        status_text = "crashed" if exit_status == QProcess.ExitStatus.CrashExit else "exited"
        self.finished.emit(exit_code, status_text)
        self._process = None
