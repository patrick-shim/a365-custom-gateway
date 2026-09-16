"""Local-only final-package proof using native Windows DETACHED_PROCESS.

The caller validates all package hashes first. This fixture never writes package
files or runs provider scripts, and records only fixed markers and scalar counts.
"""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys


class IoCounters(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in
                ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]


class BasicLimits(ctypes.Structure):
    _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                ("flags", wintypes.DWORD), ("min_working_set", ctypes.c_size_t),
                ("max_working_set", ctypes.c_size_t), ("active_processes", wintypes.DWORD),
                ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]


class ExtendedLimits(ctypes.Structure):
    _fields_ = [("basic", BasicLimits), ("io", IoCounters), ("process_memory", ctypes.c_size_t),
                ("job_memory", ctypes.c_size_t), ("peak_process_memory", ctypes.c_size_t),
                ("peak_job_memory", ctypes.c_size_t)]


def run(root, executable, arguments, hooked):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.SetInformationJobObject.restype = wintypes.BOOL
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise RuntimeError("LOCAL_JOB_CREATE_FAILED")
    process = None
    try:
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise RuntimeError("LOCAL_JOB_LIMIT_FAILED")
        environment = os.environ.copy()
        for key in ("DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "DOTNET_SHARED_STORE"):
            environment.pop(key, None)
        environment["DOTNET_EnableDiagnostics"] = "0"
        if hooked:
            environment["DOTNET_STARTUP_HOOKS"] = str(root / "Gateway.Purview.Executor.StartupDiagnostics.dll")
        process = subprocess.Popen(
            [str(executable), *arguments], cwd=root, env=environment,
            creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if not kernel.AssignProcessToJobObject(job, wintypes.HANDLE(int(process._handle))):
            process.kill()
            raise RuntimeError("LOCAL_JOB_ASSIGN_FAILED")
        output, error = process.communicate(timeout=45)
        return process.returncode, output.decode("utf-8"), error.decode("utf-8")
    finally:
        kernel.CloseHandle(job)  # Own process tree only; also covers timeout/abort.
        if process is not None:
            if process.poll() is None:
                process.wait(timeout=5)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()


def main():
    if sys.platform != "win32" or len(sys.argv) != 3:
        raise RuntimeError("WINDOWS_FINAL_PACKAGE_ARGUMENTS_REQUIRED")
    root = Path(sys.argv[1]).resolve()
    manifest = sys.argv[2]
    if len(manifest) != 71 or not manifest.startswith("sha256:"):
        raise RuntimeError("INVALID_MANIFEST_BINDING")
    cases = [
        ("consolehost-control", root / "PowerShell" / "pwsh.exe",
         ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", '[Console]::Write("fixture")'], False),
        ("console-free-child", root / "Gateway.Purview.PowerShellHost.exe",
         ["--manifest", manifest, "--probe"], False),
        ("console-free-child-native-proof", root / "Gateway.Purview.PowerShellHost.exe",
         ["--manifest", manifest, "--diagnostic-probe"], True),
    ]
    expected_markers = ["GWDIAG|ENTRY|None|0", "GWDIAG|CONOUT_FAILED|Win32Exception|6",
                        "GWDIAG|COMMAND_ENTRY|None|0", "GWDIAG|COMMAND_COMPLETE|None|0"]
    rows = []
    for name, executable, arguments, hooked in cases:
        code, output, error = run(root, executable, arguments, hooked)
        markers = error.splitlines() if hooked else []
        if hooked and markers != expected_markers:
            raise RuntimeError("UNEXPECTED_MARKERS_SUPPRESSED")
        rows.append(dict(scenario=name, exitCode=code, stdoutCharacters=len(output),
                         stderrCharacters=len(error), exactVersionPair=output == "7.6.5|3.10.1",
                         markers=markers))
    if not (rows[0]["exitCode"] == 0 and rows[0]["stdoutCharacters"] == 0 and rows[0]["stderrCharacters"] == 0
            and rows[1]["exitCode"] == 0 and rows[1]["exactVersionPair"] and rows[1]["stderrCharacters"] == 0
            and rows[2]["exitCode"] == 0 and rows[2]["exactVersionPair"]):
        raise RuntimeError("DETACHED_PROOF_FAILED")
    print(json.dumps(dict(creationFlags=520, consoleFreeSucceeded=True, consoleUnavailable=True,
                          processTreeCleanup="Owned kill-on-close job", cases=rows)))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("LOCAL_DETACHED_PROOF_FAILED; raw streams and environment suppressed.", file=sys.stderr)
        sys.exit(1)
