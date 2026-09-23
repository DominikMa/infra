#!/usr/bin/bash
set -euo pipefail

config_root=${CONFIG_ROOT-}
if [[ -n "${config_root}" && "${config_root}" != /* ]]; then
    echo "CONFIG_ROOT must be an absolute path." >&2
    exit 2
fi

for owner_and_path in \
    "1010:1010:${config_root}/etc/container-services/headscale" \
    "1011:1011:${config_root}/etc/container-services/caddy" \
    "1012:1012:${config_root}/etc/container-services/adguard" \
    "1013:1013:${config_root}/etc/container-services/vaultwarden"; do
    owner=${owner_and_path%%:*}
    remainder=${owner_and_path#*:}
    group=${remainder%%:*}
    path=${remainder#*:}
    if [[ ! -d "${path}" ]]; then
        echo "Service configuration directory is missing: ${path}" >&2
        exit 1
    fi
    chown -R --no-dereference "${owner}:${group}" "${path}"
done

for network_profile_name in \
    luebeck-lan.nmconnection \
    luebeck-bridge-enp2s0.nmconnection \
    luebeck-bridge-enp3s0.nmconnection; do
    network_profile="${config_root}/etc/NetworkManager/system-connections/${network_profile_name}"
    if [[ ! -f "${network_profile}" ]]; then
        echo "NetworkManager profile is missing: ${network_profile}" >&2
        exit 1
    fi
    chown root:root "${network_profile}"
    chmod 0600 "${network_profile}"
done
