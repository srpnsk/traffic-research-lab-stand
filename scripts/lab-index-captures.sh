#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/srv/network-lab/captures"

find "$ROOT" -type f \
    \( -name '*.pcap' -o -name '*.pcapng' \) -print0 |
    while IFS= read -r -d '' file; do
        [[ -L "$file" ]] && continue

        metadata="${file}.meta.txt"
        tmp="${metadata}.tmp"

        if capinfos -a -e -c -s -H "$file" >"$tmp"; then
            mv -- "$tmp" "$metadata"
            touch -r "$file" "$metadata"
        else
            rm -f -- "$tmp"
            echo "Could not inspect: $file" >&2
        fi
    done
