#!/usr/bin/env python3
"""Release a dataset migrator blocked on a live mount helper.

The helper is used when an older migrator is still waiting on a foreground
FUSE process such as rclone mount. The mount process is moved into its own
session, any inherited copy of the migrator lock is closed, and only the
stuck migrator exits. The mount process is not signaled.

Exit status:
  0  a stuck migrator was released
  1  no stuck remount holder was found
  2  a holder looked unsafe to release; nothing was signaled
"""

from __future__ import annotations

import argparse
import ctypes
import os
import sys

PTRACE_GETREGS = 12
PTRACE_SETREGS = 13
PTRACE_ATTACH = 16
PTRACE_DETACH = 17
PTRACE_SINGLESTEP = 9
SYS_CLOSE = 3
SYS_SETSID = 112
SYS_EXIT_GROUP = 231
MOUNT_HELPERS = {
    "rclone",
    "sshfs",
    "mergerfs",
    "mount",
    "fusermount",
    "fusermount3",
    "unionfs",
    "unionfs-fuse",
    "bindfs",
    "curlftpfs",
    "s3fs",
    "gocryptfs",
    "borg",
}
LOGGER_COMMS = {"tee", "logger"}


class Regs(ctypes.Structure):
    _fields_ = [
        ("r15", ctypes.c_uint64),
        ("r14", ctypes.c_uint64),
        ("r13", ctypes.c_uint64),
        ("r12", ctypes.c_uint64),
        ("rbp", ctypes.c_uint64),
        ("rbx", ctypes.c_uint64),
        ("r11", ctypes.c_uint64),
        ("r10", ctypes.c_uint64),
        ("r9", ctypes.c_uint64),
        ("r8", ctypes.c_uint64),
        ("rax", ctypes.c_uint64),
        ("rcx", ctypes.c_uint64),
        ("rdx", ctypes.c_uint64),
        ("rsi", ctypes.c_uint64),
        ("rdi", ctypes.c_uint64),
        ("orig_rax", ctypes.c_uint64),
        ("rip", ctypes.c_uint64),
        ("cs", ctypes.c_uint64),
        ("eflags", ctypes.c_uint64),
        ("rsp", ctypes.c_uint64),
        ("ss", ctypes.c_uint64),
        ("fs_base", ctypes.c_uint64),
        ("gs_base", ctypes.c_uint64),
        ("ds", ctypes.c_uint64),
        ("es", ctypes.c_uint64),
        ("fs", ctypes.c_uint64),
        ("gs", ctypes.c_uint64),
    ]


def log(message: str) -> None:
    print(message, flush=True)


def libc_ptrace():
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.ptrace.argtypes = [
        ctypes.c_uint64,
        ctypes.c_uint64,
        ctypes.c_uint64,
        ctypes.c_uint64,
    ]
    libc.ptrace.restype = ctypes.c_int64
    return libc


def ptrace(libc, request: int, pid: int, addr: int = 0, data: int = 0) -> int:
    ctypes.set_errno(0)
    result = libc.ptrace(request, pid, addr, data)
    error = ctypes.get_errno()
    if result == -1 and error != 0:
        raise OSError(error, f"ptrace {request} pid {pid}: {os.strerror(error)}")
    return int(result)


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def comm_of(proc_root: str, pid: int) -> str:
    return read_text(os.path.join(proc_root, str(pid), "comm")).strip()


def cmdline_of(proc_root: str, pid: int) -> list[str]:
    path = os.path.join(proc_root, str(pid), "cmdline")
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return []
    if not raw:
        return []
    parts = raw.split(b"\0")
    return [part.decode("utf-8", "replace") for part in parts if part]


def session_id(proc_root: str, pid: int) -> int | None:
    stat = read_text(os.path.join(proc_root, str(pid), "stat"))
    if ")" not in stat:
        return None
    fields = stat.rsplit(")", 1)[1].split()
    if len(fields) < 4:
        return None
    try:
        return int(fields[3])
    except ValueError:
        return None


def child_pids(proc_root: str, parent: int) -> list[int]:
    found: list[int] = []
    try:
        names = os.listdir(proc_root)
    except OSError:
        return found
    for name in names:
        if not name.isdigit():
            continue
        status = read_text(os.path.join(proc_root, name, "status"))
        for line in status.splitlines():
            if line.startswith("PPid:"):
                ppid = line.split()[-1]
                if ppid == str(parent):
                    found.append(int(name))
                break
    return found


def descendants(proc_root: str, pid: int) -> list[int]:
    found: list[int] = []
    for child in child_pids(proc_root, pid):
        found.extend(descendants(proc_root, child))
        found.append(child)
    return found


