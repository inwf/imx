import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.parse import quote, urlencode


ARCHITECTURES = ("x86_64", "aarch64")
CACHE_PREFIX = "imx-zig-v1-Linux-"


def api(repository, path, *, paginate=False, method="GET"):
    command = ["gh", "api", "--method", method, f"repos/{repository}/{path}"]
    if paginate:
        command.extend(["--paginate", "--slurp"])
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def reusable_run(repository, sha):
    query = urlencode({"event": "push", "branch": "main", "head_sha": sha, "per_page": 100})
    discovery_deadline = time.monotonic() + 60
    deadline = time.monotonic() + 30 * 60
    while True:
        pages = api(repository, f"actions/workflows/release.yml/runs?{query}", paginate=True)
        candidates = [
            run for page in pages for run in page["workflow_runs"]
            if run["head_sha"] == sha and run["event"] == "push" and run["head_branch"] == "main"
            and run["head_repository"]["full_name"] == repository
        ]
        if not candidates:
            if time.monotonic() >= discovery_deadline or api(repository, "commits/main")["sha"] != sha:
                print("No main build is available; a build is required.", flush=True)
                return ""
            print("Waiting for the main build to start.", flush=True)
            time.sleep(10)
            continue
        run = max(candidates, key=lambda item: item["id"])
        if run["status"] == "completed":
            if run["conclusion"] != "success":
                raise RuntimeError(f"主分支检查未通过：{run['html_url']} ({run['conclusion']})")
            pages = api(repository, f"actions/runs/{run['id']}/artifacts?per_page=100", paginate=True)
            artifacts = [item for page in pages for item in page["artifacts"]]
            required = {f"imx-{architecture}" for architecture in ARCHITECTURES}
            valid = [
                item for item in artifacts if item["name"] in required and not item["expired"]
                and datetime.fromisoformat(item["expires_at"]) > datetime.now(timezone.utc) + timedelta(minutes=10)
                and item["workflow_run"]["head_sha"] == sha
            ]
            if len(valid) != len(required) or {item["name"] for item in valid} != required:
                print("Main build artifacts are unavailable or expiring; a build is required.", flush=True)
                return ""
            print(f"Reusing verified artifacts from {run['html_url']}", flush=True)
            return str(run["id"])
        if time.monotonic() >= deadline:
            raise TimeoutError(f"等待主分支检查超时：{run['html_url']}")
        print(f"Waiting for {run['html_url']} ({run['status']}).", flush=True)
        time.sleep(20)


def prepare(repository):
    tag = os.environ.get("RELEASE_TAG", "")
    if tag:
        if not tag.startswith("v"):
            raise ValueError("发布标签需要以 v 开头")
        sha = api(repository, f"commits/{quote('refs/tags/' + tag, safe='')}")["sha"]
        run_id = reusable_run(repository, sha)
    else:
        sha = subprocess.run(["git", "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        run_id = ""
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"sha={sha}\nrun_id={run_id}\n")
    print(f"Selected commit {sha}; artifact run: {run_id or 'current run'}", flush=True)


def prune(repository, dry_run):
    query = urlencode({"key": CACHE_PREFIX, "ref": "refs/heads/main", "per_page": 100})
    pages = api(repository, f"actions/caches?{query}", paginate=True)
    caches = [item for page in pages for item in page["actions_caches"]]
    summary = ["## Compilation caches", "", "| Architecture | Stored caches | Size |", "| --- | --- | --- |"]
    for architecture in ARCHITECTURES:
        entries = sorted(
            (item for item in caches if item["ref"] == "refs/heads/main"
             and item["key"].startswith(f"{CACHE_PREFIX}{architecture}-")),
            key=lambda item: (item["created_at"], item["id"]), reverse=True,
        )
        for item in entries[2:]:
            print(f"{'Would remove' if dry_run else 'Removing'} cache {item['id']}: {item['key']}", flush=True)
            if not dry_run:
                api(repository, f"actions/caches/{item['id']}", method="DELETE")
        retained = entries if dry_run else entries[:2]
        size = sum(item["size_in_bytes"] for item in retained)
        print(f"{architecture}: {len(retained)} caches, {size / 1024**2:.1f} MiB", flush=True)
        summary.append(f"| {architecture} | {len(retained)} | {size / 1024**2:.1f} MiB |")
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write("\n".join(summary) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"), required="GITHUB_REPOSITORY" not in os.environ)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    reuse = commands.add_parser("reuse")
    reuse.add_argument("--sha", required=True)
    cleanup = commands.add_parser("prune")
    cleanup.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.repository)
    elif args.command == "reuse":
        print(reusable_run(args.repository, args.sha))
    else:
        prune(args.repository, args.dry_run)


if __name__ == "__main__":
    main()
