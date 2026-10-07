#!/usr/bin/env python3
"""Fetch GitHub Actions run status, job steps and failed job logs.

Usage:
    python Tools/gh_actions_report.py <token> [owner/repo] [run-id]

Output: Tools/out/gh-actions.txt (git-ignored). Job logs are fetched with curl -L
because the logs endpoint redirects to a temporary blob URL.
"""

from __future__ import annotations

import json
import os
import subprocess
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
            "User-Agent": "YPlayer-actions",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8")
        return error.code, {"error": body[:800]}


def fetch_log(token: str, repo: str, job_id: int, out_path: str) -> tuple[int, int]:
    url = f"{API}/repos/{repo}/actions/jobs/{job_id}/logs"
    result = subprocess.run(
        ["curl.exe", "-sL", "-H", f"Authorization: Bearer {token}", "-o", out_path, url],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=180,
    )
    size = os.path.getsize(out_path) if os.path.exists(out_path) else 0
    return result.returncode, size


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python Tools/gh_actions_report.py <token> [owner/repo] [run-id]")
        return 2

    token = sys.argv[1]
    repo = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "Tools", "out")
    os.makedirs(out_dir, exist_ok=True)

    lines: list[str] = [f"repo = {repo}"]

    status, runs = api(token, f"/repos/{repo}/actions/runs?per_page=10")
    lines.append(f"runs -> {status}")
    run_id = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    for run in runs.get("workflow_runs", []):
        lines.append(
            f"run {run['id']} | {run['name']} | {run['status']}/{run['conclusion']} | "
            f"sha={run['head_sha'][:8]} | event={run['event']}"
        )
        if not run_id:
            run_id = run["id"]

    if not run_id:
        write(lines, out_dir)
        return 0

    status, jobs = api(token, f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=50")
    lines.append(f"\njobs for run {run_id} -> {status}")
    for job in jobs.get("jobs", []):
        lines.append(f"\nJOB | {job['name']} | {job['status']}/{job['conclusion']} | id={job['id']}")
        for step in job.get("steps", []):
            mark = "FAIL" if step.get("conclusion") == "failure" else step.get("conclusion")
            lines.append(f"   {step['number']:>2}. {step['name']} | {mark}")

        if job.get("conclusion") != "failure":
            continue
        log_path = os.path.join(out_dir, f"job-{job['id']}.log")
        code, size = fetch_log(token, repo, job["id"], log_path)
        lines.append(f"\n--- LOG job={job['id']} curl={code} bytes={size} tail 9000 ---")
        if size:
            with open(log_path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            lines.append(text[-9000:])

    write(lines, out_dir)
    print("\n".join(lines[:40]))
    return 0


def write(lines: list[str], out_dir: str) -> None:
    path = os.path.join(out_dir, "gh-actions.txt")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
