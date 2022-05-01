const std = @import("std");
const win32 = @import("win32");

const foundation = win32.foundation;
const HWND = foundation.HWND;
const HRESULT = foundation.HRESULT;
const DWORD = std.os.windows.DWORD;
const PVOID = std.os.windows.PVOID;
pub const DWMA_CLOAKED: DWORD = 13;

pub extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, dwAttribute: DWORD, pvAttribute: PVOID, cbAttribute: DWORD) callconv(.C) HRESULT;
