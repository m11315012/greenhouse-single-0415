#!/bin/bash
# Greenhouse batch rehosting for D-Link DNR/DNS/DWC series firmware.

set -euo pipefail

GREENHOUSE_IMAGE="greenhouse:patched"
BRAND="dlink"
OUTDIR="./results/batch_dnr_dns_dwc"
MAX_CYCLES=26
PORTS="80,81"
IP="172.21.0.2"
REHOST_TYPE="HTTP"
REHOST_FIRST=""
DO_SCREENSHOT=false
SCREENSHOT_WAIT=60

FW_ROOT="/home/m11315012/Firmware-Dataset/dlink_fws"

log()  { echo "[*] $(date '+%H:%M:%S') $*"; }
warn() { echo "[!] $(date '+%H:%M:%S') $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --outdir)           OUTDIR="$2";         shift 2 ;;
        --max-cycles)       MAX_CYCLES="$2";     shift 2 ;;
        --rehost-first)     REHOST_FIRST="-rh";  shift ;;
        --screenshot)       DO_SCREENSHOT=true;  shift ;;
        --screenshot-wait)  SCREENSHOT_WAIT="$2"; shift 2 ;;
        -h|--help) cat <<HELP
Usage: $0 [--outdir DIR] [--screenshot] [--screenshot-wait N]
HELP
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

STAGING_DIR=$(mktemp -d /tmp/gh_batch_XXXXXX)
log "Collecting DNR/DNS/DWC firmware from $FW_ROOT ..."

find -L "$FW_ROOT" -maxdepth 2 -type f \
    \( -iname "*.zip" -o -iname "*.bin" -o -iname "*.img" \) \
    | grep -E "/DN[HR]|/DNS|/DWC" \
    | grep -v "DNR-150N_REVA_FIRMWARE_v3.11" \
    | while read -r f; do
        cp "$f" "$STAGING_DIR/"
        log "  + $(basename "$f")"
    done

FILE_COUNT=$(ls "$STAGING_DIR" | wc -l)
[[ "$FILE_COUNT" -eq 0 ]] && { rm -rf "$STAGING_DIR"; die "No firmware files found."; }
log "Found $FILE_COUNT firmware file(s)."

docker image inspect "$GREENHOUSE_IMAGE" &>/dev/null \
    || die "Docker image '$GREENHOUSE_IMAGE' not found."

log "Starting Greenhouse container..."
CONTAINER=$(docker run -d --privileged -v /dev:/host/dev "$GREENHOUSE_IMAGE" sleep infinity)
log "Container ID: $CONTAINER"

cleanup() {
    log "Stopping container $CONTAINER ..."
    docker stop "$CONTAINER" &>/dev/null || true
    docker rm   "$CONTAINER" &>/dev/null || true
    rm -rf "$STAGING_DIR"
    docker network ls -q --filter "name=ghbridge" 2>/dev/null | xargs -r docker network rm 2>/dev/null || true
    docker images --filter "reference=debug_gh_rehosted*" -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
    docker images -f "dangling=true" -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
}
trap cleanup EXIT

log "Initializing container environment..."
docker exec "$CONTAINER" /gh/docker_init.sh
log "Patching FirmAE run.sh..."
docker cp ./FirmAEreplacements/run.sh "$CONTAINER:/work/FirmAE/run.sh"
docker cp ./Greenhouse/backend/Planter.py "$CONTAINER:/gh/backend/Planter.py"

log "Copying firmware into container at /batch_input/${BRAND}/ ..."
docker exec "$CONTAINER" mkdir -p "/batch_input/${BRAND}"
docker cp "$STAGING_DIR/." "$CONTAINER:/batch_input/${BRAND}/"

mkdir -p "$OUTDIR"
log "Starting batch rehost — results: $OUTDIR"

docker exec "$CONTAINER" bash -c "
    source /root/venv/bin/activate
    mkdir -p /gh/results /gh/scratch
    cd /gh
    timeout 864000 python3 /gh/gh.py \
        --batchfolder /batch_input/${BRAND} \
        --brand=${BRAND} \
        --outpath /gh/results \
        --workspace /gh/scratch \
        --firmae /work/FirmAE \
        --cache_path=/cache \
        --ip ${IP} \
        --ports='${PORTS}' \
        --max_cycles=${MAX_CYCLES} \
        --rehost_type=${REHOST_TYPE} \
        --logpath=/tmp/batch.log \
        ${REHOST_FIRST} 2>&1
" | tee "$OUTDIR/batch.log"

log "Copying results back to $OUTDIR ..."
docker cp "$CONTAINER:/gh/results/." "$OUTDIR/firmware_results/" 2>/dev/null || warn "No results in container"
docker cp "$CONTAINER:/tmp/batch.log" "$OUTDIR/batch.log" 2>/dev/null || true

if [[ -d "$OUTDIR/firmware_results" ]]; then
    log "Generating summary CSV..."
    python3 - <<PYEOF > "$OUTDIR/summary.csv"
import json, glob
print("firmware,result,brand,ip,port,seconds_to_up,target_bin,login_user,login_url")
for f in sorted(glob.glob("$OUTDIR/firmware_results/*/config.json")):
    try:
        d = json.load(open(f))
        print(",".join(str(d.get(k,"")) for k in [
            "image","result","brand","targetip","targetport",
            "seconds_to_up","targetpath","loginuser","loginurl"
        ]))
    except Exception as e:
        print(f"# error: {e}")
PYEOF
    log "Summary CSV: $OUTDIR/summary.csv"
    cat "$OUTDIR/summary.csv"
fi

log "All done. Results: $OUTDIR"
trap - EXIT
cleanup
