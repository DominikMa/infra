#!/usr/bin/env bash
set -euo pipefail

machine=${1-}
if [[ -z "${machine}" ]]; then
    echo "Fehler: MACHINE ist erforderlich (z. B. MACHINE=luebeck)." >&2
    exit 2
fi
case "${machine}" in
    luebeck) ;;
    *)
        echo "Fehler: unbekannte Maschine '${machine}'. Bekannt: luebeck." >&2
        exit 2
        ;;
esac
