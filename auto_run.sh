#!/bin/bash
# Automated end-to-end Greenhouse firmware rehosting workflow.
# Replaces the manual steps in doc/MANUAL.md.
#
# Usage examples:
#   ./auto_run.sh --brand dlink --firmware ./DIR-868L.zip
#   ./auto_run.sh --brand dlink --firmware ./DIR-868L.zip --routersploit
#   ./auto_run.sh --run-firmware ./results/<sha256>
#   ./auto_run.sh --build          # rebuild Docker image first

set -euo pipefail

GREENHOUSE_IMAGE="greenhouse:patched"
OUTDIR="./results/test"
BRAND=""
FIRMWARE=""
DO_BUILD=false
DO_REHOST=false
DO_RUN_FIRMWARE=false
DO_ROUTERSPLOIT=false
DO_REHOST_FIRST=false
RUN_FIRMWARE_PATH=""

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[*] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --brand BRAND           Firmware brand (required with --rehost)
  --firmware PATH         Firmware image path (required with --rehost)
  --outdir DIR            Results output directory (default: ./results)
  --build                 (Re)build the Docker image via Makefile before running
  --rehost                Rehost firmware (default when --firmware is given)
  --run-firmware PATH     Start a previously rehosted result with docker-compose
  --routersploit          Run routersploit after rehosting (implies --rehost)
  --rehost-first          Pass -rh to Greenhouse: run FirmAE full-system rehost before patch loop
  -h, --help              Show this help

Examples:
  # Rehost a firmware image:
  $0 --brand dlink --firmware DIR-868L.zip

  # Rehost then run routersploit:
  $0 --brand dlink --firmware DIR-868L.zip --routersploit

  # Start an already-rehosted image:
  $0 --run-firmware ./results/<sha256>
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────

[[ $# -eq 0 ]] && { usage; exit 0; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --brand)        BRAND="$2";            shift 2 ;;
        --firmware)     FIRMWARE="$2";         shift 2 ;;
        --outdir)       OUTDIR="$2";           shift 2 ;;
        --build)        DO_BUILD=true;         shift ;;
        --rehost)       DO_REHOST=true;        shift ;;
        --run-firmware) DO_RUN_FIRMWARE=true; RUN_FIRMWARE_PATH="$2"; shift 2 ;;
        --routersploit)  DO_ROUTERSPLOIT=true;  shift ;;
        --rehost-first)  DO_REHOST_FIRST=true;  shift ;;
        -h|--help)      usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# --firmware implies --rehost
[[ -n "$FIRMWARE" ]] && DO_REHOST=true
# --routersploit implies --rehost
$DO_ROUTERSPLOIT && DO_REHOST=true

# ── step 0: build image ───────────────────────────────────────────────────────

if $DO_BUILD; then
    log "Building Greenhouse Docker image (this takes a while)..."
    make build
fi

# ── step 1-6: rehost firmware ─────────────────────────────────────────────────

if $DO_REHOST; then
    [[ -z "$BRAND" ]]    && die "--brand is required for rehosting"
    [[ -z "$FIRMWARE" ]] && die "--firmware is required for rehosting"
    [[ -f "$FIRMWARE" ]] || die "Firmware file not found: $FIRMWARE"

    # Check image exists
    docker image inspect "$GREENHOUSE_IMAGE" &>/dev/null \
        || die "Docker image '$GREENHOUSE_IMAGE' not found. Run with --build first."

    SHA256=$(sha256sum "$FIRMWARE" | awk '{print $1}')
    log "Firmware SHA256: $SHA256"

    RESULT_PATH="$OUTDIR/$SHA256"
    if [[ -d "$RESULT_PATH" ]]; then
        warn "Results already exist at $RESULT_PATH — skipping rehost."
        warn "Delete that directory and re-run to force a fresh rehost."
    else
        log "Starting Greenhouse container (privileged, /dev mounted)..."
        CONTAINER=$(docker run -d --privileged \
            -v /dev:/host/dev \
            "$GREENHOUSE_IMAGE" \
            sleep infinity)
        log "Container ID: $CONTAINER"

        cleanup() {
            log "Stopping and removing container $CONTAINER ..."
            docker stop "$CONTAINER" &>/dev/null || true
            docker rm   "$CONTAINER" &>/dev/null || true
        }
        trap cleanup EXIT

        log "Initializing container environment (dockerd, PostgreSQL, etc.)..."
        docker exec "$CONTAINER" /gh/docker_init.sh

        log "Copying firmware into container as /firmware_input ..."
        docker cp "$FIRMWARE" "$CONTAINER:/firmware_input"

        log "Running Greenhouse — this can take up to 24 hours..."
        # tee keeps output visible while also logging
        REHOST_FIRST_FLAG=""
        $DO_REHOST_FIRST && REHOST_FIRST_FLAG="-rh"
        docker exec "$CONTAINER" /gh/run.sh "$BRAND" "firmware_input" "$REHOST_FIRST_FLAG" \
            2>&1 | tee gh.log

        log "Copying results back to host..."
        mkdir -p "$OUTDIR"
        docker cp "$CONTAINER:/gh/results/$SHA256" "$OUTDIR/"

        log "Copying gh.log from container..."
        docker cp "$CONTAINER:/tmp/gh.log" "$RESULT_PATH/gh.log" || \
            warn "gh.log not found in container (run may have failed early)"

        log "Unpacking firmware with binwalk for comparison..."
        docker exec "$CONTAINER" bash -c \
            "cd /tmp && binwalk -e -M /firmware_input -C /tmp/fw_extracted" \
            2>&1 | tee -a gh.log || true
        docker cp "$CONTAINER:/tmp/fw_extracted" "$RESULT_PATH/firmware_unpacked" || \
            warn "binwalk extraction not found in container"

        log "Results saved to: $RESULT_PATH"
        trap - EXIT   # drop the auto-cleanup; let the user inspect logs
        cleanup
    fi

    # Discover firmware name from result directory
    FIRMWARE_NAME=$(ls "$RESULT_PATH" 2>/dev/null | head -1)
    [[ -z "$FIRMWARE_NAME" ]] && die "No subdirectory found inside $RESULT_PATH"
    DEBUG_DIR="$RESULT_PATH/$FIRMWARE_NAME/debug"
    CONFIG_JSON="$RESULT_PATH/$FIRMWARE_NAME/config.json"

    log "Debug dir : $DEBUG_DIR"
    if [[ -f "$CONFIG_JSON" ]]; then
        TARGET_IP=$(python3 -c "import json; d=json.load(open('$CONFIG_JSON')); print(d.get('targetip','172.21.0.2'))")
        TARGET_PORT=$(python3 -c "import json; d=json.load(open('$CONFIG_JSON')); print(d.get('targetport','80'))")
        log "Target    : $TARGET_IP:$TARGET_PORT"
    fi
