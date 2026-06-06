#!/bin/bash
# Large-scale D-Link firmware batch rehosting via Greenhouse.
#
# Usage:
#   ./batch_dlink.sh                        # scan poc_firmware/ + root for dlink zips
#   ./batch_dlink.sh --firmware-dir /path   # use a custom firmware directory
#   ./batch_dlink.sh --brand tplink --firmware-dir /path/to/tplink
#
# How it works:
#   1. Collects all firmware files from the specified directory
#   2. Spins up a single Greenhouse Docker container
#   3. Copies all firmware into /batch_input/ inside the container
#   4. Runs gh.py --batchfolder (sequential, one firmware at a time)
#   5. Copies results + logs back to ./results/batch_<timestamp>/
#   6. Runs process_batchlog.py to generate a summary CSV

set -euo pipefail

GREENHOUSE_IMAGE="greenhouse:patched"
BRAND="dlink"
FIRMWARE_DIR=""
OUTDIR="./results/batch_$(date +%Y%m%d_%H%M%S)"
MAX_CYCLES=26
PORTS="80,81"
IP="172.21.0.2"
REHOST_TYPE="HTTP"
REHOST_FIRST=""
SKIPFILE=""
DO_SCREENSHOT=false
SCREENSHOT_WAIT=60

log()  { echo "[*] $(date '+%H:%M:%S') $*"; }
warn() { echo "[!] $(date '+%H:%M:%S') $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --brand BRAND           Firmware brand keyword to filter filenames (default: dlink)
  --firmware-dir DIR      Directory containing firmware files (default: auto-collect D-Link files)
  --outdir DIR            Output directory (default: ./results/batch_<timestamp>)
  --max-cycles N          Max patch iterations per firmware (default: 26)
  --rehost-first          Enable FirmAE full-system rehost before patch loop (-rh)
  --skipfile PATH         File listing firmware paths to skip (one per line)
  --screenshot            Take a screenshot of each successful firmware web UI after batch
  --screenshot-wait N     Seconds to wait after docker-compose up before screenshotting (default: 60)
  -h, --help              Show this help

Examples:
  # Run all D-Link firmware found in poc_firmware/ and current dir:
  $0

  # Run from a custom directory of D-Link firmware:
  $0 --firmware-dir /data/dlink_firmware/

  # Run TP-Link firmware:
  $0 --brand tplink --firmware-dir /data/tplink_firmware/
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --brand)          BRAND="$2";         shift 2 ;;
        --firmware-dir)   FIRMWARE_DIR="$2";  shift 2 ;;
        --outdir)         OUTDIR="$2";        shift 2 ;;
        --max-cycles)     MAX_CYCLES="$2";    shift 2 ;;
        --rehost-first)      REHOST_FIRST="-rh";       shift ;;
        --skipfile)          SKIPFILE="$2";            shift 2 ;;
        --screenshot)        DO_SCREENSHOT=true;       shift ;;
        --screenshot-wait)   SCREENSHOT_WAIT="$2";     shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ── collect firmware files ────────────────────────────────────────────────────

STAGING_DIR=$(mktemp -d /tmp/gh_batch_XXXXXX)
log "Staging firmware in: $STAGING_DIR"

if [[ -n "$FIRMWARE_DIR" ]]; then
    [[ -d "$FIRMWARE_DIR" ]] || die "Firmware directory not found: $FIRMWARE_DIR"
    # Copy all files (no brand filter — trust the user's directory)
    find -L "$FIRMWARE_DIR" -maxdepth 3 -type f \( -iname "*.zip" -o -iname "*.bin" -o -iname "*.img" -o -iname "*.trx" -o -iname "*.chk" \) \
        | while read -r f; do
            cp "$f" "$STAGING_DIR/"
            log "  + $(basename "$f")"
        done
else
    # Auto-collect: search common locations for files matching the brand keyword
    log "Auto-collecting firmware matching '$BRAND' ..."
    SEARCH_DIRS="./poc_firmware ."
    while IFS= read -r f; do
        cp "$f" "$STAGING_DIR/"
        log "  + $(basename "$f")"
    done < <(find $SEARCH_DIRS -maxdepth 1 -type f \
        \( -iname "*.zip" -o -iname "*.bin" -o -iname "*.img" -o -iname "*.trx" -o -iname "*.chk" \) \
        | grep -i "$BRAND" 2>/dev/null || true)
