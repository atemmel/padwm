const std = @import("std");
const win32 = @import("win32");
const binding = @import("binding.zig");
const windows = std.os.windows;
const wam = win32.ui.windows_and_messaging;
const threading = win32.system.threading;
const foundation = win32.foundation;
const HINSTANCE = foundation.HINSTANCE;
const HWND = foundation.HWND;
const WPARAM = foundation.WPARAM;
const LPARAM = foundation.LPARAM;
const LRESULT = foundation.LRESULT;
const BOOL = foundation.BOOL;

const GetMessage = wam.GetMessage;
const TranslateMessage = wam.TranslateMessage;
const DispatchMessage = wam.DispatchMessage;
const GetLastError = windows.kernel32.GetLastError;
const assert = std.debug.assert;
const info = std.log.info;
const u16Literal = std.unicode.utf8ToUtf16LeStringLiteral;

const TITLE = "padwm";
const WTITLE = u16Literal(TITLE);

const Client = struct {
    hwnd: HWND,
    parent: HWND,
    root: HWND,
    isAlive: bool,
};

const Clients = std.ArrayList(Client);
var clients: Clients = undefined;

fn findClient(hwnd: HWND) ?*Client {
    for(clients.items) |*client| {
        if(client.hwnd == hwnd) {
            return client;
        }
    }
    return null;
}

fn shouldManage(hwnd: HWND) bool {

    if(findClient(hwnd)) |_| {
        return true;
    }

    const parent = wam.GetParent(hwnd);
    const style = wam.GetWindowLong(hwnd, wam.GWL_STYLE);
    const ex_style = wam.GetWindowLong(hwnd, wam.GWL_EXSTYLE);
    const parent_ok = parent != null and shouldManage(parent.?);
    const is_tool = (ex_style & @enumToInt(wam.WS_EX_TOOLWINDOW)) != 0;
    const is_app = (ex_style & @enumToInt(wam.WS_EX_APPWINDOW)) != 0;
    const no_activate = (ex_style & @enumToInt(wam.WS_EX_NOACTIVATE)) != 0;
    const disabled = (ex_style & @enumToInt(wam.WS_DISABLED)) != 0;

    _ = style;
    _ = is_app;
    _ = is_tool;

    if(parent_ok and findClient(parent.?) == null) {
        manage(parent.?);
    }

    if(disabled or no_activate or isCloaked(hwnd)) {
        return false;
    }

    var title_buffer: [512:0] u16 = undefined;
    _ = wam.GetWindowTextW(hwnd, &title_buffer, title_buffer.len);
    const title = &title_buffer;

    var class_buffer: [512:0] u16 = undefined;
    _ = wam.GetClassNameW(hwnd, &class_buffer, class_buffer.len);
    const class = &class_buffer;

    const ignore_title = [_][:0] const u16{
        u16Literal("Windows.UI.Core.CoreWindow"),
        u16Literal("Windows Shell Experience Host"),
        u16Literal("Microsoft Text Input Application"),
        u16Literal("Action Center"),
        u16Literal("New Notification"),
        u16Literal("Date And Time Information"),
        u16Literal("Volume Control"),
        u16Literal("Network Connections"),
        u16Literal("Cortana"),
        u16Literal("Start"),
        u16Literal("Windows Default Lock Screen"),
        u16Literal("Search"),
    };

    const ignore_class = [_][:0] const u16 {
        u16Literal("ForegroundStaging"),
        u16Literal("ApplicationManager_DesktopShellWindow"),
        u16Literal("Static"),
        u16Literal("Scrollbar"),
        u16Literal("Progman"),
    };

    for(ignore_title) |str| {
        if(std.mem.eql([:0]u16, title, str)) {
            return false;
        }
    }

    for(ignore_class) |str| {
        if(std.mem.eql([:0]u16, class, str)) {
            return false;
        }
    }

    return false;
}

fn manage(hwnd: HWND) void {
    _ = hwnd;
}

fn isCloaked(hwnd: HWND) bool {
    var value: i32 = undefined;
    const h_res = binding.DwmGetWindowAttribute(hwnd, binding.DWMA_CLOAKED, &value, @sizeOf(i32));
    if(h_res != 0) {
        value = 0;
    }
    return if(value == 0) false else true;
}

fn wndProc(hwnd: HWND, msg: c_uint, wparam: WPARAM, lparam: LPARAM) callconv(.C) LRESULT {
    switch (msg) {
        else => {
            return wam.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
    unreachable;
}

fn enumWndProc(hwnd: HWND, lparam: LPARAM) callconv(.C) BOOL {
    _ = lparam;
    if(findClient(hwnd)) |client| {
        client.isAlive = true;
    } else if(shouldManage(hwnd)) {
        manage(hwnd);
    }
    return 1;
}

fn init(h_instance: HINSTANCE, alloc: std.mem.Allocator) void {
    clients = Clients.init(alloc);
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
    info("Window created", .{});

    _ = wam.EnumWindows(enumWndProc, 0);
}

pub fn wWinMain(h_instance_param: windows.HINSTANCE, _: ?windows.HINSTANCE, _: [*:0]const u16, _: i32) c_int {
    _ = h_instance_param;
    const gpa = std.heap.GeneralPurposeAllocator(.{});
    var alloc = gpa{};
    defer std.debug.assert(alloc.deinit());
    const h_instance = @ptrCast(HINSTANCE, h_instance_param);
    init(h_instance, alloc.allocator());
    //var msg = std.mem.zeroes(wam.MSG);
    //while (GetMessage(&msg, null, 0, 0) > 0) {
    //_ = TranslateMessage(&msg);
    //_ = DispatchMessage(&msg);
    //}
    return 0;
}
