#!/usr/bin/env python3
"""Redact a generated DR report so it can be shared (e.g. docs/sample_rto_report.html).

Replaces project IDs/numbers, vault suffixes, backup/operation IDs, e-mail addresses
and internal IPs with stable placeholders. Timings, sizes, regions and resource
names are kept, so the RTO figures stay meaningful.

Usage:
  scripts/redact_report.py dr_test_report.html docs/sample_rto_report.html \
      --project argo-svc-dev-7=workload-project --project argo-svc-dev-6=backup-project ...
Projects not given explicitly are taken from terraform.tfvars (if present) and
mapped by role.
"""
import argparse
import os
import re
import sys

ROLE_VARS = [  # tfvars key -> placeholder (first match wins per project)
    ("vault_project_id", "backup-project"),
    ("gcbdr_project_id", "backup-project"),
    ("project_id", "workload-project"),
    ("infra_prod_project_id", "workload-project"),
    ("dr_project_id", "dr-project"),
    ("host_project_id", "network-kms-project"),
    ("kms_project_id", "network-kms-project"),
]


def tfvars_projects(path):
    mapping = {}
    if not os.path.exists(path):
        return mapping
    text = open(path, encoding="utf-8").read()
    for key, placeholder in ROLE_VARS:
        m = re.search(rf'^\s*{key}\s*=\s*"([^"]+)"', text, re.M)
        if m and m.group(1) and m.group(1) not in mapping:
            mapping[m.group(1)] = placeholder
    return mapping


def redact(html, projects):
    # Longest first so "proj-1" never clobbers "proj-10".
    for real in sorted(projects, key=len, reverse=True):
        html = re.sub(rf"(?<![\w-]){re.escape(real)}(?![\w-])", projects[real], html)
    # Vault / key-ring random suffixes: bv-...-<8 hex>, kr-...-<8 hex>
    html = re.sub(r"\b((?:bv|kr|k)-[a-z0-9-]*?-)[0-9a-f]{8}\b", r"\1xxxxxxxx", html)
    # Backup image / generic UUIDs
    html = re.sub(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
                  "00000000-0000-0000-0000-000000000000", html)
    html = re.sub(r"\boperation-[0-9a-f-]{16,}\b", "operation-REDACTED", html)
    html = re.sub(r"\bprojects/\d{6,}\b", "projects/000000000000", html)
    html = re.sub(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", "user@example.com", html)
    html = re.sub(r"\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", "10.x.x.x", html)
    return html


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--project", action="append", default=[], help="REAL=PLACEHOLDER (repeatable)")
    ap.add_argument("--tfvars", default="terraform.tfvars")
    a = ap.parse_args()

    projects = tfvars_projects(a.tfvars)
    for pair in a.project:
        real, _, ph = pair.partition("=")
        projects[real] = ph or "project"

    out = redact(open(a.src, encoding="utf-8").read(), projects)
    leftovers = [p for p in projects if p in out]
    if leftovers:
        sys.exit(f"[ERROR] project IDs still present: {leftovers}")
    open(a.dst, "w", encoding="utf-8").write(out)
    print(f"[INFO] Redacted {a.src} -> {a.dst} ({len(projects)} project IDs mapped)")


if __name__ == "__main__":
    main()