fi

FILE_COUNT=$(ls "$STAGING_DIR" | wc -l)
if [[ "$FILE_COUNT" -eq 0 ]]; then
    rm -rf "$STAGING_DIR"
    die "No firmware files found. Use --firmware-dir to specify a directory."
fi

log "Found $FILE_COUNT firmware file(s) to process:"
ls "$STAGING_DIR" | while read -r f; do echo "    $f"; done

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

    # Remove Docker networks created by rehosted firmware (pattern: debug_<sha256>ghbridge*)
    STALE_NETS=$(docker network ls -q --filter "name=ghbridge" 2>/dev/null)
    if [[ -n "$STALE_NETS" ]]; then
        log "Removing stale Greenhouse networks..."
        echo "$STALE_NETS" | xargs docker network rm 2>/dev/null || true
    fi

    # Remove rehosted firmware Docker images (debug_gh_rehosted:*)
    STALE_IMGS=$(docker images --filter "reference=debug_gh_rehosted*" -q 2>/dev/null)
    if [[ -n "$STALE_IMGS" ]]; then
        log "Removing rehosted firmware images (debug_gh_rehosted)..."
        echo "$STALE_IMGS" | xargs docker rmi -f 2>/dev/null || true
    fi

    # Remove dangling images left over from the build process
    DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null)
    if [[ -n "$DANGLING" ]]; then
        log "Removing dangling images..."
        echo "$DANGLING" | xargs docker rmi -f 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "Initializing container environment (dockerd, PostgreSQL, etc.)..."
docker exec "$CONTAINER" /gh/docker_init.sh

# Patch FirmAE run.sh inside container to fix QEMU zombie hang
log "Patching FirmAE run.sh (zombie QEMU fix)..."
docker cp ./FirmAEreplacements/run.sh "$CONTAINER:/work/FirmAE/run.sh"
docker cp ./Greenhouse/backend/Planter.py "$CONTAINER:/gh/backend/Planter.py"
docker cp ./Greenhouse/backend/chkup_pre_analyzer.py "$CONTAINER:/gh/backend/chkup_pre_analyzer.py"

# ── copy firmware into container ──────────────────────────────────────────────

log "Copying $FILE_COUNT firmware file(s) into container at /batch_input/${BRAND}/ ..."
docker exec "$CONTAINER" mkdir -p "/batch_input/${BRAND}"
docker cp "$STAGING_DIR/." "$CONTAINER:/batch_input/${BRAND}/"

# Copy skipfile if provided
SKIPFILE_FLAG=""
if [[ -n "$SKIPFILE" && -f "$SKIPFILE" ]]; then
    docker cp "$SKIPFILE" "$CONTAINER:/batch_skipfile.txt"
    SKIPFILE_FLAG="--skipfile /batch_skipfile.txt"
fi

# ── run gh.py --batchfolder ───────────────────────────────────────────────────

mkdir -p "$OUTDIR"
log "Starting batch rehost — results will go to: $OUTDIR"
log "This can take many hours. Output is also saved to $OUTDIR/batch.log"

docker exec "$CONTAINER" bash -c "
    source /root/venv/bin/activate
    mkdir -p /gh/results
    cd /gh
    mkdir -p /gh/scratch
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
        ${REHOST_FIRST} \
        ${SKIPFILE_FLAG} 2>&1
" | tee "$OUTDIR/batch.log"

# ── copy results back ─────────────────────────────────────────────────────────

log "Copying results back to $OUTDIR ..."
docker cp "$CONTAINER:/gh/results/." "$OUTDIR/firmware_results/" 2>/dev/null || \
    warn "No results directory found in container"
docker cp "$CONTAINER:/tmp/batch.log" "$OUTDIR/batch.log" 2>/dev/null || true

# ── screenshot successful firmware ───────────────────────────────────────────

