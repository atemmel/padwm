const std = @import("std");
const win32 = @import("win32");
const wam = win32.ui.windows_and_messaging;

const foundation = win32.foundation;
const HWND = foundation.HWND;
const HRESULT = foundation.HRESULT;
const DWORD = std.os.windows.DWORD;
const PVOID = std.os.windows.PVOID;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const DWMA_CLOAKED: DWORD = 13;

pub extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, dwAttribute: DWORD, pvAttribute: PVOID, cbAttribute: DWORD) callconv(.C) HRESULT;

pub extern fn GetSystemMetrics(index: c_int) callconv(.C) c_int;

pub extern fn SetActiveWindow(hWnd: ?HWND) callconv(.C) HWND;

pub const SM_XVIRTUALSCREEN = 76;
pub const SM_YVIRTUALSCREEN = 77;
pub const SM_CXVIRTUALSCREEN = 78;
pub const SM_CYVIRTUALSCREEN = 79;

pub fn getRoot(hwnd: HWND) HWND {
    var root = hwnd;
    var parent: ?HWND = undefined;
    const desktop = wam.GetDesktopWindow() orelse @panic("Unable to get desktop window");

    parent = wam.GetWindow(root, wam.GW_OWNER);
    while (parent != null and desktop != parent.?) {
        root = parent.?;
        parent = wam.GetWindow(root, wam.GW_OWNER);
    }

    return root;
}

pub fn isCloaked(hwnd: HWND) bool {
    var value: i32 = undefined;
    const h_res = DwmGetWindowAttribute(hwnd, DWMA_CLOAKED, &value, @sizeOf(i32));
    if (h_res != 0) {
        value = 0;
    }
    return value != 0;
}

pub fn setHwndVisibility(hwnd: HWND, visible: bool) void {
    const i_visible = @boolToInt(visible);
    const i_hide = @boolToInt(!visible);
    _ = wam.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        wam.SET_WINDOW_POS_FLAGS.initFlags(.{
            .NOACTIVATE = 1,
            .NOMOVE = 1,
            .NOSIZE = 1,
            .NOZORDER = 1,
            .SHOWWINDOW = i_visible,
            .HIDEWINDOW = i_hide,
        }),
    );
}

pub const tray_window_string = L("Shell_TrayWnd");
