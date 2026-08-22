# Cpp_Code_Analyzer

A command-line code analysis tool for C/C++ projects that generates detailed reports on code structure, relationships, and call graphs. It automates the generation of CodeQuery databases, text reports, JSON, CSV exports, and SVG visualizations.

## Overview

Cpp_Code_Analyzer simplifies the process of analyzing large C/C++ codebases by integrating three powerful tools:

- **ctags**: Symbol extraction and indexing
- **cscope**: Code navigation and call relationship analysis
- **cqmakedb**: CodeQuery database generation

The tool scans your project, extracts definitions (functions, prototypes, members, classes), maps caller-callee relationships, and generates multiple output formats for analysis and documentation.

## Stack

- **Language**: Perl 5 (85.4% of codebase)
- **Analysis Tools**: ctags, cscope, cqmakedb
- **Output Formats**: CodeQuery database, text reports, CSV, JSON, SVG
- **Build**: CMake for example projects
- **License**: MIT

## Directory Structure

```
Cpp_Code_Analyzer/
├── cpp_inspector.pl           Main Perl script (~1000 lines)
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

Generates output in the default `output` directory.

### Advanced Options

```bash
perl cpp_inspector.pl --in=./my_project --out=./results --kind=fp --no_line --yes
```

**Options:**

| Flag | Description |
|------|-------------|
| `--in=<path>` | Project directory to analyze (required) |
| `--out=<path>` | Output directory (default: `output`) |
| `--kind=<letters>` | Filter symbol types: `f` (functions), `p` (prototypes), `m` (members), `c` (classes) |
| `--no_label` | Omit symbol kind labels in reports |
| `--no_line` | Omit line numbers in reports |
| `--no_call` | Omit "Called by" sections in reports |
| `--yes, -y` | Skip confirmation prompts (useful for CI/automation) |
| `--help, -h` | Display help message |

### Project Configuration

Create a `config.json` file in your project root to set default options:

```json
{
  "out": "output_codequery",
  "kind": "fp",
  "no_line": false,
  "no_label": false,
  "no_call": false,
  "yes": false
}
```

This allows projects to define preferred analysis flags without repeating them on every invocation. CLI options always take precedence over config values.

### Output Artifacts

The tool generates five deliverables:

1. **codequery.db**: CodeQuery database for GUI exploration
   ```bash
   codequery /path/to/output/codequery.db
   ```

2. **cpp_relationships.txt**: Comprehensive text report with symbol definitions and call relationships

3. **cpp_relationships.csv**: Machine-readable CSV export for spreadsheets and graph tools

4. **cpp_relationships.json**: Structured JSON report optimized for machine/AI consumption

5. **cpp_call_graph.svg**: Circular call graph visualization (no external dependencies)

## cpp_inspector.pl - Script Architecture

### Core Components

**1. Symbol Types (Kinds)**
- `f` - Functions: Function definitions
- `p` - Prototypes: Function or method declarations
- `m` - Members: Class member variables or methods
- `c` - Classes: Class or struct definitions

**2. Main Processing Pipeline (8 Steps)**

```
[1] Collect source files from project directory
    └─ Recursively discovers .c/.cpp/.h/.hpp files
    └─ Skips: .git, .svn, .hg, build, cmake-build-*, out directories

[2] Write file list to cscope.files
    └─ Contains absolute paths for all discovered source files

[3] Run ctags
    └─ Extracts symbol definitions with metadata
    └─ Captures: function signatures, return types, class scope

[4] Run cscope
    └─ Builds cross-reference database
    └─ Enables caller-callee relationship queries

[5] Generate CodeQuery database
    └─ Runs cqmakedb to create .db file
    └─ Enables GUI exploration (codequery command)

[6] Parse tags output
    └─ Loads ctags results into %definitions hash
    └─ Structure: %definitions{file}{symbol_name} = {kind, line, signature, return_type, scope}

[7] Build caller map via cscope
    └─ Queries "who calls this function?" for each symbol
    └─ Creates %callers_of{callee_name} = [{caller, file, line}, ...]

[8] Generate reports
    └─ Text report: Human-readable symbol overview
    └─ CSV export: Edge list for graph analysis
    └─ JSON report: Structured data with full metadata
    └─ SVG graph: Circular node-link visualization
