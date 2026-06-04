import json
import os

HINTS_DIR_NAME = "greenhouse_hints"


class ChkUpPreAnalyzer:
    """
    Reads ChkUp static-analysis hints from CHKUP_HINTS_DIR and injects
    them into Greenhouse before the first QEMU run.

    Set CHKUP_HINTS_DIR to the greenhouse_hints/ directory produced by ChkUp.
    If the env var is absent or the directory does not exist, all methods are no-ops.
    """

    def __init__(self):
        hints_dir = os.environ.get("CHKUP_HINTS_DIR", "")
        self._nvram   = self._load(hints_dir, "nvram_hints.json")
        self._ipc     = self._load(hints_dir, "ipc_deps.json")
        self._patches = self._load(hints_dir, "patch_hints.json")
        self._web     = self._load(hints_dir, "web_binary_hints.json")
        self.enabled  = bool(hints_dir and any([self._nvram, self._ipc, self._patches, self._web]))
        if self.enabled:
            print("[ChkUp] Loaded hints from %s" % hints_dir)
        else:
            print("[ChkUp] No hints (set CHKUP_HINTS_DIR to enable pre-analysis)")

    def _load(self, hints_dir, fname):
        if not hints_dir:
            return {}
        path = os.path.join(hints_dir, fname)
        if not os.path.exists(path):
            return {}
        try:
            with open(path) as f:
                return json.load(f)
        except Exception as e:
            print("[ChkUp] Warning: could not load %s: %s" % (fname, e))
            return {}

    # ── NVRAM key injection ──────────────────────────────────────────────────

    def inject_nvram(self, fixer):
        """
        Merge ChkUp-identified NVRAM keys into fixer.nvram_map.
        Only adds keys that are not already present (hints < brand defaults).
        """
        injected = 0
        for entry in self._nvram.get("nvram_keys", []):
            key = entry.get("key", "").strip()
            val = entry.get("suggested_value", "")
            if key and key not in fixer.nvram_map:
                fixer.nvram_map[key] = val
                injected += 1
        if injected:
            print("[ChkUp] Injected %d NVRAM key(s) into nvram_map" % injected)

    # ── Companion daemon commands ────────────────────────────────────────────

    def get_companion_daemon_cmds(self, bin_paths, fs_path):
        """
        Return (cmds, sleeptime) for ChkUp-identified companion daemons.

        cmds     — list of shell-command strings to prepend to run_background.sh
        sleeptime — cumulative sleep seconds to add to bg_sleep
        """
        cmds = []
        total_sleep = 0

        sleep_path = ""
        for bp in sorted(bin_paths, key=len):
            if bp.endswith("/sleep"):
                sleep_path = "/" + os.path.relpath(bp, fs_path)
                break

        # 若 ipc_deps.json 提供了 xmldb root node name，用它覆蓋 xmldb 的啟動參數
        xmldb_node_name = self._ipc.get("xmldb_node_name", "")

        for d in self._ipc.get("companion_daemons", []):
            name     = d.get("binary_name", "").strip()
            hint_path = d.get("binary_path", "").strip()
            args     = d.get("launch_args", "").strip()

            # xmldb 特殊處理：注入正確的 node name
            if name == "xmldb" and xmldb_node_name:
                args = "-n %s -t" % xmldb_node_name
                print("[ChkUp] xmldb node name overridden: %s" % xmldb_node_name)

            found_path = self._find_binary(name, hint_path, bin_paths, fs_path)
            if not found_path:
                print("[ChkUp] Companion daemon '%s' not found in fs, skipping" % name)
                continue

            cmd = ("%s %s &" % (found_path, args)).strip() + " &"
            # avoid double-ampersand
            cmd = found_path + (" %s" % args if args else "") + " &"
            cmds.append(cmd)
            total_sleep += 2
            print("[ChkUp] Companion daemon: %s" % cmd)

        if cmds and sleep_path and total_sleep > 0:
            cmds.append("%s %d" % (sleep_path, min(total_sleep, 10)))

        return cmds, total_sleep

    def _find_binary(self, name, hint_path, bin_paths, fs_path):
        """Locate a binary: try hint_path first, then name-match in bin_paths."""
        if hint_path:
            full = os.path.join(fs_path, hint_path.lstrip("/"))
            if os.path.exists(full):
                return hint_path if hint_path.startswith("/") else "/" + hint_path
        for bp in sorted(bin_paths, key=len):
            if os.path.basename(bp) == name:
                return "/" + os.path.relpath(bp, fs_path)
        return ""

    # ── Patch hints ──────────────────────────────────────────────────────────

    def get_patch_hints(self):
        """
        Return the patch_hints list from ChkUp analysis.

        Each hint is a dict with at minimum:
          hint_type  — 'wait_loop' | 'version_check' | 'model_check' | 'signature_check'
          binary     — path to the binary inside the firmware fs
          description — human-readable note
          loop_head / branch_addr — approximate address (string hex) of the obstacle site
        """
        return self._patches.get("patch_hints", [])

    # ── Web binary candidates ────────────────────────────────────────────────

    def get_web_binary_candidates(self):
        """
        Return [(binary_name, confidence)] sorted so 'high' entries come first.

        Used to extend POTENTIAL_HTTPSERV before searching the firmware fs.
        """
        entries = [
            (os.path.basename(b.get("binary_path", "")), b.get("confidence", "medium"))
            for b in self._web.get("web_binaries", [])
            if b.get("binary_path", "")
        ]
        return sorted(entries, key=lambda x: (x[1] != "high", x[1] != "medium"))

    # ── Device node hints ────────────────────────────────────────────────────

    def get_device_nodes(self):
        """
        回傳 [{"path": "/dev/gpio", "type": "char"}] 清單。
        FirmAE 失敗時，Greenhouse 可用此資訊預建虛擬裝置節點。
        從 ipc_deps.json 的 "device_nodes" 欄位讀取。
        """
        return self._ipc.get("device_nodes", [])
