#!/bin/bash
# 把 Greenhouse 跑完的結果關鍵資訊存入 results/results.csv
# 用法：
#   ./save_result.sh <results_dir> [chkup_hints_dir] [notes]
#   ./save_result.sh --all                  # 掃描 results/test/ 下所有結果

RESULTS_ROOT="./results/test"
CSV_FILE="./results/results.csv"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

die() { echo "[ERROR] $*" >&2; exit 1; }

# 確保 CSV 有 header
if [[ ! -f "$CSV_FILE" ]]; then
    mkdir -p "$(dirname "$CSV_FILE")"
    echo "timestamp,firmware,sha256,brand,result,seconds_to_up,targetpath,targetip,targetport,chkup_hints,sigsegv_count,firmae_success,notes" > "$CSV_FILE"
fi

save_one() {
    local sha256_dir="$1"
    local chkup_hints="${2:-}"
    local notes="${3:-}"

    local sha256
    sha256=$(basename "$sha256_dir")

    local fw_dir
    fw_dir=$(ls "$sha256_dir" 2>/dev/null | head -1)
    [[ -z "$fw_dir" ]] && { echo "[skip] $sha256: no firmware subdir"; return; }

    local config_json="$sha256_dir/$fw_dir/config.json"
    local gh_log="$sha256_dir/gh.log"

    [[ -f "$config_json" ]] || { echo "[skip] $sha256: no config.json"; return; }

    # 從 config.json 讀取欄位
    local result seconds_to_up targetpath targetip targetport brand
    result=$(python3 -c "import json; d=json.load(open('$config_json')); print(d.get('result',''))" 2>/dev/null)
    seconds_to_up=$(python3 -c "import json; d=json.load(open('$config_json')); print(round(d.get('seconds_to_up',0),1))" 2>/dev/null)
    targetpath=$(python3 -c "import json; d=json.load(open('$config_json')); print(d.get('targetpath',''))" 2>/dev/null)
    targetip=$(python3 -c "import json; d=json.load(open('$config_json')); print(d.get('targetip',''))" 2>/dev/null)
    targetport=$(python3 -c "import json; d=json.load(open('$config_json')); print(d.get('targetport',''))" 2>/dev/null)
    brand=$(python3 -c "import json; d=json.load(open('$config_json')); print(d.get('brand',''))" 2>/dev/null)

    # 從 gh.log 讀取額外資訊
    local sigsegv_count=0 firmae_success="no"
    if [[ -f "$gh_log" ]]; then
        sigsegv_count=$(grep -c "SIGSEGV\|signal 11" "$gh_log" 2>/dev/null | tr -d '[:space:]' || echo 0)
        grep -q "b'SUCCESS'" "$gh_log" 2>/dev/null && firmae_success="yes"
    fi

    # firmware 名稱（用 subdir 名）
    local firmware="$fw_dir"

    # ChkUp hints 是否使用
    local chkup_used="no"
    if [[ -n "$chkup_hints" ]]; then
        chkup_used=$(basename "$(dirname "$(dirname "$chkup_hints")")")
    elif [[ -f "$gh_log" ]] && grep -q "\[ChkUp\] Loaded hints" "$gh_log" 2>/dev/null; then
        chkup_used="yes(unknown)"
    fi

    # 寫入 CSV（避免逗號衝突用雙引號包）
    echo "\"$TIMESTAMP\",\"$firmware\",\"$sha256\",\"$brand\",\"$result\",\"$seconds_to_up\",\"$targetpath\",\"$targetip\",\"$targetport\",\"$chkup_used\",\"$sigsegv_count\",\"$firmae_success\",\"$notes\"" >> "$CSV_FILE"

    echo "[saved] $firmware → $result (${seconds_to_up}s) FirmAE:$firmae_success SIGSEGV:$sigsegv_count ChkUp:$chkup_used"
}

# ── main ──────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--all" ]]; then
    echo "[*] Scanning all results in $RESULTS_ROOT ..."
    for d in "$RESULTS_ROOT"/*/; do
        [[ -d "$d" ]] && save_one "$d"
    done
else
    [[ -z "${1:-}" ]] && die "Usage: $0 <results_dir> [chkup_hints_dir] [notes]"
    save_one "$1" "${2:-}" "${3:-}"
fi

echo "[*] CSV updated: $CSV_FILE"
