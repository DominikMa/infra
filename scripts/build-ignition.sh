#!/usr/bin/env bash
set -euo pipefail
umask 077

machine=${1-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"${script_dir}/validate-machine.sh" "${machine}"
source "${script_dir}/lib.sh"
validate_local_inputs "${machine}"

output_dir="${repo_root}/build/${machine}"
mkdir -p "${output_dir}"
common_ign="${output_dir}/common.ign"
machine_ign="${output_dir}/${machine}.ign"

if [[ -e "${common_ign}" ]]; then
    chmod 0600 "${common_ign}"
fi
if [[ -e "${machine_ign}" ]]; then
    chmod 0600 "${machine_ign}"
fi

podman_run -v "${repo_root}:/work:ro" \
    -v "${repo_root}/local/${machine}:/machine-local:ro" "${BUTANE_IMAGE}" \
    --strict --pretty --files-dir /machine-local /work/ignition/common.bu \
    > "${common_ign}"
chmod 0600 "${common_ign}"

podman_run -v "${repo_root}:/work:ro" \
    "${BUTANE_IMAGE}" --strict --pretty --files-dir /work \
    "/work/ignition/${machine}.bu" > "${machine_ign}"
chmod 0600 "${machine_ign}"

podman_run -v "${machine_ign}:/config.ign:ro" \
    "${IGNITION_VALIDATE_IMAGE}" /config.ign

echo "Erzeugt: build/${machine}/${machine}.ign"