fi

# ── steps 7-13: run rehosted firmware ────────────────────────────────────────

run_rehosted() {
    local result_root="$1"   # path to <outdir>/<sha256>

    local fw_name
    fw_name=$(ls "$result_root" | head -1)
    [[ -z "$fw_name" ]] && die "No firmware directory inside $result_root"

    local debug_dir="$result_root/$fw_name/debug"
    local config_json="$result_root/$fw_name/config.json"

    [[ -f "$debug_dir/docker-compose.yml" ]] \
        || die "docker-compose.yml not found at $debug_dir"

    TARGET_IP=172.21.0.2
    TARGET_PORT=80
    if [[ -f "$config_json" ]]; then
        TARGET_IP=$(python3   -c "import json; d=json.load(open('$config_json')); print(d.get('targetip',   '172.21.0.2'))")
        TARGET_PORT=$(python3 -c "import json; d=json.load(open('$config_json')); print(d.get('targetport', '80'))")
    fi

    log "Building rehosted image..."
    (cd "$debug_dir" && docker-compose build)

    log "Starting rehosted firmware..."
    (cd "$debug_dir" && docker-compose up -d)

    log "Waiting 90 s for firmware to start..."
    sleep 90

    log "Testing firmware at $TARGET_IP:$TARGET_PORT ..."
    if curl -sf --connect-timeout 15 "http://$TARGET_IP:$TARGET_PORT" -o /dev/null; then
        log "SUCCESS — firmware is responding at http://$TARGET_IP:$TARGET_PORT"
    else
        warn "Firmware did not respond within the timeout."
        warn "It may still be starting; try again in a minute."
        warn "  curl http://$TARGET_IP:$TARGET_PORT"
    fi

    log "To stop the firmware:  cd $debug_dir && docker-compose down"
}

if $DO_RUN_FIRMWARE; then
    [[ -n "$RUN_FIRMWARE_PATH" ]] || die "--run-firmware requires a path argument"
    [[ -d "$RUN_FIRMWARE_PATH" ]] || die "Directory not found: $RUN_FIRMWARE_PATH"
    run_rehosted "$RUN_FIRMWARE_PATH"
elif $DO_REHOST && [[ -n "${DEBUG_DIR:-}" ]]; then
    read -rp "[?] Start the rehosted firmware now? [y/N] " REPLY
    if [[ "${REPLY,,}" == "y" ]]; then
        run_rehosted "$RESULT_PATH"
    fi
fi

# ── routersploit ──────────────────────────────────────────────────────────────

if $DO_ROUTERSPLOIT; then
    log "Running routersploit (this takes ~4 hours)..."

    docker image inspect "$GREENHOUSE_IMAGE" &>/dev/null \
        || die "Docker image '$GREENHOUSE_IMAGE' not found."

    RS_CONTAINER=$(docker run -d --privileged \
        -v /dev:/host/dev \
        "$GREENHOUSE_IMAGE" \
        sleep infinity)
    log "Routersploit container: $RS_CONTAINER"

    rs_cleanup() {
        log "Stopping routersploit container..."
        docker stop "$RS_CONTAINER" &>/dev/null || true
        docker rm   "$RS_CONTAINER" &>/dev/null || true
    }
    trap rs_cleanup EXIT

    log "Initializing container..."
    docker exec "$RS_CONTAINER" /gh/docker_init.sh

    log "Copying rehosted image into container..."
    docker cp "$RESULT_PATH" "$RS_CONTAINER:/rehosted_input"

    log "Running routersploit evaluation..."
    docker exec "$RS_CONTAINER" /routersploit/run_routersploit.sh "/rehosted_input" \
        2>&1 | tee routersploit.log

    log "Copying routersploit results back..."
    mkdir -p "$OUTDIR/routersploit"
    docker cp "$RS_CONTAINER:/routersploit/results/." "$OUTDIR/routersploit/"

    log "Routersploit results: $OUTDIR/routersploit/"
    if [[ -f "$OUTDIR/routersploit/vulnerable.csv" ]]; then
        log "Vulnerabilities found:"
        cat "$OUTDIR/routersploit/vulnerable.csv"
    fi

    trap - EXIT
    rs_cleanup
fi

log "All done."
