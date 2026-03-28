"""
Internal maintainer helper for exporting repository source into one text file.
Keep it as a local maintenance utility.
"""

import argparse
import json
import logging
import os
from pathlib import Path
from typing import List, Optional, Set

# --- CONFIGURATION ---
def _find_project_root(start: Path) -> Path:
    for parent in [start, *start.parents]:
        if (parent / "pyproject.toml").exists():
            return parent
    return start


try:
    PROJECT_ROOT = _find_project_root(Path(__file__).resolve())
except NameError:
    # Fallback for interactive environments where __file__ is not defined
    PROJECT_ROOT = Path.cwd()

OUTPUT_FILENAME = "full_project_source.txt"

# --- EXCLUSION LISTS ---

# Directories to exclude if they appear ANYWHERE in the project structure.
EXCLUDE_DIRS_ANYWHERE: Set[str] = {
    ".git",
    "__pycache__",
    ".pytest_cache",
    "cache",
    "outputs",
    ".vscode",
    ".idea",
    "venv",
    ".venv",
    "env",
    "build",
    "dist",
    "renv",
    "node_modules",
}

# Directories to exclude ONLY if they are in the project root directory.
# This allows keeping nested directories with the same name (e.g., 'src/app/data').
EXCLUDE_DIRS_ROOT_ONLY: Set[str] = {
    "data",  # User-specific data, not source code
#     "tests",
    ".ruff_cache",
    "out",
    "cache",
    ".venv",
    "venv",
    ".git/",
    "__pycache__/",
    "artifacts",
    "configs",
}

# Directory name patterns to exclude (e.g., any directory ending with .egg-info).
EXCLUDE_DIR_PATTERNS: tuple[str, ...] = (".egg-info",)

# File extensions to exclude, typically for binary or non-source files.
EXCLUDE_EXTENSIONS: Set[str] = {
    ".pyc",
    ".pyo",
    ".so",
    ".dll",
    ".exe",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".ico",
    ".svg",
    ".parquet",
    ".arrow",
    ".feather",
    ".csv",
    ".zip",
    ".gz",
    ".tar",
    ".rar",
    ".7z",
    ".db",
    ".sqlite3",
    ".pdf",
    ".docx",
    ".xlsx",
    ".swp",
    ".swo",
}

# Specific filenames to exclude. The chosen output file will be added at runtime
# to ensure it is not reprocessed on subsequent runs.
EXCLUDE_FILES: Set[str] = {
    OUTPUT_FILENAME,
    ".DS_Store",
    "Thumbs.db",
    "celerybeat-schedule",
    ".env",
    "uv.lock",
    ".gitignore",
}


def process_notebook(filepath: Path) -> Optional[str]:
    """
    Parses a Jupyter Notebook (.ipynb) file, extracting only the code and
    markdown content while ignoring all cell outputs.
    """
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            notebook = json.load(f)

        content_parts: List[str] = []
        for i, cell in enumerate(notebook.get("cells", [])):
            cell_type = cell.get("cell_type")
            source_list = cell.get("source", [])

            # Ensure 'source' is a single string
            source = (
                "".join(source_list)
                if isinstance(source_list, list)
                else str(source_list)
            )

            if not source.strip():
                continue

            if cell_type == "code":
                content_parts.append(f"# --- Code Cell {i+1} ---\n{source}\n")
            elif cell_type == "markdown":
                content_parts.append(f"# --- Markdown Cell {i+1} ---\n{source}\n")

        return "\n".join(content_parts)
    except Exception as e:
        logging.warning("Could not parse notebook %s: %s", filepath.name, e)
        return None


def is_likely_text_file(filepath: Path) -> bool:
    """
    Checks if a file is likely to be a text file by checking its extension
    and sniffing the first 1024 bytes for null characters.
    """
    if filepath.suffix.lower() in EXCLUDE_EXTENSIONS:
        return False
    try:
        with open(filepath, "rb") as f:
            # If the first 1KB contains a null byte, it's likely a binary file.
            return b"\0" not in f.read(1024)
    except (IOError, PermissionError):
        return False


