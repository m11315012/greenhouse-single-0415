from .patches import *
import time
import json
import os

_TIMING_LOG = "/tmp/fuverify_patch_timing.jsonl"

def _log_timing(record: dict):
    with open(_TIMING_LOG, "a") as f:
        f.write(json.dumps(record) + "\n")

class PrematureExit:    
    def __init__(self):
        self.priority = 5
        self.is_exit = False
        self.avoid_addr = -1
        self.parent = None
        self.old_node = None
        self.alt_node = None

    def diagnose(self, binary, bintrunk, trace, trace_trunk_path, index, exit_code, timedout, errored, daemonized, exit_hints=None):
        self.avoid_addr = -1
        self.parent = None
        self.old_node = None
        self.alt_node = None
        exit_addr = -1
        self.exit_tags = ["shutdown", "reboot", "die", "exit", "_exit"]

        if timedout == False and exit_code != None:
            parent_addr_trace_seq = trace.read_trace(trace.traces[trace.parent_pid])
            parent_addr_trace_seq = bintrunk.unroll_trace(parent_addr_trace_seq)
            trace_len = len(parent_addr_trace_seq)
            hint_time = 0.0
            fullscan_time = 0.0

            # Hint-guided fast path: search a trimmed trace window near each hint
            # address before falling back to the full O(N) scan.
            if exit_hints:
                t0 = time.perf_counter()
                for hint in exit_hints:
                    addr_str = hint.get("branch_addr", "")
                    if not addr_str:
                        continue
                    try:
                        hint_addr = int(addr_str, 16)
                    except ValueError:
                        continue
                    hint_nodes = bintrunk.find_nodes_near_addr(hint_addr)
                    if not hint_nodes:
                        continue
                    trimmed = bintrunk.trim_trace_near_nodes(
                        trace_trunk_path, hint_nodes, window=150
                    )
                    if not trimmed:
                        continue
                    trimmed_addr_seq = bintrunk.unroll_trace(trimmed)
                    for tag in self.exit_tags:
                        exit_addr = bintrunk.addr_trace_find_func_callsites(
                            trimmed_addr_seq, tag
                        )
                        if exit_addr >= 0:
                            print("[ChkUp] PrematureExit found via hint @ %s (tag: %s)"
                                  % (addr_str, tag))
                            break
                    if exit_addr >= 0:
                        break
                hint_time = time.perf_counter() - t0
                if exit_addr < 0:
                    print("[ChkUp] PrematureExit hints did not match, "
                          "falling back to full trace scan")

            if exit_addr < 0:
                t1 = time.perf_counter()
                for tag in self.exit_tags:
                    exit_addr = bintrunk.addr_trace_find_func_callsites(
                        parent_addr_trace_seq, tag
                    )
                    if exit_addr >= 0:
                        print("    - found addr %x for tag %s" % (exit_addr, tag))
                        break
                fullscan_time = time.perf_counter() - t1
                _log_timing({
                    "patcher": "PrematureExit",
                    "iteration": index,
                    "trace_len": trace_len,
                    "hints_provided": exit_hints is not None and len(exit_hints) > 0,
                    "hint_matched": False,
                    "hint_time_s": round(hint_time, 4),
                    "fullscan_time_s": round(fullscan_time, 4),
                    "total_time_s": round(hint_time + fullscan_time, 4),
                })
            else:
                _log_timing({
                    "patcher": "PrematureExit",
                    "iteration": index,
                    "trace_len": trace_len,
                    "hints_provided": exit_hints is not None and len(exit_hints) > 0,
                    "hint_matched": True,
                    "hint_time_s": round(hint_time, 4),
                    "fullscan_time_s": 0.0,
                    "total_time_s": round(hint_time, 4),
                })

            if exit_addr < 0:
                # check if last touched address is an exit
                last_addr_node = trace_trunk_path[-1]
                for node in bintrunk.graph.nodes:
                    if last_addr_node in str(node):
                        if "exit" in str(node):
                            exit_addr = bintrunk.node_name_to_addr(node)
                            break

            if exit_addr < 0:
                print("Unable to find exit address to avoid, stopping...")
                return False

            if bintrunk.is_program_code(exit_addr):
                self.avoid_addr = exit_addr
            else:
                self.avoid_addr  = bintrunk.node_trace_get_caller_for_addr_in_sequence(trace_trunk_path, exit_addr)

            print("Dodging an exit...")
            print("Finding closest divergence node that avoids previous termination point %x..." % self.avoid_addr)
            # identify branch points
            # try branch points until we avoid the exit
            self.parent, self.old_node, self.alt_node = bintrunk.find_divergence_avoid_node(parent_addr_trace_seq, trace_trunk_path, self.avoid_addr)

            if self.parent == None or self.old_node == None or self.alt_node == None:
                print("Unable to find divergence to avoid exits/loops, exiting...")
                print("   --> ", self.parent, self.old_node, self.alt_node)
                return False

            print("Divergence Node: %s->%s should become %s->%s" % (self.parent, self.old_node, self.parent, self.alt_node))

            self.is_exit = True
            return True
        return False

    def applyPatch(self, binary, bintrunk, trace, trace_trunk_path, index, exit_code, timedout, errored, daemonized, changelog=[]):
        if self.is_exit:
            print("Applying PrematureExit Patch...")
            # set up and perform jump address patch
            parent_addr = bintrunk.node_name_to_addr(self.parent)
            new_target_addr = bintrunk.node_name_to_addr(self.alt_node)

            jmp_instr_addr = bintrunk.get_last_jmp_instr_addr(parent_addr)

            if jmp_instr_addr is None:
                print("    - invalid jmp_instr_addr for parent_addr %x" % parent_addr)
                self.is_exit = None
                return False

            # convert offsets for r2 patching
            jmp_instr_addr = jmp_instr_addr + (binary.base_addr - bintrunk.base_addr) #add base addr offset
            parent_addr = parent_addr + (binary.base_addr - bintrunk.base_addr) #add base addr offset
            new_target_addr = new_target_addr + (binary.base_addr - bintrunk.base_addr) #add base addr offset

            instr_to_patch, op = binary.get_instr(jmp_instr_addr)

            if jmp_instr_addr is None or instr_to_patch is None or op is None:
                print("    - invalid instruction to patch %s, %s at addr %x..." % (instr_to_patch, op, jmp_instr_addr))
                self.is_exit = None
                return False

            patchLine = "    - patching instruction [%s %s] at %x to [jmp %x]" % (instr_to_patch, op, jmp_instr_addr, new_target_addr)
            print(patchLine)
            changelog.append("[ROADBLOCK] requires patching of check that leads to exit")
            changelog.append("[PremExit] %s" % patchLine)

            jmpPatch = SwitchJmpPatch(binary.arch, jmp_instr_addr, new_target_addr)
            binary.addPatch(jmp_instr_addr, jmpPatch)
            binary.applyPatch(jmp_instr_addr)

            print("    - Patch Completed!")
            self.is_exit = False
            return True

        self.is_exit = False
        return False