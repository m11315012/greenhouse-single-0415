# ChkUp × Greenhouse 整合簡報

> 本文件供 ChkUp 側的 Claude 閱讀，目的是讓你理解 Greenhouse 的架構與瓶頸，
> 以便評估 ChkUp 的 firmware 更新路徑分析能在哪些地方提供有效的靜態先驗資訊。

---

## 1. Greenhouse 是什麼

Greenhouse 是一個針對 **消費性路由器/IoT 設備 firmware** 的單服務 user-space 模擬框架。
它的目標是：在不需要完整系統模擬的前提下，讓 firmware 內的 HTTP daemon（或 UPnP / DNS daemon）
在 QEMU user-mode 下正常啟動並對外提供服務。

### 1.1 整體流程

```
firmware image
      │
      ▼
[FirmAE extractor]  ──→  extracted filesystem (fs_path/)
      │
      ▼
[Planter.identify_target_folder]
      │  找出 webroot、目標 binary（httpd / boa / goahead / ...）
      ▼
[Fixer.initial_setup]
      │  - 偵測架構 (arm/mips/mipsel/x86)
      │  - 複製對應 qemu-*-static 進 fs
      │  - 部署 libnvram-faker.so（攔截所有 nvram_get/set 呼叫）
      │  - 寫入 nvram.ini（預設 key-value）
      │  - 複製 busybox、ip 等 helper
      ▼
[Planter.get_bg_scripts]
      │  在 fs 裡搜尋固定名單中的 background daemon
      │  目前名單：{"xmldb": "-n gh_xml_root_node -t", "userconfig": ""}
      ▼
[QemuRunner]  ←─────────────────────────────────────────────┐
      │  在 Docker container 內執行：                        │
      │  1. 啟動 bg_scripts（背景 daemon）                   │
      │  2. chroot + qemu-*-static <target_binary>           │
      │  3. 掛 QEMU plugin 錄製 execution trace              │
      │  4. timeout 後收集結果                               │
      ▼                                                       │
[Patcher.diagnose_and_patch]                                  │
      │  對 trace 做靜態分析，識別障礙類型：                  │
      │  - WaitLoop     → timeout 觸發，patch 掉 polling loop│
      │  - PrematureExit → 提前 exit，patch branch 繞過       │
      │  - DaemonFork   → 不讓 daemon 化                     │
      │  - CrashingInstr → segfault 點 nop/retval patch       │
      │  若 patch 成功 → 重新執行（回到 QemuRunner）          │
      ▼
[Checker plugins]
      HTTP: curl 測試 80/443
      UPnP: SSDP M-SEARCH
      DNS:  dig 測試
```

### 1.2 關鍵常數（`Planter.py`）

```python
# Greenhouse/backend/Planter.py

BACKGROUND_SCRIPTS = {"xmldb": "-n gh_xml_root_node -t", "userconfig": ""}

POTENTIAL_HTTPSERV = ["anweb", "httpd", "uhttpd", "lighttpd", "jjhttpd",
                      "shttpd", "thttpd", "minihttpd", "mini_httpd",
                      "mini_httpds", "dhttpd", "alphapd", "goahead", "boa",
                      "appweb", "shgw_httpd", "tenda_httpd", "funjsq_httpd",
                      "webs", "hunt_server", "hydra"]

NVRAM_FOLDER = "libnvram_faker"   # libnvram-faker.so 所在
NVRAM_INIT   = "nvram.ini"        # key=value 格式，啟動時預載
```

---

## 2. 現有瓶頸——Greenhouse 卡在哪裡

### 2.1 Background Daemon 識別不完整

`BACKGROUND_SCRIPTS` 只有兩個硬編碼名稱 (`xmldb`, `userconfig`)。
實務上許多 firmware 需要先啟動 `configd`、`eventd`、`upnpd`、`nas`、`zcip`
等 companion daemon，httpd 才能正常初始化（透過 Unix domain socket 或 shared memory 通訊）。

**現狀**：Greenhouse 不知道需要這些 daemon → httpd 在等待 IPC 回應時 timeout →
觸發 `WaitLoop` patch → patch 後 httpd 繞過初始化但功能殘缺。

### 2.2 NVRAM key 靠品牌猜測

`Fixer.setup_custom_libraries` 從靜態 `nvram.ini` 載入預設值，
再從品牌目錄（`conf/dlink/nvram.ini` 等）補充。
但許多 firmware 需要特定的 key（型號字串、region code、firmware version、license flag）
才能通過啟動時的自我檢查。

