const std = @import("std");
const win32 = @import("win32");

const foundation = win32.foundation;
const HWND = foundation.HWND;
const HRESULT = foundation.HRESULT;
const DWORD = std.os.windows.DWORD;
const PVOID = std.os.windows.PVOID;
pub const DWMA_CLOAKED: DWORD = 13;

pub extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, dwAttribute: DWORD, pvAttribute: PVOID, cbAttribute: DWORD) callconv(.C) HRESULT;

pub extern fn GetSystemMetrics(index: c_int) callconv(.C) c_int;

pub const SM_XVIRTUALSCREEN = 76;
pub const SM_YVIRTUALSCREEN = 77;
pub const SM_CXVIRTUALSCREEN = 78;
pub const SM_CYVIRTUALSCREEN = 79;
