# ChkUp → Greenhouse 整合：修改建議清單

> 建立日期：2026-06-05  
> 依據：DIR513A / DAP2310B / DAP3662 三組 firmware 的實際執行結果（`results/results.csv`）  
> 優先級定義：P0 = 現在會造成崩潰或完全無效；P1 = 有 hints 但效果為零；P2 = 品質改善

---

## 執行結果摘要（問題的直接證據）

| firmware | 有無 ChkUp hints | 結果 | 備註 |
|----------|-----------------|------|------|
| DIR513A  | 無 | SUCCESS (191.8s, sigsegv×7) | baseline |
| DIR513A  | 有（v1） | **CRASHED** | `exit_hints_bug`，Greenhouse 側已修 |
| DIR513A  | 有（v1 修後） | **CRASHED** | hints 仍然有問題 |
| DIR513A  | 有（v1 修後） | SUCCESS (191.6s, sigsegv×7) | 與 baseline 完全相同，hints 無任何加速 |
| DAP2310B | 有 | SUCCESS (148.8s) | hints 部分有效（xmldb_node_name 有用） |
| DAP3662  | 有 | SUCCESS (148.x s) | patch_hints 正確指向 httpd，效果最好 |

**結論**：ChkUp hints 的有效程度從 firmware 到 firmware 差異極大，根本原因在以下幾個可修的設計問題。

---

## BUG-01｜`patch_hints.json` 輸出主機絕對路徑而非 firmware 相對路徑

**優先級**：P0  
**受影響**：DAP2310B

### 問題描述

`patch_hints.json` 的 `binary` 欄位應填寫 binary 在 firmware 根目錄下的相對路徑，但目前輸出的是分析機器的完整主機路徑：

```json
// 現在的輸出（錯誤）
{
  "hint_type": "wait_loop",
  "binary": "/home/m11315012/workspace/Firmware-Dataset/fws/CVE_extracted/DAP-2310_REVB_FIRMWARE_2.10.RC036.ZIP_extracted/_DAP2310B-firmware-v210-rc036.bin.extracted/squashfs-root/sbin/athstats",
  ...
}
```

Greenhouse 的 `WaitLoop.diagnose()` 會嘗試用這個路徑比對執行中的 binary，但在 Docker 容器內路徑完全不同，結果是所有 wait_loop hints 靜默失效並 fallback 到全 trace 掃描。

### 要求修改

輸出前，剝離 firmware 根目錄（`squashfs-root/`、`cpio-root/` 等）以前的路徑前綴，統一以 `/` 開頭的 firmware 內部路徑輸出：

```json
// 修改後（正確，參照 DAP3662 的格式）
{
  "hint_type": "wait_loop",
  "binary": "/sbin/athstats",
  ...
}
```

### 驗收標準

`binary` 欄位的值以 `/` 開頭，不包含任何主機路徑成分（無 `/home/`、`/workspace/`、`squashfs-root` 等）。

---

## BUG-02｜`patch_hints.json` 分析目標是更新路徑 CGI，不是 HTTP server

**優先級**：P0（最高）  
**受影響**：DIR513A（24 個 hints 全部無效）、DAP2310B（16 個 hints 全部無效）

### 問題描述

ChkUp 分析的是「firmware 更新路徑」（從 `firmup.asp` → `upload.cgi` / `upload_bootloader.cgi`），因此 `patch_hints.json` 中的 binary 全是更新用的 CGI：

```
DIR513A 的 24 個 hints，binary 全部是：
  /etc_ro/web/cgi-bin/upload_bootloader.cgi
  /etc_ro/web/cgi-bin/upload.cgi

DAP2310B 的 16 個 hints，binary 全部是：
  /sbin/athstats、/usr/sbin/captival_tar、/sbin/wlanconfig、...（非 httpd binary）
```