def fd_targets(proc_root: str, pid: int) -> dict[int, str]:
    root = os.path.join(proc_root, str(pid), "fd")
    found: dict[int, str] = {}
    try:
        entries = os.listdir(root)
    except OSError:
        return found
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            found[int(entry)] = os.readlink(os.path.join(root, entry))
        except OSError:
            continue
    return found


def lock_fds(proc_root: str, pid: int, lock_path: str) -> list[int]:
    wanted = {lock_path}
    try:
        wanted.add(os.path.realpath(lock_path))
    except OSError:
        pass
    matches: list[int] = []
    for number, target in fd_targets(proc_root, pid).items():
        if target in wanted:
            matches.append(number)
            continue
        try:
            if os.path.realpath(target) in wanted:
                matches.append(number)
        except OSError:
            continue
    return sorted(matches)


def parent_pid(proc_root: str, pid: int) -> int:
    status = read_text(os.path.join(proc_root, str(pid), "status"))
    for line in status.splitlines():
        if line.startswith("PPid:"):
            try:
                return int(line.split()[-1])
            except ValueError:
                return 0
    return 0


def is_under(proc_root: str, pid: int, ancestor: int) -> bool:
    seen: set[int] = set()
    current = pid
    while current > 1 and current not in seen:
        seen.add(current)
        parent = parent_pid(proc_root, current)
        if parent == ancestor:
            return True
        current = parent
    return False


def holder_pids(proc_root: str, lock_path: str, self_pid: int) -> list[int]:
    holders: list[int] = []
    try:
        names = os.listdir(proc_root)
    except OSError:
        return holders
    for name in names:
        if not name.isdigit() or int(name) == self_pid:
            continue
        if lock_fds(proc_root, int(name), lock_path):
            holders.append(int(name))
    return holders


