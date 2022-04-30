const std = @import("std");
const win32 = @import("win32");
const windows = std.os.windows;
const wam = win32.ui.windows_and_messaging;
const threading = win32.system.threading;
const foundation = win32.foundation;
const HINSTANCE = foundation.HINSTANCE;
const HWND = foundation.HWND;
const WPARAM = foundation.WPARAM;
const LPARAM = foundation.LPARAM;
const LRESULT = foundation.LRESULT;

const GetMessage = wam.GetMessage;
const TranslateMessage = wam.TranslateMessage;
const DispatchMessage = wam.DispatchMessage;
const GetLastError = windows.kernel32.GetLastError;
const assert = std.debug.assert;

const TITLE = "padwm";
const WTITLE = std.unicode.utf8ToUtf16LeStringLiteral(TITLE);

fn wndProc(hwnd: HWND, msg: c_uint, wparam: WPARAM, lparam: LPARAM) callconv(.C) LRESULT {
    _ = hwnd;
    _ = msg;
    _ = wparam;
    _ = lparam;
    switch (msg) {
        else => {},
    }
    return 0;
}

fn init(h_instance: HINSTANCE) void {
    _ = wam.SetProcessDPIAware();
    // mutex is freed automatically by windows when process dies
    const mutex = threading.CreateMutexW(null, 1, WTITLE);
    assert(mutex != null);
    if (GetLastError() == windows.Win32Error.ALREADY_EXISTS) {
        @panic(TITLE ++ " is already running.");
    }

    const class_style = std.mem.zeroes(wam.WNDCLASS_STYLES);

    const win_class = wam.WNDCLASSEXW{
        .cbSize = @sizeOf(wam.WNDCLASSEXW),
        .style = class_style,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = h_instance,
        .hIcon = null,
        .hIconSm = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WTITLE,
    };

    if (wam.RegisterClassExW(&win_class) == 0) {
        @panic("Unable to register window class");
    }

    const ex_style = std.mem.zeroes(wam.WINDOW_EX_STYLE);
    const style = std.mem.zeroes(wam.WINDOW_STYLE);

    var wmhwnd = wam.CreateWindowExW(ex_style, WTITLE, WTITLE, style, 0, 0, 0, 0, wam.HWND_MESSAGE, null, h_instance, null);
    if (wmhwnd == null) {
        std.debug.print("{}\n", .{GetLastError()});
        @panic("Unable to create window");
    }
}

pub fn wWinMain(h_instance_param: windows.HINSTANCE, _: ?windows.HINSTANCE, _: [*:0]const u16, _: i32) c_int {
    const h_instance = @ptrCast(HINSTANCE, h_instance_param);
    init(h_instance);

    var msg = std.mem.zeroes(wam.MSG);
    while (GetMessage(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessage(&msg);
    }
    return 0;
}
