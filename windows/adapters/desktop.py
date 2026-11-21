"""Identify a running Codex desktop window in the current Windows session."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path

PACKAGE_FAMILY = "OpenAI.Codex_2p2nqsd0c76g0"


def profile_paths():
    # Electron's per-user profile can be redirected into MSIX LocalCache.
    paths = (Path(os.environ["APPDATA"]) / "Codex",
             Path(os.environ["LOCALAPPDATA"]) / "Packages" / PACKAGE_FAMILY / "LocalCache/Roaming/Codex")
    return tuple(str(path) for path in paths if path.is_dir())


def launch_time():
    if os.name != "nt":
        return None
    user = ctypes.WinDLL("user32")
    kernel = ctypes.WinDLL("kernel32")
    enum_proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user.EnumWindows.argtypes = (enum_proc, wintypes.LPARAM)
    user.GetWindowThreadProcessId.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.DWORD))
    kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel.GetPackageFamilyName.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.UINT), wintypes.LPWSTR)
    kernel.GetProcessTimes.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 4

    pids = set()
    @enum_proc
    def collect(hwnd, _):
        pid = wintypes.DWORD()
        user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        pids.add(pid.value)
        return True
    user.EnumWindows(collect, 0)

    started = []
    for pid in pids:
        handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            continue
        try:
            family = ctypes.create_unicode_buffer(256)
            size = wintypes.UINT(len(family))
            if kernel.GetPackageFamilyName(handle, ctypes.byref(size), family) or family.value != PACKAGE_FAMILY:
                continue
            times = [wintypes.FILETIME() for _ in range(4)]
            if kernel.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)):
                ticks = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
                started.append(ticks / 10_000_000 - 11644473600)
        finally:
            kernel.CloseHandle(handle)
    return min(started, default=None)