def unescape_mountinfo(value: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(value):
        if value[index] == "\\" and index + 3 < len(value):
            octal = value[index + 1 : index + 4]
            if octal.isdigit():
                output.append(chr(int(octal, 8)))
                index += 4
                continue
        output.append(value[index])
        index += 1
    return "".join(output)


def mounted_targets(mountinfo_path: str) -> set[str]:
    targets: set[str] = set()
    try:
        lines = open(mountinfo_path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return targets
    for line in lines:
        fields = line.split()
        if len(fields) < 5:
            continue
        target = unescape_mountinfo(fields[4])
        try:
            target = os.path.realpath(target)
        except OSError:
            pass
        targets.add(target)
    return targets


def is_logger(proc_root: str, pid: int) -> bool:
    comm = comm_of(proc_root, pid)
    if comm in LOGGER_COMMS:
        return True
    argv = cmdline_of(proc_root, pid)
    if not argv:
        return False
    base = os.path.basename(argv[0])
    return base in LOGGER_COMMS


def is_mount_helper(proc_root: str, pid: int, mounted: set[str]) -> bool:
    comm = comm_of(proc_root, pid)
    argv = cmdline_of(proc_root, pid)
    base = os.path.basename(argv[0]) if argv else comm
    if comm not in MOUNT_HELPERS and base not in MOUNT_HELPERS:
        return False
    for arg in argv:
        if not arg.startswith("/"):
            continue
        try:
            candidate = os.path.realpath(arg)
        except OSError:
            candidate = arg
        if candidate in mounted or arg in mounted:
            return True
    return False


def find_syscall_site(pid: int) -> int:
    maps_path = f"/proc/{pid}/maps"
    mem_path = f"/proc/{pid}/mem"
    with open(maps_path, encoding="utf-8", errors="replace") as maps, open(mem_path, "rb", buffering=0) as memory:
        for line in maps:
            parts = line.split()
            if len(parts) < 2 or "x" not in parts[1]:
                continue
            path = parts[-1] if len(parts) >= 6 else ""
            if path.startswith("["):
                continue
            start_text, end_text = parts[0].split("-")
            start = int(start_text, 16)
            end = int(end_text, 16)
            span = end - start
            if span <= 0 or span > 16_000_000:
                continue
            try:
                memory.seek(start)
                blob = memory.read(span)
            except OSError:
                continue
            offset = blob.find(b"\x0f\x05")
            if offset != -1:
                return start + offset
    raise OSError(f"no syscall instruction in pid {pid}")


def inject_syscall(libc, pid: int, number: int, arg0: int = 0) -> tuple[str, int]:
    ptrace(libc, PTRACE_ATTACH, pid)
    os.waitpid(pid, 0)
    regs = Regs()
    ptrace(libc, PTRACE_GETREGS, pid, 0, ctypes.addressof(regs))
    saved = Regs.from_buffer_copy(regs)
    site = find_syscall_site(pid)
    regs.rip = site
    regs.rax = number
    regs.rdi = arg0
    regs.rsi = 0
    regs.rdx = 0
    regs.r10 = 0
    regs.r8 = 0
    regs.r9 = 0
    ptrace(libc, PTRACE_SETREGS, pid, 0, ctypes.addressof(regs))
    ptrace(libc, PTRACE_SINGLESTEP, pid, 0, 0)
    _wpid, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status) or os.WIFSIGNALED(status):
        return "dead", status
    after = Regs()
    ptrace(libc, PTRACE_GETREGS, pid, 0, ctypes.addressof(after))
    result = int(after.rax)
    ptrace(libc, PTRACE_SETREGS, pid, 0, ctypes.addressof(saved))
    ptrace(libc, PTRACE_DETACH, pid, 0, 0)
    return "ok", result


def syscall_failed(result: int) -> bool:
    return result > 0xFFFFFFFFFFFFF000


def close_lock_fds(libc, proc_root: str, pid: int, lock_path: str) -> None:
    for number in lock_fds(proc_root, pid, lock_path):
        closed, close_result = inject_syscall(libc, pid, SYS_CLOSE, number)
        if closed != "ok" or syscall_failed(close_result):
            raise OSError(f"could not close inherited lock fd {number} in pid {pid}")
    if lock_fds(proc_root, pid, lock_path):
        raise OSError(f"pid {pid} still holds the migrator lock")


def detach_mount_child(libc, proc_root: str, pid: int, lock_path: str) -> None:
    for descendant in descendants(proc_root, pid):
        close_lock_fds(libc, proc_root, descendant, lock_path)
    state, result = inject_syscall(libc, pid, SYS_SETSID, 0)
    if state != "ok":
        raise OSError(f"mount helper {pid} exited while entering a new session")
    own_session = session_id(proc_root, pid)
    if syscall_failed(result) and own_session != pid:
        raise OSError(f"mount helper {pid} stayed in its old session")
    close_lock_fds(libc, proc_root, pid, lock_path)


def release_holder(libc, proc_root: str, holder: int, children: list[int], lock_path: str) -> None:
    for child in children:
        if is_logger(proc_root, child):
            close_lock_fds(libc, proc_root, child, lock_path)
            continue
        detach_mount_child(libc, proc_root, child, lock_path)
        log(f"Detached mount helper {child} into its own session without signaling it.")
    for child in child_pids(proc_root, holder):
        close_lock_fds(libc, proc_root, child, lock_path)
    state, _status = inject_syscall(libc, holder, SYS_EXIT_GROUP, 0)
    if state != "dead":
        raise OSError(f"stuck migrator {holder} did not exit")
    log(f"Released stuck migrator {holder}. Its mount helper was left running.")


def classify(proc_root: str, holder: int, mounted: set[str]) -> tuple[str, list[int]]:
    children = child_pids(proc_root, holder)
    mount_children = [pid for pid in children if is_mount_helper(proc_root, pid, mounted)]
    other = [pid for pid in children if not is_logger(proc_root, pid) and pid not in mount_children]
    if mount_children and not other:
        return "stuck-mount", mount_children
    if mount_children and other:
        return "unsafe", mount_children
    return "busy", []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--proc-root", default="/proc")
    parser.add_argument("--mountinfo", default="/proc/self/mountinfo")
    parser.add_argument("--self-pid", type=int, default=os.getpid())
    args = parser.parse_args()

    if os.uname().machine != "x86_64":
        log("Refusing to release a stuck migrator on this architecture.")
        return 2

    mounted = mounted_targets(args.mountinfo)
    holders = [
        pid
        for pid in holder_pids(args.proc_root, args.lock, args.self_pid)
        if not is_mount_helper(args.proc_root, pid, mounted)
    ]
    holders = [
        pid
        for pid in holders
        if not any(other != pid and is_under(args.proc_root, pid, other) for other in holders)
    ]
    if not holders:
        log("No other process is holding the dataset migrator lock.")
        return 1

    stuck: list[tuple[int, list[int]]] = []
    for holder in holders:
        if not os.path.exists(os.path.join(args.proc_root, str(holder))):
            continue
        kind, children = classify(args.proc_root, holder, mounted)
        if kind == "stuck-mount":
            stuck.append((holder, children))
            continue
        if kind == "unsafe":
            log(
                f"Migrator {holder} has a mount helper and other children. "
                "It was left running, and the mount helper was not signaled."
            )
            return 2
        log(f"Migrator {holder} is running and is not blocked only on a live mount helper.")

    if not stuck:
        return 1

    try:
        libc = libc_ptrace()
        for holder, children in stuck:
            release_holder(libc, args.proc_root, holder, children, args.lock)
    except OSError as exc:
        log(f"Could not release the stuck migrator safely: {exc}")
        log("The mount helper was not signaled.")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
