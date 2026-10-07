#!/usr/bin/env python3
"""Probe GitHub Actions state for a repository (workflows, runs, check-runs).

Usage:
    python Tools/gh_probe.py <token> [owner/repo] [ref-sha]

Output: Tools/out/gh-probe.txt (git-ignored).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
DEFAULT_REPO = "1970905901/Y-Player"


def api(token: str, path: str) -> tuple[int, dict]:
    request = urllib.request.Request(
        API + path,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "YPlayer-probe",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        return error.code, {"error": error.read().decode("utf-8")[:600]}


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python Tools/gh_probe.py <token> [owner/repo] [ref-sha]")
        return 2

    token = sys.argv[1]
    repo = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO
    sha = sys.argv[3] if len(sys.argv) > 3 else "96887a5"

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "Tools", "out")
    os.makedirs(out_dir, exist_ok=True)

    lines = [f"repo = {repo}", f"sha = {sha}"]

    status, repo_info = api(token, f"/repos/{repo}")
    lines.append(
        f"repo -> {status} private={repo_info.get('private')} default={repo_info.get('default_branch')} "
        f"pushed_at={repo_info.get('pushed_at')}"
    )

    status, workflows = api(token, f"/repos/{repo}/actions/workflows")
    lines.append(f"\nworkflows -> {status} total={workflows.get('total_count')}")
    for workflow in workflows.get("workflows", []):
        lines.append(
            f"  {workflow.get('name')} | state={workflow.get('state')} | path={workflow.get('path')}"
        )

    status, runs = api(token, f"/repos/{repo}/actions/runs?per_page=20")
    lines.append(f"\nruns -> {status} total_count={runs.get('total_count')}")
    for run in runs.get("workflow_runs", []):
        lines.append(
            f"  run {run['id']} | {run['name']} | {run['status']}/{run['conclusion']} | "
            f"sha={run['head_sha'][:8]} | created={run['created_at']} | event={run['event']}"
        )

    status, checks = api(token, f"/repos/{repo}/commits/{sha}/check-runs")
    lines.append(f"\ncheck-runs for {sha} -> {status} total={checks.get('total_count')}")
    for check in checks.get("check_runs", []):
        lines.append(
            f"  {check.get('name')} | {check.get('status')}/{check.get('conclusion')} | "
            f"started={check.get('started_at')}"
        )

    path = os.path.join(out_dir, "gh-probe.txt")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
