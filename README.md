# Cpp_Code_Analyzer

A command-line code analysis tool for C/C++ projects that generates detailed reports on code structure, relationships, and call graphs. It automates the generation of CodeQuery databases, text reports, CSV exports, and SVG visualizations using industry-standard tools.

## Overview

Cpp_Code_Analyzer simplifies the process of analyzing large C/C++ codebases by integrating three powerful tools:

- **ctags**: Symbol extraction and indexing
- **cscope**: Code navigation and call relationship analysis
- **cqmakedb**: CodeQuery database generation

The tool scans your project, extracts definitions (functions, prototypes, members, classes), maps caller-callee relationships, and generates multiple output formats for analysis and documentation.

## Stack

- **Language**: Perl 5 (81.3% of codebase)
- **Analysis Tools**: ctags, cscope, cqmakedb
- **Output Formats**: CodeQuery database, text reports, CSV, SVG
- **Build**: CMake for example projects
- **License**: MIT

## Directory Structure

```
Cpp_Code_Analyzer/
├── cpp_inspector.pl           Main Perl script (23.7 KB)
├── Example_Project_01/        Sample C++ project (CMake-based)
│   ├── CMakeLists.txt
│   ├── include/
│   ├── src/
│   │   ├── main.cpp
│   │   └── hello.cpp
│   └── include/hello.hpp
│
└── Example_Project_02/        Second example project
    ├── CMakeLists.txt
    ├── include/
    └── src/
        ├── main.cpp
        ├── calculator.cpp
        ├── shape.cpp
        └── logger.cpp
```

The script processes any C/C++ project directory, discovering all source files (`.c`, `.cpp`, `.cxx`, `.cc`, `.h`, `.hpp`, `.hxx`, `.hh`). It automatically skips build directories and version control metadata.

## Installation

### Prerequisites

Install the required analysis tools:

**On Ubuntu/Debian:**
```bash
sudo apt-get install universal-ctags cscope codequery
```

**On macOS (Homebrew):**
```bash
brew install universal-ctags cscope codequery
```

**On other systems:** Install ctags, cscope, and cqmakedb from your package manager or source.

### Running the Analyzer

```bash
perl cpp_inspector.pl --in=/path/to/project --out=/path/to/output
```

## Usage

### Basic Analysis

```bash
perl cpp_inspector.pl --in=./my_project
```

Generates output in the default `output_codequery/` directory.

### Advanced Options

```bash
perl cpp_inspector.pl --in=./my_project --out=./results --kind=fp --no_line --yes
```

**Options:**

| Flag | Description |
|------|-------------|
| `--in=<path>` | Project directory to analyze (required) |
| `--out=<path>` | Output directory (default: `output_codequery`) |
| `--kind=<letters>` | Filter symbol types: `f` (functions), `p` (prototypes), `m` (members), `c` (classes) |
| `--no_label` | Omit symbol kind labels in reports |
| `--no_line` | Omit line numbers in reports |
| `--no_call` | Omit "Called by" sections in reports |
| `--yes, -y` | Skip confirmation prompts (useful for CI/automation) |
| `--help, -h` | Display help message |

### Output Artifacts

The tool generates four deliverables:

1. **codequery.db**: CodeQuery database for GUI exploration
   ```bash
   codequery /path/to/output/codequery.db
   ```

2. **cpp_relationships.txt**: Comprehensive text report with symbol definitions and call relationships

3. **cpp_relationships.csv**: Machine-readable CSV export for spreadsheets and graph tools

4. **cpp_call_graph.svg**: Circular call graph visualization (no external dependencies)

## Example

```bash
perl cpp_inspector.pl --in=./Example_Project_01 --out=./analysis
```

**Output:**
```
[*] Scanning project directory: /full/path/to/Example_Project_01
[*] Saving output artifacts to: /full/path/to/analysis

[1/8] Found 3 C/C++ source/header files.
[2/8] Wrote absolute file list to 'cscope.files'.
[3/8] Running ctags...
[4/8] Running cscope...
[5/8] Generating CodeQuery database (.db)...
[6/8] Parsing tags output...
[7/8] Mapping caller/callee relationships via cscope...
[8/8] Writing text, CSV and SVG reports...

[SUCCESS] Pipeline completed successfully!
--------------------------------------------------
1. CodeQuery GUI:
   codequery /full/path/to/analysis/codequery.db

2. Text overview report:
   /full/path/to/analysis/cpp_relationships.txt

3. CSV relationship export:
   /full/path/to/analysis/cpp_relationships.csv

4. SVG call graph:
   /full/path/to/analysis/cpp_call_graph.svg
--------------------------------------------------
```

## Features

- **Symbol Extraction**: Functions, prototypes, class members, and class definitions
- **Call Graph Analysis**: Maps caller-callee relationships automatically
- **Flexible Filtering**: Include/exclude symbol types by kind
- **Multiple Output Formats**: Text, CSV, SVG, and CodeQuery database
- **Report Customization**: Control label visibility, line numbers, and relationship depth
- **CI/Automation Ready**: Non-interactive mode for integration into pipelines
- **Security**: Refuses to run as root
- **Path Handling**: Shortens paths in reports for readability

## License

MIT License - see LICENSE file for details