**現狀**：缺少 key 時 httpd 呼叫 `nvram_get` 拿到 NULL → 邏輯錯誤 → 提早 exit →
觸發 `PrematureExit` patch，但有時找不到正確的 divergence point。

### 2.3 `PrematureExit` / `WaitLoop` 只能反應式修補

Greenhouse 的 patcher 是**動態觀察到問題才修補**，每次迭代代價高昂
（需要一次完整的 QEMU trace）。若能在第一次執行前就知道哪些 branch 會是障礙，
可以大幅減少迭代次數（目前常見需要 3–6 次）。

### 2.4 非標準 HTTP server 名稱

`POTENTIAL_HTTPSERV` 是靜態白名單。遇到廠商自訂名稱（如 `alphanetworks_httpd`、
`rtspd`、`dweb`）就找不到目標 binary，整個流程失敗。

---

## 3. ChkUp 能提供什麼

ChkUp 對 firmware 更新路徑做靜態分析，本質上是在追蹤
「update binary → IPC → 設定讀取 → 依賴 daemon → 網路呼叫」這條鏈。

這條鏈與 httpd 啟動路徑**高度重疊**，原因是：

1. 更新流程必須讀取 nvram（firmware version、model、region）
2. 更新流程必須與 configd / xmldb 等設定 daemon 溝通
3. 更新流程最終會重啟或呼叫 httpd，因此走到相同的 IPC socket

---

## 4. 期望的整合介面

以下是 Greenhouse 希望從 ChkUp 分析取得的資訊，以及建議的 JSON 格式。

### 4.1 `nvram_hints.json` — 必要的 NVRAM key 清單

```json
{
  "firmware_id": "DIR-868L_fw_revB_2-05b02",
  "nvram_keys": [
    {"key": "fw_ver",       "suggested_value": "2.05B02",  "source": "version_check@0x40a1c0"},
    {"key": "model_name",   "suggested_value": "DIR-868L", "source": "model_check@0x40b330"},
    {"key": "region",       "suggested_value": "EU",       "source": "region_check@0x40b440"},
    {"key": "lan_ipaddr",   "suggested_value": "",         "source": "nvram_get@0x40c120"}
  ]
}
```

- `key`：nvram key 名稱（字串）
- `suggested_value`：若 ChkUp 能從字串常數推斷，填入；否則留空字串
- `source`：找到這個 key 的來源（binary 路徑 + 函式位址，供 debug 用）

Greenhouse 的使用方式：在 `Fixer.update_nvram_map()` 呼叫前注入這些 key，
優先級高於品牌預設值但低於使用者手動設定。

### 4.2 `ipc_deps.json` — 需要預啟動的 companion daemon

```json
{
  "firmware_id": "DIR-868L_fw_revB_2-05b02",
  "companion_daemons": [
    {
      "binary_name": "configd",
      "binary_path": "/usr/sbin/configd",
      "launch_args": "",
      "ipc_type": "unix_socket",
      "socket_path": "/var/run/configd.sock",
      "evidence": "connect(AF_UNIX, /var/run/configd.sock) in httpd@0x40d220"
    },
    {
      "binary_name": "eventd",
      "binary_path": "/usr/sbin/eventd",
      "launch_args": "-d",
      "ipc_type": "shared_memory",
      "socket_path": "",
      "evidence": "shmget(key=0x1234) in httpd@0x40e110"
    }
  ]
}
```

- `binary_name`：用來在 `BACKGROUND_SCRIPTS` 字典補充
- `ipc_type`：`unix_socket` / `shared_memory` / `named_pipe` / `tcp`
- `socket_path`：若是 Unix socket，提供路徑讓 Greenhouse 確保路徑存在
- `evidence`：靜態分析的依據（供 debug）

Greenhouse 的使用方式：注入到 `Planter.get_bg_scripts()` 的回傳字典，
讓 `QemuRunner` 在主 binary 啟動前先 launch 這些 daemon。

### 4.3 `patch_hints.json` — 靜態找到的可疑 branch（潛在修補目標）