```

**3. Key Data Structures**

- `%definitions`: Symbol metadata keyed by file and name
- `%callers_of`: Call graph relationships (who calls each function)
- `%KIND_LABEL`: Human-readable names for symbol types
- `%KIND_PRIORITY`: Sort order for report output

**4. Output Report Formats**

**Text Report** (`cpp_relationships.txt`)
- Summary counts by symbol type
- File-by-file symbol listing
- Caller relationships with file/line references

**CSV Report** (`cpp_relationships.csv`)
- Standard format: `callee,caller,file,line`
- One row per unique caller-callee pair
- Suitable for spreadsheets, graph-viz tools, data analysis

**JSON Report** (`cpp_relationships.json`)
- Comprehensive structured data
- Schema version tracking
- Project metadata and analysis options
- Full symbol information with caller details
- Relationship edges

Example JSON structure:
```json
{
  "schema_version": "1.0",
  "project": { "path": "..." },
  "options": { "kind": ["f","p","m","c"], "hide_labels": false, ... },
  "summary": { "files": 10, "symbols": 250, "relationships": 1500, "kinds": {...} },
  "files": [
    {
      "path": "src/main.cpp",
      "symbols": [
        {
          "name": "main",
          "qualified_name": "main",
          "kind": "f",
          "kind_name": "Function",
          "line": 42,
          "signature": "(int argc, char** argv)",
          "return_type": "int",
          "callers": [...]
        }
      ]
    }
  ],
  "relationships": [
    { "callee": "foo", "caller": "main", "file": "src/main.cpp", "line": 50 }
  ]
}
```

**SVG Call Graph** (`cpp_call_graph.svg`)
- Circular layout with nodes positioned on circumference
- Edges drawn as straight lines with arrowheads
- Automatically sized based on node count
- No external dependencies (pure SVG)

**5. Safety & Validation Features**

- Refuses to run as root (security protection)
- Validates tool availability before execution
- Verifies project directory existence
- Handles output directory creation with interactive prompt (skippable with `--yes`)
- Comprehensive error messages for missing tools/files

**6. Path Handling**

- All file paths stored as absolute paths internally
- Reports display relative paths for readability
- Supports tilde expansion (`~/path`)
- Cross-platform path handling via File::Spec

**7. Filtering & Customization**

- Symbol kind filtering (include/exclude specific types)
- Report suffix naming: `cpp_relationships__kind_fp__no_label__no_call.txt`
- Dynamic report generation based on active options
- Deduplication: Avoids duplicate caller entries and relationships

### Module Dependencies

- `strict`, `warnings`, `feature`: Modern Perl practices
- `Cwd`: Path resolution
- `File::Basename`, `File::Find`, `File::Path`, `File::Spec`: File operations
- `Getopt::Long`: Command-line parsing
- `JSON::PP`: JSON encoding/decoding

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
[8/8] Writing text, CSV, JSON and SVG reports...

[SUCCESS] Pipeline completed successfully!
--------------------------------------------------
1. CodeQuery GUI:
   codequery /full/path/to/analysis/codequery.db

2. Text overview report:
   /full/path/to/analysis/cpp_relationships.txt

3. CSV relationship export:
   /full/path/to/analysis/cpp_relationships.csv

4. AI/JSON analysis report:
   /full/path/to/analysis/cpp_relationships.json

5. SVG call graph:
   /full/path/to/analysis/cpp_call_graph.svg
--------------------------------------------------
```

## Features

- **Symbol Extraction**: Functions, prototypes, class members, and class definitions
- **Call Graph Analysis**: Maps caller-callee relationships automatically
- **Flexible Filtering**: Include/exclude symbol types by kind
- **Multiple Output Formats**: Text, CSV, JSON, SVG, and CodeQuery database
- **Report Customization**: Control label visibility, line numbers, and relationship depth
- **Project Configuration**: Use config.json for persistent default settings
- **CI/Automation Ready**: Non-interactive mode for integration into pipelines
- **Security**: Refuses to run as root
- **Path Handling**: Shortens paths in reports for readability
- **Deduplication**: Eliminates redundant caller/callee pairs in outputs
- **Self-Recursion Filtering**: Ignores self-referential calls in analysis

## Performance Notes

- Processing time scales with project size (files and symbols)
- Typical small project (< 100 files): < 5 seconds
- Large projects (1000+ files): 30-120 seconds depending on system
- Memory efficient: Streams file processing, uses hashes for symbol indexing
- Output file sizes:
  - `.db`: Varies by symbol count and complexity
  - `.txt`: ~50-500 lines per 100 functions
  - `.csv`: ~1 row per call relationship
  - `.json`: Approximately 2-3x size of text report
  - `.svg`: Compact unless there are 1000+ unique functions

## License

MIT License - see LICENSE file for details