但 Greenhouse 執行的目標是 **HTTP server**（DIR513A 為 `/bin/goahead`，DAP2310B 為 `/sbin/httpd`）。這些 CGI binary 的地址完全不在 HTTP server 的地址空間內，hint 在 Greenhouse 中完全無效。

**這直接導致了 DIR513A CRASHED**：hint 被傳入 Patcher，觸發了 Greenhouse 的 bug，讓整個流程崩潰。即使 bug 修復後，DIR513A 有 hints 的執行時間（191.6s, sigsegv×7）與無 hints 的 baseline（191.8s, sigsegv×7）**完全相同**——hints 零貢獻。

### 要求修改

在輸出 `patch_hints.json` 時，**以 `web_binary_hints.json` 識別的 HTTP server binary 為主分析目標**，分析其啟動流程中的：

1. `wait_loop`：HTTP server 在啟動時等待 IPC socket 回應的 polling loop
2. `version_check` / `model_check`：HTTP server 讀取 NVRAM 後的版本或型號比對分支

更新路徑 CGI（upload.cgi 等）的 hints 對 Greenhouse 沒有幫助，**不需要輸出**（或另外放進一個 `update_path_hints.json` 供其他用途，不要混入 `patch_hints.json`）。

### 參照

DAP3662 是目前**唯一正確**的範例，其 `patch_hints.json` 的 binary 直接指向 `/sbin/httpd`：
```json
{
  "hint_type": "wait_loop",
  "binary": "/sbin/httpd",
  "loop_head": "0x0042071c",
  "condition": "unix_socket_connect(/var/run/xmldb_sock)",
  "description": "polling for xmldb socket"
}
```

### 驗收標準

`patch_hints.json` 中所有 `binary` 欄位的值，必須與 `web_binary_hints.json` 中列出的其中一個 `binary_path`（basename）相符，或是其直接依賴的 daemon binary。

---

## BUG-03｜`patch_hints.json` 的 `fail_target` / `pass_target` 全為空字串

**優先級**：P1  
**受影響**：DIR513A（24 個 hints 均無方向資訊）

### 問題描述

DIR513A 所有的 `version_check` / `model_check` hints 的分支目標均為空：

```json
{
  "hint_type": "version_check",
  "binary": "/etc_ro/web/cgi-bin/upload_bootloader.cgi",
  "branch_addr": "0x004430ec",
  "fail_target": "",    ← 空
  "pass_target": "",    ← 空
  "description": "findStrInFile call site"
}
```

ChkUp 識別了 `findStrInFile` 的 call site 位址，但沒有繼續分析 call 返回後的 branch 指令，因此不知道「成功路徑」跳到哪裡。

Greenhouse 的 `PrematureExit` patcher 需要 `pass_target` 來決定把 branch 強制跳向哪裡。沒有這個資訊，即使未來實作了對 `exit_hints` 的支援，hint 仍然無法使用。

### 要求修改

在識別 call site（例如 `findStrInFile@0x004430ec`）之後，往下找最近的 conditional branch 指令，填寫其兩個目標：

```json
{
  "hint_type": "version_check",
  "binary": "/sbin/httpd",
  "branch_addr": "0x004430f4",
  "fail_target": "0x00443180",
  "pass_target": "0x004430f8",
  "description": "version string match branch after findStrInFile"
}
```

- `branch_addr`：branch 指令本身的位址（不是 call site）
- `fail_target`：比對失敗時跳往的位址（通常指向 exit 路徑）
- `pass_target`：比對成功時繼續執行的位址

### 驗收標準

`version_check` / `model_check` / `signature_check` 類型的 hint，`fail_target` 和 `pass_target` 至少其中一個非空。

---

## BUG-04｜`ipc_deps.json` 的 xmldb `launch_args` 留空，且缺少 `xmldb_node_name`

**優先級**：P1  
**受影響**：DAP3662（無 `xmldb_node_name`，xmldb 以無參數啟動）

### 問題描述

