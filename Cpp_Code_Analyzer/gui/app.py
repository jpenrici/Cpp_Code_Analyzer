#!/usr/bin/env python3
"""
app.py — Entry point for the Cpp_Code_Analyzer GUI.

A thin PySide6 front-end around cpp_inspector.pl: pick a project, tick a
few options, hit Run, and browse the generated reports without touching
the terminal.

Usage:
    python app.py
"""
import sys

from PySide6.QtWidgets import QApplication

from src.main_window import MainWindow


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Cpp Inspector GUI")
    app.setOrganizationName("Cpp_Code_Analyzer")

    window = MainWindow()
    window.resize(1100, 720)
    window.show()

    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