screenshot_all() {
    local results_root="$1"
    local wait_secs="$2"

    log "=== Starting screenshot pass ==="

    # Inline Selenium script injected into the container
    local SS_SCRIPT
    SS_SCRIPT=$(cat <<'PYEOF'
import sys, time
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.common.exceptions import WebDriverException

url     = sys.argv[1]
outdir  = sys.argv[2]

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
    print(f"[ss] saved screenshot.png  title={driver.title!r}")
except WebDriverException as e:
    print(f"[ss] WARNING: {e}")
driver.quit()
PYEOF
)

    local fw_count=0
    local ss_ok=0

    # Iterate every <sha256>/<fw_name>/config.json under results_root
    while IFS= read -r cfg_path; do
        local fw_dir
        fw_dir=$(dirname "$cfg_path")
        local sha_dir
        sha_dir=$(dirname "$fw_dir")
        local fw_name
        fw_name=$(basename "$fw_dir")

        # Only process SUCCESS results
        local result
        result=$(python3 -c "import json,sys; d=json.load(open('$cfg_path')); print(d.get('result',''))" 2>/dev/null)
        [[ "$result" != "SUCCESS" ]] && continue

        local ip port
        ip=$(python3   -c "import json; d=json.load(open('$cfg_path')); print(d.get('targetip','172.21.0.2'))" 2>/dev/null)
        port=$(python3 -c "import json; d=json.load(open('$cfg_path')); print(d.get('targetport','80'))"       2>/dev/null)
        local url="http://${ip}:${port}"

        local debug_dir="${fw_dir}/debug"
        local ss_dir="${fw_dir}/screenshots"
        mkdir -p "$ss_dir"

        fw_count=$((fw_count + 1))
        log "Screenshot [$fw_count]: $fw_name  →  $url"

        # Start rehosted firmware
        if [[ ! -f "${debug_dir}/docker-compose.yml" ]]; then
            warn "  docker-compose.yml not found at $debug_dir — skipping"
            continue
        fi
        (cd "$debug_dir" && docker-compose build -q && docker-compose up -d) 2>&1 | \
            sed 's/^/    /' || { warn "  docker-compose up failed — skipping"; continue; }

        log "  Waiting ${wait_secs}s for firmware to initialise..."
        sleep "$wait_secs"

        # Write selenium script to a temp file, mount it into a Greenhouse container
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

        # Stop firmware and clean up its resources
        log "  Stopping firmware..."
        (cd "$debug_dir" && docker-compose down --remove-orphans) &>/dev/null || true

        # Clean up this firmware's network and image immediately
        docker network ls -q --filter "name=ghbridge" 2>/dev/null \
            | xargs -r docker network rm 2>/dev/null || true
        docker images --filter "reference=debug_gh_rehosted*" -q 2>/dev/null \
            | xargs -r docker rmi -f 2>/dev/null || true

        log "  Screenshot saved to: ${ss_dir}/screenshot.png"

    done < <(find "$results_root" -maxdepth 3 -name "config.json" | sort)

    log "=== Screenshot pass complete: $ss_ok/$fw_count successful ==="
}

if $DO_SCREENSHOT && [[ -d "$OUTDIR/firmware_results" ]]; then
    screenshot_all "$OUTDIR/firmware_results" "$SCREENSHOT_WAIT"
fi

# ── generate summary ──────────────────────────────────────────────────────────

BATCHLOG_SCRIPT="./Greenhouse/scripts/process_batchlog.py"
if [[ -f "$BATCHLOG_SCRIPT" && -f "$OUTDIR/batch.log" ]]; then
    log "Generating summary CSV from batch log..."
    python3 "$BATCHLOG_SCRIPT" "$OUTDIR/batch.log" > "$OUTDIR/summary.csv" 2>/dev/null || \
        warn "process_batchlog.py failed — check $OUTDIR/batch.log manually"
    if [[ -f "$OUTDIR/summary.csv" ]]; then
        log "Summary CSV saved to: $OUTDIR/summary.csv"
        echo ""
        echo "=== BATCH SUMMARY ==="
        cat "$OUTDIR/summary.csv"
    fi
fi

log "All done. Results: $OUTDIR"
trap - EXIT
cleanup
