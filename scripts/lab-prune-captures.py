#!/usr/bin/env python3
import os
import time
from pathlib import Path

ROOT = Path("/srv/network-lab/captures")
TTL_SECONDS = 14 * 24 * 60 * 60
MAX_TOTAL_BYTES = 5 * 1024**3

now = time.time()
files = []

# Do not follow symlinks.
for current, dirs, names in os.walk(ROOT, followlinks=False):
    dirs[:] = [
        d for d in dirs
        if not (Path(current) / d).is_symlink()
    ]

    for name in names:
        path = Path(current) / name

        try:
            if path.is_symlink() or not path.is_file():
                continue

            st = path.stat(follow_symlinks=False)
            files.append((path, st.st_mtime, st.st_size))
        except OSError as exc:
            print(f"Cannot inspect {path}: {exc}")

# Delete files older than 14 days.
remaining = []

for path, mtime, size in files:
    if now - mtime > TTL_SECONDS:
        try:
            path.unlink()
            print(f"Expired: {path}")
        except OSError as exc:
            print(f"Cannot delete {path}: {exc}")
    else:
        remaining.append((path, mtime, size))

# Enforce a logical total-storage limit by removing oldest files.
# This is NOT a filesystem-enforced quota.
total = sum(size for _, _, size in remaining)

for path, mtime, size in sorted(remaining, key=lambda x: x[1]):
    if total <= MAX_TOTAL_BYTES:
        break

    try:
        path.unlink()
        total -= size
        print(f"Quota cleanup: {path}")
    except OSError as exc:
        print(f"Cannot delete {path}: {exc}")

print(f"Remaining regular-file size: {total} bytes")