DAP3662 的 `ipc_deps.json`：
```json
{
  "binary_name": "xmldb",
  "binary_path": "/usr/sbin/xmldb",
  "launch_args": "",   ← 空
  ...
}
```

沒有填寫 `xmldb_node_name`，Greenhouse 的補救機制（`chkup_pre_analyzer.py:85-87`）無法生效，xmldb 以無參數方式啟動。

xmldb 需要 `-n <node_name> -t` 才能正確建立 `/var/run/xmldb_sock`。以空參數啟動的 xmldb 可能無法提供 socket，導致 httpd 的 xmldb wait_loop 仍然需要被 patch，而 DAP3662 的 `patch_hints.json` 裡已有針對這個 loop 的 hint（`loop_head: 0x0042071c`）——本可以完全省掉這次 patch，卻因為 xmldb 沒有正確啟動而白費。

### 要求修改

從 firmware 的 init 腳本（`/etc_ro/rcS`、`/etc/init.d/rcS`、`/etc/init.d/`目錄下的各腳本）中提取 xmldb 的實際啟動命令，填寫 `xmldb_node_name` 欄位（Greenhouse 支援的格式）或直接填入 `launch_args`：

```json
// 方式一：填 xmldb_node_name（Greenhouse 會自動組裝 -n <name> -t）
{
  "binary_name": "xmldb",
  "binary_path": "/usr/sbin/xmldb",
  "launch_args": "",
  "xmldb_node_name": "dap3662_xml_root",
  ...
}

// 方式二：直接填完整 launch_args
{
  "binary_name": "xmldb",
  "binary_path": "/usr/sbin/xmldb",
  "launch_args": "-n dap3662_xml_root -t",
  ...
}
```

DAP2310B 已正確填寫 `xmldb_node_name: "wapn25_dkbs_dap2310b"`，可作為參考。

### 提取方法建議

在 firmware 的 init 腳本中搜尋 `xmldb` 的啟動行，例如：
```sh
grep -r "xmldb" /etc_ro/rcS /etc/init.d/ 2>/dev/null
# 預期找到類似：xmldb -n dap3662_xml_root -t &
```

### 驗收標準

凡是 `binary_name == "xmldb"` 的 companion daemon，必須有非空的 `xmldb_node_name` 欄位，或 `launch_args` 包含 `-n <node_name>` 參數。

---

## IMPROVE-01｜`web_binary_hints.json` 應基於靜態分析識別 HTTP server，而非名稱匹配

**優先級**：P2  
**受影響**：DIR513A、DAP2310B、DAP3662 全部三個

### 問題描述

三個 firmware 的 `web_binary_hints.json` evidence 欄位均為：
```json
"evidence": "binary name matches known HTTP server list: httpd"
"evidence": "binary name matches known HTTP server list: goahead"
```

這與 Greenhouse 自身的 `POTENTIAL_HTTPSERV` 硬編碼白名單（21 個名稱）完全重疊，ChkUp 的 hints **沒有提供任何 Greenhouse 自己找不到的資訊**。

真正有價值的情境是：HTTP server binary 使用**非標準名稱**（如 `alphapd`、`rgbd`、`webs`、廠商自訂名），此時 Greenhouse 的靜態白名單找不到，必須依賴 ChkUp 的靜態分析。

### 要求修改

優先透過靜態分析識別 HTTP server，而非名稱匹配：

1. **確認依據**：在候選 binary 中找到 `bind(AF_INET, port=80)` 或 `bind(AF_INET, port=443)` 加上 `listen()` 的調用鏈
2. **Confidence 規則**：
   - `high`：靜態分析確認有 `bind(80)` + `listen()` 的調用
   - `medium`：只有名稱在已知清單中，但無靜態分析確認
3. **Evidence 內容**：改為描述靜態分析依據，例如：
   ```json
   "evidence": "bind(AF_INET, port=80)@0x0040a2c0 + listen()@0x0040a310 in call graph"
   ```

