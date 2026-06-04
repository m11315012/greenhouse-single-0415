from . import *
from .patches import *

import importlib, inspect
import os
import operator

class Patcher:  
    def __init__(self, whitelist=None, blacklist=[]):
        self.pObstacles = []

        all_obstacles=os.listdir("patcher")
        all_obstacles.remove('__init__.py')
        all_obstacles.remove('Patcher.py')

        print(all_obstacles)

        for obstacleName in all_obstacles:
            if obstacleName.endswith(".py"):
                obstacleName = obstacleName[:-3]
                if whitelist and obstacleName not in whitelist:
                    continue
                if obstacleName in blacklist:
                    continue
                obs = importlib.import_module("patcher."+obstacleName)
                members = inspect.getmembers(obs)
                for mem in members:
                    path_name = str(mem[1])+"."+str(mem[0])
                    print("    - ", mem)
                    print("    - ",path_name)
                    if obstacleName in path_name:
                        self.pObstacles.append(mem[1]())
                        break

        self.pObstacles = sorted(self.pObstacles, key=operator.attrgetter('priority'), reverse=True)

    def diagnose_and_patch(self, binary, bintrunk, trace, trace_trunk_path, index, exit_code, timedout, errored, daemonized, skip=False, changelog=[], patch_hints=None):
        patchers = []

        # 將 hints 依類型分類，傳給對應的 patcher
        wait_loop_hints = []
        exit_hints = []
        if patch_hints:
            print("[ChkUp] %d static hint(s) available:" % len(patch_hints))
            for h in patch_hints:
                addr = h.get("branch_addr") or h.get("loop_head", "")
                print("    - [%s] %s @ %s" % (h.get("hint_type", "?"), h.get("description", ""), addr))
                if h.get("hint_type") == "wait_loop":
                    wait_loop_hints.append(h)
                elif h.get("hint_type") in ("version_check", "model_check", "signature_check"):
                    exit_hints.append(h)

        print("Patch Priority: ", [str(p)+":"+str(p.priority) for p in self.pObstacles])
        for pObs in self.pObstacles:
            print("Diagnosing with", pObs)
            kwargs = {}
            if type(pObs).__name__ == "WaitLoop" and wait_loop_hints:
                kwargs["loop_hints"] = wait_loop_hints
            if type(pObs).__name__ == "PrematureExit" and exit_hints:
                kwargs["exit_hints"] = exit_hints
            if pObs.diagnose(binary, bintrunk, trace, trace_trunk_path, index, exit_code, timedout, errored, daemonized, **kwargs):
                print("Found appropriate patcher: ", pObs)
                patchers.append(pObs)

        if skip:
            return False

        print("Trying patchers: ", patchers)
        for patcher in patchers:
            result = patcher.applyPatch(binary, bintrunk, trace, trace_trunk_path, index, exit_code, timedout, errored, daemonized, changelog=changelog)
            if result:
                return True

        return False