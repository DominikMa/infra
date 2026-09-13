#!/usr/bin/env bash
set -euo pipefail

subid_root=${SUBID_ROOT-}
if [[ -n "${subid_root}" && "${subid_root}" != /* ]]; then
    echo "SUBID_ROOT must be an absolute path." >&2
    exit 2
fi

ensure_subid() {
    local file=$1 user=$2 start=$3 count=$4 end
    end=$((start + count - 1))
    if [[ ! -e "${file}" ]]; then
        install -m 0644 /dev/null "${file}"
    fi

    if grep -q "^${user}:" "${file}"; then
        if ! grep -qx "${user}:${start}:${count}" "${file}"; then
            echo "Unexpected existing subordinate-ID allocation for ${user} in ${file}." >&2
            exit 1
        fi
        return
    fi

    if ! awk -F: -v wanted_start="${start}" -v wanted_end="${end}" '
        NF == 3 {
            existing_start = $2
            existing_end = $2 + $3 - 1
            if (wanted_start <= existing_end && existing_start <= wanted_end) {
                exit 1
            }
        }
    ' "${file}"; then
        echo "Subordinate-ID range ${start}-${end} overlaps an existing entry in ${file}." >&2
        exit 1
    fi

    printf '%s:%s:%s\n' "${user}" "${start}" "${count}" >> "${file}"
}

ensure_subid "${subid_root}/etc/subuid" headscale 200000 65536
ensure_subid "${subid_root}/etc/subgid" headscale 200000 65536
ensure_subid "${subid_root}/etc/subuid" caddy 300000 65536
ensure_subid "${subid_root}/etc/subgid" caddy 300000 65536
ensure_subid "${subid_root}/etc/subuid" adguard 400000 65536
ensure_subid "${subid_root}/etc/subgid" adguard 400000 65536
