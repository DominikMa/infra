#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${script_dir}/lib.sh"

machine=${1-}
"${script_dir}/validate-machine.sh" "${machine}"

command -v bluebuild >/dev/null || {
    echo "Fehler: bluebuild wird fuer das Veroeffentlichen des Images benoetigt." >&2
    exit 1
}
command -v podman >/dev/null || {
    echo "Fehler: podman wird fuer das Veroeffentlichen des Images benoetigt." >&2
    exit 1
}

recipe="${repo_root}/recipes/${machine}.yml"
image_ref_file="${repo_root}/local/${machine}/image-ref"
signing_key_file=${COSIGN_PRIVATE_KEY_FILE:-"${repo_root}/cosign.key"}

[[ -f "${recipe}" ]] || {
    echo "Fehler: Recipe ${recipe} fehlt." >&2
    exit 2
}
[[ -s "${image_ref_file}" ]] || {
    echo "Fehler: ${image_ref_file} fehlt oder ist leer." >&2
    exit 2
}

image_ref=$(tr -d '\n' < "${image_ref_file}")
if [[ $(wc -l < "${image_ref_file}") -ne 1 ]] ||
   [[ ! "${image_ref}" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+$ ]]; then
    echo "Fehler: ${image_ref_file} muss genau eine OCI-Referenz wie ghcr.io/owner/${machine}:stable enthalten." >&2
    exit 2
fi

registry=${image_ref%%/*}
repository_and_tag=${image_ref#*/}
repository=${repository_and_tag%:*}
namespace=${repository%/*}
image_name=${repository##*/}
image_tag=${repository_and_tag##*:}

if [[ "${image_name}" != "${machine}" ]]; then
    echo "Fehler: Image-Name '${image_name}' in ${image_ref_file} passt nicht zu MACHINE=${machine}." >&2
    exit 2
fi
if ! awk -v expected="${image_tag}" '
    /^alt-tags:[[:space:]]*$/ { inside = 1; next }
    inside && /^[^[:space:]]/ { inside = 0 }
    inside && $1 == "-" {
        tag = $2
        if (tag == expected) found = 1
    }
    END { exit !found }
' "${recipe}"; then
    echo "Fehler: Tag '${image_tag}' aus ${image_ref_file} fehlt unter alt-tags in ${recipe}." >&2
    exit 2
fi

registry_username=${GHCR_USERNAME:-${BB_USERNAME:-${namespace%%/*}}}
registry_token=${GHCR_TOKEN:-${BB_PASSWORD:-}}
if [[ -z "${registry_token}" ]]; then
    if [[ ! -t 0 ]]; then
        echo "Fehler: GHCR_TOKEN ist fuer einen nicht-interaktiven Push erforderlich." >&2
        exit 2
    fi
    read -rsp "Token fuer ${registry} (${registry_username}): " registry_token
    echo
fi
[[ -n "${registry_token}" ]] || {
    echo "Fehler: der Registry-Token darf nicht leer sein." >&2
    exit 2
}

if [[ -z "${COSIGN_PRIVATE_KEY:-}" ]]; then
    [[ -r "${signing_key_file}" && -s "${signing_key_file}" ]] || {
        echo "Fehler: privater Cosign-Key ${signing_key_file} fehlt, ist leer oder nicht lesbar." >&2
        exit 2
    }
    COSIGN_PRIVATE_KEY=$(< "${signing_key_file}")
fi

echo "Baue, signiere und veroeffentliche ${image_ref}."
cd "${repo_root}"
BB_PASSWORD="${registry_token}" \
COSIGN_PRIVATE_KEY="${COSIGN_PRIVATE_KEY}" \
bluebuild build --push --build-driver podman \
    --registry "${registry}" \
    --registry-namespace "${namespace}" \
    --username "${registry_username}" \
    "${recipe}"