```json
{
  "firmware_id": "DIR-868L_fw_revB_2-05b02",
  "patch_hints": [
    {
      "hint_type": "version_check",
      "binary": "/usr/sbin/httpd",
      "branch_addr": "0x40a1c8",
      "fail_target": "0x40a200",
      "pass_target": "0x40a1d4",
      "description": "strcmp(nvram_get('fw_ver'), EXPECTED_VER) == 0 check"
    },
    {
      "hint_type": "wait_loop",
      "binary": "/usr/sbin/httpd",
      "loop_head": "0x40d300",
      "loop_exit": "0x40d350",
      "condition": "unix_socket_connect(/var/run/configd.sock)",
      "description": "polling loop waiting for configd socket"
    },
    {
      "hint_type": "signature_check",
      "binary": "/usr/sbin/httpd",
      "branch_addr": "0x40f110",
      "fail_target": "0x40f180",
      "pass_target": "0x40f120",
      "description": "firmware signature verification result check"
    }
  ]
}
```

- `hint_type`：`version_check` / `wait_loop` / `signature_check` / `model_check`
- `branch_addr`：branch 指令的位址（相對於 binary load base）
- `fail_target` / `pass_target`：兩個分支的目標位址
- `description`：人可讀的描述

Greenhouse 的使用方式：在第一次 `QemuRunner` 執行前，
將這些 hint 餵給 `Patcher.diagnose_and_patch`，讓它優先嘗試這些已知的 patch 點，
而不是從空的 trace 反推。

### 4.4 `web_binary_hints.json` — 非標準 HTTP server 識別

```json
{
  "firmware_id": "DIR-868L_fw_revB_2-05b02",
  "web_binaries": [
    {
      "binary_path": "/usr/sbin/alphapd",
      "evidence": "bind(80) + listen() in update path",
      "confidence": "high"
    }
  ]
}
```

Greenhouse 的使用方式：補充 `POTENTIAL_HTTPSERV` 白名單，
或在 `get_target_binary()` 的搜尋結果中提升優先級。

---

## 5. 建議整合位置

在 `Greenhouse/backend/Planter.py` 的主流程中，整合點如下：

```
[Fixer.initial_setup]  完成架構偵測後
        │
        ▼
[ChkUpPreAnalyzer.run(fs_path, binary_path)]   ← 新增
        │  讀取上述 4 個 JSON（若存在）
        │  注入到 fixer.nvram_map
        │  注入到 bg_scripts
        │  準備 patch_hints 供後續 Patcher 使用
        ▼
[Fixer.setup_custom_libraries]  （nvram 已含 hints）
        │
        ▼
[QemuRunner 第一次執行]  （bg_scripts 已含 companion daemon）
```

這樣設計的好處是**完全向後相容**：若 ChkUp 沒有分析結果，JSON 不存在，
`ChkUpPreAnalyzer` 靜默跳過，Greenhouse 照原本邏輯執行。

---

## 6. 評估標準

一個有效的整合應該讓 Greenhouse 的迭代次數從平均 3–6 次降到 1–2 次。
具體可用以下指標衡量：

| 指標 | 基準線 | 目標 |
|---|---|---|
| 平均 patch 迭代次數 | 3–6 | 1–2 |
| `WaitLoop` patch 發生率 | 高 | 降低（companion daemon 先啟動） |
| `PrematureExit` 找不到 divergence 的失敗率 | ~20% | 降低（patch_hints 提供候選點） |
| 未知 binary 名稱導致的失敗率 | ~10% | 降低（web_binary_hints） |

---

## 7. 補充：Greenhouse 的 QEMU trace 格式

如果 ChkUp 側需要了解 Greenhouse 產生的 trace 格式以便對齊位址：

- Trace 由 QEMU plugin 產生，記錄每個執行到的 basic block 位址
- 格式：每行一個十六進位位址，對應 binary load base 下的 virtual address
- `BinTrunk.py` 用 angr 建構 CFG，trace 中的位址對應 angr 的 basic block 節點
- Load base 可從 `Binary.base_addr` 取得，通常為 `0x400000`（MIPS/ARM ELF 預設）

---

## 8. 聯絡與 Repo 資訊

- Greenhouse repo：`/home/m11315012/greenhouse-single-0415`
- 主要整合檔案：`Greenhouse/backend/Planter.py`（`Fixer` + `Planter` class）
- Patcher 邏輯：`Greenhouse/patcher/Patcher.py`、`premature_exit.py`、`wait_loop.py`
- NVRAM faker config：`Greenhouse/greenhouse_files/libnvram_faker/conf/`
- 目前 angr 版本：`angr-dev/` 目錄下的開發版本（Python 3.12 相容修補版）

如果你（ChkUp 側的 Claude）需要更多關於某個模組的細節，
請讓使用者在 Greenhouse 那邊的 Claude 中問。
