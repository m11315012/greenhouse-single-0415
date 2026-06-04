#!/usr/bin/env python3
"""
Take screenshots of rehosted firmware web interfaces.

Usage:
    # Screenshot a single result directory:
    python3 screenshot_firmware.py results/dlink/<sha256>

    # Screenshot all successful results under a directory:
    python3 screenshot_firmware.py --all results/dlink/

    # Screenshot and auto-login first:
    python3 screenshot_firmware.py --login results/dlink/<sha256>
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GREENHOUSE_IMAGE = "greenhouse:patched"

SELENIUM_SCRIPT = """
import sys, time
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.common.exceptions import WebDriverException

url        = sys.argv[1]
out_path   = sys.argv[2]
do_login   = sys.argv[3] == "1"
login_url  = sys.argv[4] if len(sys.argv) > 4 else ""
login_user = sys.argv[5] if len(sys.argv) > 5 else ""
login_pass = sys.argv[6] if len(sys.argv) > 6 else ""

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
    driver.save_screenshot(out_path + "/01_index.png")
    print(f"[screenshot] saved 01_index.png  title={driver.title!r}")
except WebDriverException as e:
    print(f"[screenshot] WARNING: {e}")

driver.quit()
print("[screenshot] done")
"""


def find_firmware_dirs(root: Path):
    """Yield (sha256_dir, fw_name_dir, config) for every SUCCESS result under root."""
    for sha_dir in sorted(root.iterdir()):
        if not sha_dir.is_dir():
            continue
        for fw_dir in sorted(sha_dir.iterdir()):
            if not fw_dir.is_dir():
                continue
            cfg_path = fw_dir / "config.json"
            if not cfg_path.exists():
                continue
            try:
                cfg = json.loads(cfg_path.read_text())
            except json.JSONDecodeError:
                continue
            yield sha_dir, fw_dir, cfg


def docker_compose_up(debug_dir: Path) -> bool:
    """Build and start the rehosted firmware. Returns True on success."""
    compose = debug_dir / "docker-compose.yml"
    if not compose.exists():
        print(f"  [!] docker-compose.yml not found at {debug_dir}")
        return False
    print(f"  [*] Building rehosted image in {debug_dir} ...")
    r = subprocess.run(["docker-compose", "build"], cwd=debug_dir,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  [!] docker-compose build failed:\n{r.stderr[-500:]}")
        return False
    print(f"  [*] Starting rehosted firmware ...")
    subprocess.run(["docker-compose", "up", "-d"], cwd=debug_dir,
                   capture_output=True, text=True)
    return True


def docker_compose_down(debug_dir: Path):
    subprocess.run(["docker-compose", "down", "--remove-orphans"],
                   cwd=debug_dir, capture_output=True, text=True)


def take_screenshot(fw_dir: Path, cfg: dict, do_login: bool) -> Path | None:
    """
    Spin up a temporary Greenhouse container (--network host) and use
    the bundled Chrome + Selenium to screenshot the firmware web UI.
    Returns the screenshot directory on success, None on failure.
    """
    ip   = cfg.get("targetip",   "172.21.0.2")
    port = cfg.get("targetport", "80")
    url  = f"http://{ip}:{port}"

    screenshot_dir = fw_dir / "screenshots"
    screenshot_dir.mkdir(exist_ok=True)

    # Write the selenium script to a temp file we'll mount into the container
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py",
                                    delete=False, prefix="gh_ss_") as f:
        f.write(SELENIUM_SCRIPT)
        script_path = f.name

    login_url  = cfg.get("loginurl",      "")
    login_user = cfg.get("loginuser",     "")
    login_pass = cfg.get("loginpassword", "")

    container_ss_dir = "/tmp/screenshots"
    cmd = [
        "docker", "run", "--rm",
        "--network", "host",
        "-v", f"{script_path}:/tmp/ss_script.py:ro",
        "-v", f"{screenshot_dir.resolve()}:{container_ss_dir}",
        GREENHOUSE_IMAGE,
        "bash", "-c",
        f"source /root/venv/bin/activate && "
        f"python3 /tmp/ss_script.py "
        f"'{url}' '{container_ss_dir}' "
        f"'{'1' if do_login else '0'}' "
        f"'{login_url}' '{login_user}' '{login_pass}'"
    ]

    print(f"  [*] Taking screenshot of {url} ...")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    os.unlink(script_path)

    if result.returncode != 0:
        print(f"  [!] Screenshot container failed:\n{result.stderr[-300:]}")
        return None

    print(result.stdout.strip())
    imgs = list(screenshot_dir.glob("*.png"))
    if imgs:
        print(f"  [+] {len(imgs)} screenshot(s) saved to {screenshot_dir}")
        return screenshot_dir
    else:
        print(f"  [!] No screenshots found in {screenshot_dir}")
        return None


def process_one(result_root: Path, do_login: bool, wait_secs: int):
    """Process a single <sha256> result directory."""
    entries = list(find_firmware_dirs(result_root))
    if not entries:
        print(f"[!] No valid firmware results found under {result_root}")
        return

    for sha_dir, fw_dir, cfg in entries:
        fw_name = fw_dir.name
        status  = cfg.get("result", "?")
        ip      = cfg.get("targetip",   "172.21.0.2")
        port    = cfg.get("targetport", "80")
        print(f"\n{'='*60}")
        print(f"  Firmware : {fw_name}")
        print(f"  Status   : {status}")
        print(f"  Target   : http://{ip}:{port}")

        if status != "SUCCESS":
            print(f"  [!] Skipping — result is not SUCCESS")
            continue

        debug_dir = fw_dir / "debug"
        started = docker_compose_up(debug_dir)
        if not started:
            continue

        try:
            print(f"  [*] Waiting {wait_secs}s for firmware to initialise ...")
            time.sleep(wait_secs)
            take_screenshot(fw_dir, cfg, do_login)
        finally:
            print(f"  [*] Stopping firmware ...")
            docker_compose_down(debug_dir)


def main():
    parser = argparse.ArgumentParser(
        description="Screenshot rehosted firmware web interfaces")
    parser.add_argument("result_path",
        help="Path to a single <sha256> result dir, or (with --all) a parent dir")
    parser.add_argument("--all", action="store_true",
        help="Process every result directory found under result_path")
    parser.add_argument("--login", action="store_true",
        help="Attempt to log in before taking screenshot")
    parser.add_argument("--wait", type=int, default=60,
        help="Seconds to wait after docker-compose up before screenshotting (default: 60)")
    args = parser.parse_args()

    root = Path(args.result_path).resolve()
    if not root.exists():
        print(f"[ERROR] Path not found: {root}", file=sys.stderr)
        sys.exit(1)

    # Check greenhouse image exists
    r = subprocess.run(["docker", "image", "inspect", GREENHOUSE_IMAGE],
                       capture_output=True)
    if r.returncode != 0:
        print(f"[ERROR] Docker image '{GREENHOUSE_IMAGE}' not found.", file=sys.stderr)
        sys.exit(1)

    if args.all:
        # root is a parent dir containing multiple <sha256> subdirs
        sha_dirs = [d for d in sorted(root.iterdir()) if d.is_dir()]
        print(f"[*] Processing {len(sha_dirs)} result(s) under {root}")
        for sha_dir in sha_dirs:
            process_one(sha_dir, args.login, args.wait)
    else:
        process_one(root, args.login, args.wait)

    print("\n[*] All done.")


if __name__ == "__main__":
    main()
