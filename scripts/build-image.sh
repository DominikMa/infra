#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${script_dir}/lib.sh"

machine=${1-}
"${script_dir}/validate-machine.sh" "${machine}"

command -v bluebuild >/dev/null || {
    echo "Fehler: bluebuild wird fuer den lokalen Image-Build benoetigt." >&2
    exit 1
}
command -v podman >/dev/null || {
    echo "Fehler: podman wird fuer den lokalen Image-Build benoetigt." >&2
    exit 1
}

recipe="${repo_root}/recipes/${machine}.yml"
[[ -f "${recipe}" ]] || {
    echo "Fehler: Recipe ${recipe} fehlt." >&2
    exit 2
}

cd "${repo_root}"
exec bluebuild build --build-driver podman "${recipe}"
