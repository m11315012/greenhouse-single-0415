#!/bin/bash
# Greenhouse batch rehosting for D-Link DIR series firmware.
#
# Usage:
#   ./batch_dir.sh
#   ./batch_dir.sh --screenshot
#   ./batch_dir.sh --outdir ./results/batch_dir_v2

set -euo pipefail

GREENHOUSE_IMAGE="greenhouse:patched"
BRAND="dlink"
OUTDIR="./results/batch_dir"
MAX_CYCLES=26
PORTS="80,81"
IP="172.21.0.2"
REHOST_TYPE="HTTP"
REHOST_FIRST=""
DO_SCREENSHOT=false
SCREENSHOT_WAIT=60

# DIR firmware dataset path
DIR_FW_ROOT="/home/m11315012/Firmware-Dataset/dlink_fws"

log()  { echo "[*] $(date '+%H:%M:%S') $*"; }
warn() { echo "[!] $(date '+%H:%M:%S') $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --outdir DIR            Output directory (default: ./results/batch_dir)
  --max-cycles N          Max patch iterations per firmware (default: 26)
  --rehost-first          Enable FirmAE full-system rehost before patch loop
  --screenshot            Take screenshot of each successful firmware web UI
  --screenshot-wait N     Seconds to wait before screenshotting (default: 60)
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --outdir)            OUTDIR="$2";           shift 2 ;;
        --max-cycles)        MAX_CYCLES="$2";        shift 2 ;;
        --rehost-first)      REHOST_FIRST="-rh";    shift ;;
        --screenshot)        DO_SCREENSHOT=true;     shift ;;
        --screenshot-wait)   SCREENSHOT_WAIT="$2";   shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ── collect DIR firmware (exclude DD-WRT / webflash) ─────────────────────────

STAGING_DIR=$(mktemp -d /tmp/gh_batch_XXXXXX)
log "Collecting DIR firmware from $DIR_FW_ROOT ..."

find -L "$DIR_FW_ROOT" -maxdepth 2 -type f \
    \( -iname "*.zip" -o -iname "*.bin" -o -iname "*.img" -o -iname "*.trx" \) \
    | grep "/DIR" \
    | grep -v "factory-to-ddwrt\|webflash\|dd-wrt\|RELEASENOTES" \
    | while read -r f; do
        cp "$f" "$STAGING_DIR/"
        log "  + $(basename "$f")"
    done

# Also include DIR-868L from project root if present
find /home/m11315012/greenhouse-single-0415 -maxdepth 1 -type f -iname "DIR-868L*.zip" \
    | while read -r f; do
        cp "$f" "$STAGING_DIR/"
        log "  + $(basename "$f") (from project root)"
    done

FILE_COUNT=$(ls "$STAGING_DIR" | wc -l)
if [[ "$FILE_COUNT" -eq 0 ]]; then
    rm -rf "$STAGING_DIR"
    die "No DIR firmware files found."
fi
log "Found $FILE_COUNT DIR firmware file(s) to process."

# ── check Docker image ────────────────────────────────────────────────────────

docker image inspect "$GREENHOUSE_IMAGE" &>/dev/null \
    || die "Docker image '$GREENHOUSE_IMAGE' not found. Run './auto_run.sh --build' first."

# ── start container ───────────────────────────────────────────────────────────

log "Starting Greenhouse container..."
CONTAINER=$(docker run -d --privileged \
    -v /dev:/host/dev \
    "$GREENHOUSE_IMAGE" \
    sleep infinity)
log "Container ID: $CONTAINER"

cleanup() {
    log "Stopping container $CONTAINER ..."
    docker stop "$CONTAINER" &>/dev/null || true
    docker rm   "$CONTAINER" &>/dev/null || true
    rm -rf "$STAGING_DIR"

    STALE_NETS=$(docker network ls -q --filter "name=ghbridge" 2>/dev/null)
    if [[ -n "$STALE_NETS" ]]; then
        log "Removing stale Greenhouse networks..."
        echo "$STALE_NETS" | xargs docker network rm 2>/dev/null || true
    fi

    STALE_IMGS=$(docker images --filter "reference=debug_gh_rehosted*" -q 2>/dev/null)
    if [[ -n "$STALE_IMGS" ]]; then
        log "Removing rehosted firmware images..."
        echo "$STALE_IMGS" | xargs docker rmi -f 2>/dev/null || true
    fi

    DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null)
    if [[ -n "$DANGLING" ]]; then
        log "Removing dangling images..."
        echo "$DANGLING" | xargs docker rmi -f 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "Initializing container environment..."
docker exec "$CONTAINER" /gh/docker_init.sh

# Patch FirmAE run.sh (zombie QEMU fix)
log "Patching FirmAE run.sh (zombie QEMU fix)..."
docker cp ./FirmAEreplacements/run.sh "$CONTAINER:/work/FirmAE/run.sh"
docker cp ./Greenhouse/backend/Planter.py "$CONTAINER:/gh/backend/Planter.py"