def get_directory_exclude_reason(
    dir_name: str,
    current_path: Path,
    project_root: Path,
) -> Optional[str]:
    """Returns the exclude reason for a directory, or None if it is included."""
    if dir_name in EXCLUDE_DIRS_ANYWHERE:
        return "excluded directory (anywhere)"
    if dir_name in EXCLUDE_DIRS_ROOT_ONLY and current_path == project_root:
        return "excluded root-only directory"
    if any(dir_name.endswith(pattern) for pattern in EXCLUDE_DIR_PATTERNS):
        return "excluded directory pattern"
    return None


def get_archive_file_status(
    filepath: Path,
    exclude_files: Set[str],
) -> tuple[bool, str]:
    """Classifies whether a file should be included in the content export."""
    if filepath.name in exclude_files:
        return False, "explicitly excluded filename"
    if filepath.suffix.lower() == ".ipynb":
        return True, "notebook"
    if filepath.suffix.lower() in EXCLUDE_EXTENSIONS:
        return False, "excluded extension"
    if is_likely_text_file(filepath):
        return True, "text file"
    return False, "binary or unreadable file"


def filter_walk_directories(
    dirnames: List[str],
    current_path: Path,
    project_root: Path,
) -> List[str]:
    """Returns the directories that should remain traversable for os.walk."""
    included_dirs: List[str] = []
    for dirname in dirnames:
        if get_directory_exclude_reason(dirname, current_path, project_root):
            continue
        included_dirs.append(dirname)
    included_dirs.sort()
    return included_dirs


def collect_project_tree_lines(
    project_root: Path,
    exclude_files: Set[str],
) -> tuple[List[str], dict[str, int]]:
    """Builds a tree view of the repository with include/exclude markers.

    Excluded directories are shown only at the first excluded node and their
    children are intentionally not expanded.
    """
    stats = {
        "included_files": 0,
        "excluded_files": 0,
        "excluded_directories": 0,
    }

    def _walk_tree(current_path: Path, prefix: str) -> List[str]:
        try:
            children = sorted(
                current_path.iterdir(),
                key=lambda path: (path.is_file(), path.name.lower()),
            )
        except OSError as exc:
            return [f"{prefix}`-- [exclude] <unreadable> ({exc})"]

        lines: List[str] = []
        for index, child in enumerate(children):
            is_last = index == len(children) - 1
            connector = "`-- " if is_last else "|-- "
            child_prefix = prefix + ("    " if is_last else "|   ")

            if child.is_dir():
                reason = get_directory_exclude_reason(
                    child.name, current_path, project_root
                )
                if reason:
                    stats["excluded_directories"] += 1
                    lines.append(
                        f"{prefix}{connector}[exclude] {child.name}/ "
                        f"({reason}; subtree omitted)"
                    )
                    continue

                lines.append(f"{prefix}{connector}[include] {child.name}/")
                lines.extend(_walk_tree(child, child_prefix))
                continue

            include_in_archive, reason = get_archive_file_status(child, exclude_files)
            if include_in_archive:
                stats["included_files"] += 1
                lines.append(f"{prefix}{connector}[include] {child.name}")
            else:
                stats["excluded_files"] += 1
                lines.append(
                    f"{prefix}{connector}[exclude] {child.name} ({reason})"
                )

        return lines

    return ["[include] ./", *_walk_tree(project_root, "")], stats


def collect_file_tree(
    project_root: Path,
    exclude_files: Set[str],
) -> List[Path]:
    """
    Collects all file paths in the project, applying the same exclusion rules
    as the main combine function.
    """
    files: List[Path] = []

    for dirpath, dirnames, filenames in os.walk(project_root, topdown=True):
        current_path = Path(dirpath)
        dirnames[:] = filter_walk_directories(
            list(dirnames), current_path, project_root
        )

        for filename in sorted(filenames):
            if filename in exclude_files:
                continue
            filepath = current_path / filename
            files.append(filepath)

    return files


