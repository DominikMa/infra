#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${script_dir}/lib.sh"
failures=0

expect_machine_failure() {
    local target=$1 machine=${2-} before after
    before=$(find "${repo_root}/build" -type f 2>/dev/null | sort || true)
    if make --no-print-directory -s -C "${repo_root}" "${target}" MACHINE="${machine}" >/dev/null 2>&1; then
        echo "Fehler: make ${target} MACHINE='${machine}' haette fehlschlagen muessen." >&2
        failures=$((failures + 1))
    fi
    after=$(find "${repo_root}/build" -type f 2>/dev/null | sort || true)
    if [[ "${before}" != "${after}" ]]; then
        echo "Fehler: ungueltiges MACHINE hat Dateien erzeugt." >&2
        failures=$((failures + 1))
    fi
}

for target in ignition iso installer; do
    expect_machine_failure "${target}" ""
done
expect_machine_failure ignition does-not-exist

for ignored in local/luebeck/authorized_keys build/luebeck/test.ign test.iso cosign.key; do
    if ! git -C "${repo_root}" check-ignore -q "${ignored}"; then
        echo "Fehler: ${ignored} wird nicht von .gitignore geschuetzt." >&2
        failures=$((failures + 1))
    fi
done
if git -C "${repo_root}" ls-files | grep -Eq '(^local/|^build/|\.ign$|\.iso$|^cosign\.(key|private)$)'; then
    echo "Fehler: private oder generierte Dateien sind in Git erfasst." >&2
    failures=$((failures + 1))
fi
[[ ${failures} -eq 0 ]] || exit 1

command -v podman >/dev/null || { echo "Fehler: podman wird fuer make check benoetigt." >&2; exit 1; }
check_dir=$(mktemp -d)
trap 'rm -rf -- "${check_dir}"' EXIT
mkdir -p "${check_dir}/build/luebeck" "${check_dir}/local/luebeck"
cp "${repo_root}/tests/fixtures/authorized_keys" "${check_dir}/local/luebeck/authorized_keys"
cp "${repo_root}/tests/fixtures/image-ref" "${check_dir}/local/luebeck/image-ref"
mkdir -p "${check_dir}/repo"
cp -R "${repo_root}/recipes" "${repo_root}/files" "${check_dir}/repo/"

podman_run -v "${repo_root}:/repo:ro" -v "${check_dir}:/files" "${BUTANE_IMAGE}" \
    --strict --pretty --files-dir /files /repo/ignition/common.bu \
    > "${check_dir}/build/luebeck/common.ign"
podman_run -v "${repo_root}:/repo:ro" -v "${check_dir}:/files:ro" "${BUTANE_IMAGE}" \
    --strict --pretty --files-dir /files /repo/ignition/luebeck.bu \
    > "${check_dir}/luebeck.ign"
podman_run -v "${check_dir}/luebeck.ign:/config.ign:ro" \
    "${IGNITION_VALIDATE_IMAGE}" /config.ign

podman_run -v "${check_dir}/repo:/repo" -w /repo "${BLUEBUILD_IMAGE}" \
    /usr/bin/bluebuild generate --display-full-recipe recipes/luebeck.yml \
    > "${check_dir}/expanded-recipe.yml"

grep -q 'ostree-unverified-registry:' "${repo_root}/ignition/common.bu"
grep -q 'ostree-image-signed:docker://' "${repo_root}/ignition/common.bu"
grep -q '"format": "btrfs"' "${check_dir}/luebeck.ign"
grep -q '"number": 4' "${check_dir}/luebeck.ign"
grep -q '"sizeMiB": 0' "${check_dir}/luebeck.ign"
grep -q '^dest-device: /dev/nvme0n1$' "${repo_root}/installer/luebeck.yaml"
grep -q '^offline: true$' "${repo_root}/installer/luebeck.yaml"
grep -q '^copy-network: true$' "${repo_root}/installer/luebeck.yaml"

echo "Alle Konfigurationen und Schutzregeln sind gueltig."