# ── copy firmware into container ──────────────────────────────────────────────

log "Copying $FILE_COUNT firmware file(s) into container at /batch_input/${BRAND}/ ..."
docker exec "$CONTAINER" mkdir -p "/batch_input/${BRAND}"
docker cp "$STAGING_DIR/." "$CONTAINER:/batch_input/${BRAND}/"

# ── run gh.py --batchfolder ───────────────────────────────────────────────────

mkdir -p "$OUTDIR"
log "Starting batch rehost — results: $OUTDIR"
log "This can take many hours. Output also saved to $OUTDIR/batch.log"

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

# ── copy results back ─────────────────────────────────────────────────────────

log "Copying results back to $OUTDIR ..."
docker cp "$CONTAINER:/gh/results/." "$OUTDIR/firmware_results/" 2>/dev/null || \
    warn "No results found in container"
docker cp "$CONTAINER:/tmp/batch.log" "$OUTDIR/batch.log" 2>/dev/null || true

# ── screenshot ────────────────────────────────────────────────────────────────

SS_SCRIPT='
import sys, time
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.common.exceptions import WebDriverException

url, outdir = sys.argv[1], sys.argv[2]
opts = Options()
opts.add_argument("--headless")
opts.add_argument("--no-sandbox")
opts.add_argument("--disable-dev-shm-usage")
opts.add_argument("--disable-gpu")
opts.add_argument("--window-size=1280,800")
try:
    driver = webdriver.Chrome("/gh/chromedriver", options=opts)
except Exception:
    driver = webdriver.Chrome(options=opts)
driver.set_window_size(1280, 800)
driver.set_page_load_timeout(20)
try:
    driver.get(url)
    time.sleep(3)
    driver.save_screenshot(outdir + "/screenshot.png")
    print(f"[ss] saved  title={driver.title!r}")
except WebDriverException as e:
    print(f"[ss] WARNING: {e}")
driver.quit()
'

screenshot_all() {
    local results_root="$1"
    local wait_secs="$2"
    local fw_count=0 ss_ok=0

    log "=== Starting screenshot pass ==="
    while IFS= read -r cfg_path; do
        local fw_dir result ip port url debug_dir ss_dir
        fw_dir=$(dirname "$cfg_path")
        result=$(python3 -c "import json; d=json.load(open('$cfg_path')); print(d.get('result',''))" 2>/dev/null)
        [[ "$result" != "SUCCESS" ]] && continue

        ip=$(python3   -c "import json; d=json.load(open('$cfg_path')); print(d.get('targetip','172.21.0.2'))" 2>/dev/null)
        port=$(python3 -c "import json; d=json.load(open('$cfg_path')); print(d.get('targetport','80'))"       2>/dev/null)
        url="http://${ip}:${port}"
        debug_dir="${fw_dir}/debug"
        ss_dir="${fw_dir}/screenshots"
        mkdir -p "$ss_dir"

        fw_count=$((fw_count + 1))
        log "Screenshot [$fw_count]: $(basename "$fw_dir")  →  $url"

        [[ -f "${debug_dir}/docker-compose.yml" ]] || { warn "  No docker-compose.yml — skipping"; continue; }
        (cd "$debug_dir" && docker-compose build -q && docker-compose up -d) 2>&1 | sed 's/^/    /' \
            || { warn "  docker-compose up failed"; continue; }

        log "  Waiting ${wait_secs}s..."
        sleep "$wait_secs"

        local tmpscript
        tmpscript=$(mktemp /tmp/gh_ss_XXXXXX.py)
        echo "$SS_SCRIPT" > "$tmpscript"

        docker run --rm \
            --network host \
            -v "${tmpscript}:/tmp/ss.py:ro" \
            -v "${ss_dir}:/tmp/ss_out" \
            "$GREENHOUSE_IMAGE" \
            bash -c "source /root/venv/bin/activate && python3 /tmp/ss.py '${url}' '/tmp/ss_out'" \
            2>&1 | sed 's/^/    /' && ss_ok=$((ss_ok + 1)) || warn "  Screenshot failed"

        rm -f "$tmpscript"
        (cd "$debug_dir" && docker-compose down --remove-orphans) &>/dev/null || true
        docker network ls -q --filter "name=ghbridge" 2>/dev/null | xargs -r docker network rm 2>/dev/null || true
        docker images --filter "reference=debug_gh_rehosted*" -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
        log "  Saved to: ${ss_dir}/screenshot.png"

    done < <(find "$results_root" -maxdepth 3 -name "config.json" | sort)

    log "=== Screenshot pass complete: $ss_ok/$fw_count successful ==="
}

if $DO_SCREENSHOT && [[ -d "$OUTDIR/firmware_results" ]]; then
    screenshot_all "$OUTDIR/firmware_results" "$SCREENSHOT_WAIT"
fi

# ── generate summary CSV ──────────────────────────────────────────────────────

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