### 不需要輸出的情況

若 HTTP server 的名稱就在 Greenhouse 的標準白名單中（`httpd`、`goahead`、`boa` 等），且無法取得更精確的靜態分析依據，可以**不輸出**這個 hint（讓 Greenhouse 用自己的白名單搜尋即可），或以 confidence `"medium"` 輸出但 evidence 標記為 `"name_match_only"`，避免誤導。

### 驗收標準

凡是 `confidence: "high"` 的 entry，`evidence` 欄位必須包含靜態分析依據（bind/listen 位址或類似資訊），不得只是名稱匹配的描述。

---

## IMPROVE-02｜`xmldb_hints.json` 的 `xmldb_node_paths` 欄位目前全為空陣列

**優先級**：P2  
**受影響**：DIR513A、DAP2310B（DAP3662 未確認）

### 問題描述

`xmldb_hints.json`（目前 Greenhouse 不讀取此檔）的 `xmldb_node_paths` 欄位均為空陣列：
```json
{
  "firmware_id": "...",
  "xmldb_node_paths": []
}
```

若 ChkUp 能識別 xmldb 中常用的 node path（例如 `device/name`、`sys/firmware/version`），Greenhouse 在啟動 xmldb 後可以預先寫入這些節點的初始值，避免 httpd 查詢 xmldb 時拿到空值而提早退出。這是一個未來可以利用的資訊管道。

### 要求修改

從 firmware 的 init 腳本或 xmldb 設定檔（通常在 `/etc_ro/` 或 `/etc/` 下）中提取 xmldb 的初始 node path 清單，填入 `xmldb_node_paths`。此功能若實作成本過高，可列為 backlog。

---

## 修改優先級總表

| ID | 問題 | 優先級 | 修改難度 | 預期效果 |
|----|------|--------|---------|---------|
| BUG-02 | patch_hints 目標 binary 錯誤（CGI 而非 HTTP server） | **P0** | 中（需調整分析目標選擇邏輯） | 避免 CRASHED；讓 wait_loop hints 真正有效 |
| BUG-01 | binary 欄位輸出主機路徑 | **P0** | 低（路徑後處理） | 讓 wait_loop hints 可被 Greenhouse 匹配 |
| BUG-04 | xmldb launch_args 留空 | **P1** | 低（從 init 腳本提取） | companion daemon 正確啟動，省掉一次 patch 迭代 |
| BUG-03 | fail_target / pass_target 為空 | **P1** | 中（需分析 call site 後的 branch） | 為未來 PrematureExit hint 支援鋪路 |
| IMPROVE-01 | web_binary 只用名稱匹配 | P2 | 中（需靜態分析 bind/listen） | 對非標準 HTTP server 名稱的 firmware 有幫助 |
| IMPROVE-02 | xmldb_node_paths 全空 | P2 | 高（需解析 xmldb 設定格式） | 可選，未來功能 |

---

## 附錄：DAP3662 是目前的最佳實作範例

DAP3662 的 `patch_hints.json` 符合所有 P0/P1 要求：

- ✅ binary 欄位使用 firmware 相對路徑（`/sbin/httpd`）
- ✅ 分析目標是 HTTP server 本身，而非更新路徑 CGI
- ✅ `loop_head` 位址有效（指向 httpd 的 xmldb polling loop）
- ✅ `condition` 欄位明確描述等待的 socket 路徑

DAP3662 的 `ipc_deps.json` 唯一的缺失是 xmldb 沒有 `xmldb_node_name`（BUG-04），其他結構正確。

建議以 DAP3662 的 hints 格式作為 ChkUp 輸出的**參照標準**，並在修改後對 DIR513A / DAP2310B 重新跑分析，驗證新輸出的 hints 在 Greenhouse 中是否產生實質加速效果（目標：sigsegv 次數降低、執行時間縮短）。
