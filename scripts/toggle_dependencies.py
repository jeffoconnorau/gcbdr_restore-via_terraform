#!/usr/bin/env python3
"""Toggle restore dependency gates between concurrent and sequential modes.

Terraform builds its DAG statically, so sequential phasing (AlloyDB -> Cloud SQL /
Filestore -> VMs) is enabled by un-commenting label references to the
terraform_data phase barriers in restore_orchestration.tf.

Two gate styles are supported:
  * Multi-line blocks delimited by marker comments (restore.tf):
        # [dependency_gate:begin] ...
        # labels {
        #   key   = "dependency_gate"
        #   value = var.enforce_dr_dependencies ? terraform_data.phase_2_complete[0].id : "none"
        # }
        # [dependency_gate:end]
  * Single-line map entries (restore_sql.tf, restore_filestore.tf):
        # dependency_gate = var.enforce_dr_dependencies ? terraform_data.phase_1_complete[0].id : "none"

The transformation is idempotent: running the same mode twice is a no-op.

Usage: python3 scripts/toggle_dependencies.py [parallel|sequential]
"""

import os
import re
import sys

FILES = ["restore_sql.tf", "restore_filestore.tf", "restore.tf"]
BEGIN = "[dependency_gate:begin]"
END = "[dependency_gate:end]"
SINGLE_LINE = re.compile(r"^(\s*)(#\s*)?(dependency_gate\s*=\s*var\.enforce_dr_dependencies\b.*)$")
COMMENTED = re.compile(r"^(\s*)#\s?(.*)$")


def comment(line, indent):
    """Insert '# ' at the marker's indentation so round-trips are byte-exact."""
    if not line.strip() or line[len(indent):].startswith("#"):
        return line
    return f"{indent}# {line[len(indent):]}"


def uncomment(line, indent):
    body = line[len(indent):]
    if line.startswith(indent) and body.startswith("# "):
        return indent + body[2:]
    m = COMMENTED.match(line)
    return f"{m.group(1)}{m.group(2)}" if m else line


def toggle_text(text, mode):
    out = []
    in_block = False
    indent = ""
    for line in text.splitlines():
        stripped = line.strip()
        if BEGIN in stripped:
            in_block = True
            indent = line[: len(line) - len(line.lstrip())]
            out.append(line)
            continue
        if END in stripped:
            in_block = False
            out.append(line)
            continue
        if in_block:
            out.append(comment(line, indent) if mode == "parallel" else uncomment(line, indent))
            continue
        m = SINGLE_LINE.match(line)
        if m:
            lead, _, body = m.groups()
            out.append(f"{lead}# {body}" if mode == "parallel" else f"{lead}{body}")
            continue
        out.append(line)
    if in_block:
        raise ValueError(f"Unterminated {BEGIN} marker")
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("parallel", "sequential"):
        print("Usage: python3 scripts/toggle_dependencies.py [parallel|sequential]")
        sys.exit(1)
    mode = sys.argv[1]
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    print(f"Toggling dependencies to: {mode}")
    for fname in FILES:
        path = os.path.join(root, fname)
        if not os.path.exists(path):
            continue
        with open(path) as f:
            original = f.read()
        updated = toggle_text(original, mode)
        if updated != original:
            with open(path, "w") as f:
                f.write(updated)
            print(f"Updated {fname}")
        else:
            print(f"Unchanged {fname}")
    if mode == "sequential":
        print("Reminder: also set enforce_dr_dependencies = true so gate labels carry the phase barrier IDs.")


if __name__ == "__main__":
    main()
