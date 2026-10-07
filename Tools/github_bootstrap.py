#!/usr/bin/env python3
"""Bootstrap the GitHub repository and push the initial commits.

Usage:
    python Tools/github_bootstrap.py <token> [repo-name]

Safety notes:
    - The token is used only inside this process for HTTPS calls and the one-shot push URL.
    - It is never written to disk or to any repository file; log output masks it.
    - After the push the `origin` remote is reset to the clean URL (no token).
    - Output: Tools/out/gh-bootstrap.txt (git-ignored).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
DEFAULT_REPO = "Y-Player"


def api(token: str, path: str, method: str = "GET", payload: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "YPlayer-bootstrap",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8") or "{}"
            return response.status, json.loads(body)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8")
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = {"raw": body}
        return error.code, parsed


def git(root: str, *args: str, timeout: int = 180) -> tuple[int, str]:
    """Run git non-interactively (never prompt for credentials) with a hard timeout."""
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GCM_INTERACTIVE"] = "never"
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
        )
        return result.returncode, (result.stdout + result.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, f"timeout after {timeout}s: git {' '.join(args)}"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python Tools/github_bootstrap.py <token> [repo-name]")
        return 2

    token = sys.argv[1]
    repo = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "Tools", "out")
    os.makedirs(out_dir, exist_ok=True)

    log: list[str] = [f"repo = {repo}"]

    status, user = api(token, "/user")
    if status != 200:
        log.append(f"FATAL: /user -> {status} {user}")
        write_log(log, out_dir)
        return 1
    login = user.get("login", "")
    log.append(f"user = {login}")
    write_log(log, out_dir)

    status, created = api(
        token,
        "/user/repos",
        "POST",
        {
            "name": repo,
            "private": True,
            "description": "YPlayer - Swift media shell for Apple platforms (iOS/iPadOS + macOS)",
            "has_issues": True,
            "has_wiki": False,
            "has_projects": False,
            "auto_init": False,
        },
    )
    log.append(f"create repo -> {status}" + ("" if status in (200, 201) else f" {created}"))
    write_log(log, out_dir)

    clean_url = f"https://github.com/{login}/{repo}.git"
    authed_url = f"https://{token}@github.com/{login}/{repo}.git"

    git(root, "remote", "remove", "origin")
    code, out = git(root, "remote", "add", "origin", clean_url)
    log.append(f"remote add origin -> {code} {out}".strip())

    git(root, "branch", "-M", "main")
    code, out = git(root, "push", authed_url, "main:main")
    log.append(f"push -> {code}")
    log.append(out.replace(token, "***").strip())
    write_log(log, out_dir)

    git(root, "fetch", "origin")
    code, out = git(root, "branch", "--set-upstream-to=origin/main", "main")
    log.append(f"set upstream -> {code} {out}".strip())

    code, out = git(root, "remote", "set-url", "origin", clean_url)
    log.append(f"remote set-url -> {code}")
    code, out = git(root, "remote", "-v")
    log.append("remotes:\n" + out)

    status, info = api(token, f"/repos/{login}/{repo}")
    log.append(
        f"repo info -> {status} full_name={info.get('full_name')} private={info.get('private')} "
        f"default_branch={info.get('default_branch')}"
    )

    # 等一小会儿让 Actions 起来，然后记录工作流状态
    time.sleep(25)
    status, runs = api(token, f"/repos/{login}/{repo}/actions/runs?per_page=5")
    log.append(f"workflow runs -> {status}")
    for run in runs.get("workflow_runs", []):
        log.append(
            f"  {run.get('name')} | {run.get('status')} | {run.get('conclusion')} | "
            f"{run.get('head_sha', '')[:8]} | {run.get('html_url')}"
        )

    write_log(log, out_dir)
    print("\n".join(log))
    return 0


def write_log(lines: list[str], out_dir: str) -> None:
    path = os.path.join(out_dir, "gh-bootstrap.txt")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