def combine_project_files(  # noqa: C901 - high complexity due to multiple nested checks
    project_root: Path = PROJECT_ROOT,
    output_filename: str = OUTPUT_FILENAME,
) -> None:
    """Scans the project directory, filters out unwanted files/directories,
    and combines all relevant source code into a single text file."""

    output_filepath = project_root / output_filename
    logging.info("Project root identified as: %s", project_root)
    logging.info("Output will be saved to: %s\n", output_filepath)

    files_processed_count = 0
    files_skipped_count = 0

    exclude_files = set(EXCLUDE_FILES)
    exclude_files.add(output_filename)

    # First, collect the tree summary for the header.
    logging.info("Collecting project tree structure...")
    tree_lines, tree_stats = collect_project_tree_lines(project_root, exclude_files)

    logging.info(
        "Found %d files to include in the archive.\n",
        tree_stats["included_files"],
    )

    try:
        with open(output_filepath, "w", encoding="utf-8", errors="replace") as outfile:
            outfile.write("--- Project Source Code Archive ---\n\n")
            outfile.write(
                "This file contains the concatenated source code of the project, "
                "with each file wrapped in tags indicating its relative path.\n\n"
            )

            # Write tree summary at the beginning.
            outfile.write("--- Full Project Source Tree ---\n")
            outfile.write(
                "Legend: [include] exported in the content section; "
                "[exclude] not exported in the content section.\n"
            )
            outfile.write(
                "Excluded directories are shown only at the first excluded "
                "node and their children are not expanded.\n"
            )
            outfile.write(
                f"Included files: {tree_stats['included_files']}\n"
                f"Excluded files: {tree_stats['excluded_files']}\n"
                f"Excluded directories (collapsed): "
                f"{tree_stats['excluded_directories']}\n\n"
            )
            for line in tree_lines:
                outfile.write(line + "\n")
            outfile.write("\n--- End of Tree ---\n\n")

            for dirpath, dirnames, filenames in os.walk(project_root, topdown=True):
                current_path = Path(dirpath)
                dirnames[:] = filter_walk_directories(
                    list(dirnames), current_path, project_root
                )

                # --- FILE PROCESSING LOGIC ---
                for filename in sorted(filenames):
                    filepath = current_path / filename
                    relative_path_str = filepath.relative_to(project_root).as_posix()
                    content: Optional[str] = None
                    include_in_archive, reason = get_archive_file_status(
                        filepath, exclude_files
                    )

                    if not include_in_archive:
                        logging.info(
                            "  - Skipping excluded file: %s (%s)",
                            relative_path_str,
                            reason,
                        )
                        files_skipped_count += 1
                        continue

                    try:
                        # Step 1: Specifically handle Jupyter Notebooks.
                        if filepath.suffix.lower() == ".ipynb":
                            logging.info(
                                "  + Processing Notebook: %s", relative_path_str
                            )
                            content = process_notebook(filepath)
                        # Step 2: Handle general text files.
                        elif is_likely_text_file(filepath):
                            logging.info(
                                "  + Processing Text File: %s", relative_path_str
                            )
                            with open(
                                filepath, "r", encoding="utf-8", errors="replace"
                            ) as infile:
                                content = infile.read()
                        # Step 3: The inclusion classifier should have filtered
                        # everything else already, but keep a safe fallback.
                        else:
                            logging.info(
                                "  - Skipping binary/excluded file: %s",
                                relative_path_str,
                            )
                            files_skipped_count += 1
                            continue

                        # Write content to the output file if it's not empty.
                        if content and content.strip():
                            outfile.write(f"<{relative_path_str}>\n")
                            outfile.write(content.strip())
                            outfile.write(f"\n</{relative_path_str}>\n\n")
                            files_processed_count += 1
                        else:
                            files_skipped_count += 1
                            logging.info(
                                "    No content extracted from %s", relative_path_str
                            )

                    except Exception as e:
                        files_skipped_count += 1
                        logging.error(
                            "Could not read file %s: %s", relative_path_str, e
                        )

        logging.info("\n--- Summary ---")
        logging.info("Successfully processed %d files.", files_processed_count)
        logging.info(
            "Skipped %d binary, excluded, or unreadable files.", files_skipped_count
        )
        logging.info("Combined output saved to: %s", output_filepath)

    except IOError as e:
        logging.error("Could not write to output file %s: %s", output_filepath, e)
    except Exception as e:
        logging.error("An unexpected error occurred: %s", e)


def main() -> None:
    parser = argparse.ArgumentParser(description="Combine project source files")
    parser.add_argument(
        "--root",
        type=Path,
        default=PROJECT_ROOT,
        help="Project root directory",
    )
    parser.add_argument(
        "--output",
        default=OUTPUT_FILENAME,
        help="Name of the output file",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG"],
        help="Logging level",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(levelname)s: %(message)s",
    )

    combine_project_files(args.root.resolve(), args.output)


if __name__ == "__main__":
    main()
