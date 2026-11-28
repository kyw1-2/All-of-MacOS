#!/bin/bash
# CI only: give every tracked file the time of the last commit that touched
# it. actions/checkout stamps every file with the checkout time, which makes a
# restored .build cache look stale and recompiles all 560+ sources; with
# commit times, the Swift driver's incremental build recompiles only what
# changed since the cached build. Needs the full history (fetch-depth: 0).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
import os, subprocess
seen = set()
tracked = set(subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0"))
tracked.discard("")
log = subprocess.run(["git", "log", "--format=@%ct", "--name-only", "--no-renames", "-z"],
                     capture_output=True, check=True).stdout.decode()
stamp = None
for token in log.replace("\n", "\0").split("\0"):
    if not token:
        continue
    if token.startswith("@") and token[1:].isdigit():
        stamp = int(token[1:])
        continue
    if stamp is not None and token in tracked and token not in seen:
        seen.add(token)
        try:
            os.utime(token, (stamp, stamp), follow_symlinks=False)
        except FileNotFoundError:
            pass
print(f"restored modification times of {len(seen)} of {len(tracked)} tracked files")
PY
