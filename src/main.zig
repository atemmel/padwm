const std = @import("std");
const win32 = @import("win32");
const binding = @import("binding.zig");
const types = @import("types.zig");
const Wm = @import("wm.zig").Wm;
const Client = @import("client.zig").Client;
const utils = @import("utils.zig");
const KeyBind = types.KeyBind;
const Workspace = types.Workspace;
const Direction = types.Direction;
const Cycle = types.Cycle;
const windows = std.os.windows;
const gdi = win32.graphics.gdi;
const wam = win32.ui.windows_and_messaging;
const kbm = win32.ui.input.keyboard_and_mouse;
const threading = win32.system.threading;
const foundation = win32.foundation;
const RECT = foundation.RECT;
const HINSTANCE = foundation.HINSTANCE;
const HWND = foundation.HWND;
const WPARAM = foundation.WPARAM;
const LPARAM = foundation.LPARAM;
const LRESULT = foundation.LRESULT;
const BOOL = foundation.BOOL;

const GetLastError = windows.kernel32.GetLastError;
const assert = std.debug.assert;
const print = std.debug.print;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const check = utils.check;
const checkLastError = utils.checkLastError;
const lookupWorkspace = types.lookupWorkspace;
const setHwndVisibility = binding.setHwndVisibility;

const TITLE = "padwm";
const WTITLE = L(TITLE);
const bar_name = L("padbar");
const modifier = kbm.HOT_KEY_MODIFIERS.ALT;

const binds = [_]KeyBind{
    // exit padwm
    KeyBind.init(kbm.VK_E, "exit", "", .{ .mod = kbm.MOD_SHIFT }),

    // change active workspace
    KeyBind.init(kbm.VK_H, "walk", "left", .{}),
    KeyBind.init(kbm.VK_L, "walk", "right", .{}),
    KeyBind.init(kbm.VK_K, "walk", "up", .{}),
    KeyBind.init(kbm.VK_J, "walk", "down", .{}),

    // cycle through clients
    KeyBind.init(kbm.VK_W, "cycle", "backwards", .{}),
    KeyBind.init(kbm.VK_E, "cycle", "forwards", .{}),

    // move client to workspace
    KeyBind.init(kbm.VK_H, "move", "left", .{ .mod = kbm.MOD_SHIFT }),
    KeyBind.init(kbm.VK_L, "move", "right", .{ .mod = kbm.MOD_SHIFT }),
    KeyBind.init(kbm.VK_K, "move", "up", .{ .mod = kbm.MOD_SHIFT }),
    KeyBind.init(kbm.VK_J, "move", "down", .{ .mod = kbm.MOD_SHIFT }),

    // toggle maximized
    KeyBind.init(kbm.VK_M, "maximize", "", .{}),
};

var wm: Wm = undefined;

fn barHandler(hwnd: HWND, msg: c_uint, wparam: WPARAM, lparam: LPARAM) callconv(.C) LRESULT {
    switch (msg) {
        wam.WM_CREATE => {
            wm.updateBar();
        },
        wam.WM_PAINT => {
            var ps = std.mem.zeroes(gdi.PAINTSTRUCT);
            _ = gdi.BeginPaint(hwnd, &ps);
            wm.drawBar();
            _ = gdi.EndPaint(hwnd, &ps);
        },
        wam.WM_LBUTTONDOWN, wam.WM_RBUTTONDOWN, wam.WM_MBUTTONDOWN => {
            print("CLICK\n", .{});
        },
        wam.WM_TIMER => {
            wm.drawBar();
            return wam.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {
            return wam.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
    return 0;
}

fn handleKey(index: usize) void {
    const bind = binds[index];
    if (std.mem.eql(u8, bind.action, "exit")) {
        print("Exiting...\n", .{});
        wm.running = false;
    } else if (std.mem.eql(u8, bind.action, "walk")) {
        if (std.meta.stringToEnum(Direction, bind.arg)) |direction| {
            const active_workspace = wm.active_workspace;
            const next_workspace = lookupWorkspace(active_workspace, direction);
            wm.changeWorkspace(next_workspace);
        }
    } else if (std.mem.eql(u8, bind.action, "move")) {
        if (std.meta.stringToEnum(Direction, bind.arg)) |direction| {
            const active_workspace = wm.active_workspace;
            const next_workspace = lookupWorkspace(active_workspace, direction);
            print("\nAsking to move client {} from {} to {}\n", .{ wm.focused_client, wm.active_workspace, next_workspace });
            wm.moveToWorkspace(next_workspace) catch |err| {
                print("Unable to move to workspace: {s}\n", .{err});
            };
        }
    } else if (std.mem.eql(u8, bind.action, "cycle")) {
        if (std.meta.stringToEnum(Cycle, bind.arg)) |cycle| {
            switch (cycle) {
                .backwards => {
                    wm.focusPrev();
                },
                .forwards => {
                    wm.focusNext();
                },
            }
        }
    } else if (std.mem.eql(u8, bind.action, "maximize")) {
        if (wm.focused_client) |idx| {
            var client = &wm.clients.items[idx];
            print("Toggling maximized for {}\n", .{idx});
            client.toggleMaximized(
                wm.desktop_x,
                wm.desktop_y,
                wm.desktop_width,
                wm.desktop_height,
            );
        }
    }
}

fn handleWindowCreated(maybe_client: ?*Client, client_hwnd: HWND) void {
    //print("Window created\n", .{});
    if (maybe_client == null and wm.shouldManage(client_hwnd)) {
        print("Managing...\n", .{});
        wm.manage(client_hwnd);
        //var n_client = clients.items[clients.items.len - 1];
        //n_client.resize(desktop_x, desktop_y, desktop_width, desktop_height);
    } else if (maybe_client != null) {
        for (wm.clients.items) |*c, i| {
            if (c == maybe_client.?) {
                wm.focus(i);
            }
        }
        //print("Did not manage!\n", .{});
    }
}

fn handleWindowDestroyed(maybe_client: ?*Client) void {
    if (maybe_client) |client| {
        if (!client.still_lives) {
            wm.unmanage(client);
        } else {
            client.still_lives = false;
        }
    }
}

fn wndProc(hwnd: HWND, msg: c_uint, wparam: WPARAM, lparam: LPARAM) callconv(.C) LRESULT {
    switch (msg) {
        wam.WM_HOTKEY => {
            if (wparam >= 0 and wparam < binds.len) {
                handleKey(wparam);
            }
        },
        else => {
            if (msg == wm.shellHookId) {
                const maybe_client_hwnd = @intToPtr(?HWND, @intCast(usize, lparam));
                if (maybe_client_hwnd == null) {
                    return 0;
                }
                const client_hwnd = maybe_client_hwnd.?;
                const maybe_client = wm.findClient(client_hwnd);
                switch (wparam & 0x7FFF) {
                    wam.HSHELL_WINDOWCREATED => {
                        handleWindowCreated(maybe_client, client_hwnd);
                    },
                    wam.HSHELL_WINDOWDESTROYED => {
                        handleWindowDestroyed(maybe_client);
                    },
                    wam.HSHELL_WINDOWACTIVATED => {
                        //TODO: this
                    },
                    else => {},
                }
            } else {
                return wam.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
        },
    }
    return 0;
}

fn enumWndProc(hwnd: HWND, _: LPARAM) callconv(.C) BOOL {
    if (wm.findClient(hwnd) == null and wm.shouldManage(hwnd)) {
        wm.manage(hwnd);
    }
    return 1;
}

fn init(h_instance: HINSTANCE) void {
    _ = wam.SetProcessDPIAware();
    // mutex is freed automatically by windows when process dies
    const mutex = threading.CreateMutexW(null, 1, WTITLE);
    assert(mutex != null);
    checkLastError(TITLE ++ " is already running");

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

    _ = wam.RegisterClassExW(&win_class);
    checkLastError("Unable to register window class");

    const ex_style = std.mem.zeroes(wam.WINDOW_EX_STYLE);
    const style = std.mem.zeroes(wam.WINDOW_STYLE);

    var maybe_wmhwnd = wam.CreateWindowExW(ex_style, WTITLE, WTITLE, style, 0, 0, 0, 0, null, null, h_instance, null);
    checkLastError("Unable to create window");
    print("Window created\n", .{});

    var wmhwnd = maybe_wmhwnd.?;

    wm.init(ally);

    // collect all active windows
    _ = wam.EnumWindows(enumWndProc, 0);
    wm.focusBottom();

    registerKeys(wmhwnd);

    check(
        wam.RegisterShellHookWindow(wmhwnd) == 1,
        "Could not RegisterShellHookWindow",
    );

    wm.shellHookId = wam.RegisterWindowMessageW(L("SHELLHOOK"));
    wm.updateGeometry();

    initBar(h_instance);

    wm.updateBar();

    wm.dumpState();
}

fn registerKeys(hwnd: HWND) void {
    for (binds) |bind, index| {
        const mod = @intToEnum(kbm.HOT_KEY_MODIFIERS, bind.extraMod | @enumToInt(modifier));
        if (kbm.RegisterHotKey(
            hwnd, // hwnd
            @intCast(i32, index), // id
            mod, // modifier(s)
            bind.key, // virtual key-code
        ) == 0) {
            @panic("Unable to register hotkey");
        }
    }
}

fn initBar(h_instance: HINSTANCE) void {
    const maybe_tray = wam.FindWindowW(binding.tray_window_string, null);
    if (maybe_tray) |tray| {
        var rect = RECT{
            .left = 0,
            .right = 0,
            .top = 0,
            .bottom = 20,
        };
        setHwndVisibility(tray, false);
        _ = wam.GetWindowRect(tray, &rect);
        wm.bar.h = rect.bottom - rect.top;
    } else {
        wm.bar.h = 20;
    }

    var win_class = std.mem.zeroes(wam.WNDCLASSEXW);

    const h_cursor = wam.LoadCursor(null, wam.IDC_ARROW);
    check(h_cursor != null, "Unable to load cursor");

    win_class.cbSize = @sizeOf(@TypeOf(win_class));
    win_class.style = std.mem.zeroes(wam.WNDCLASS_STYLES);
    win_class.lpfnWndProc = barHandler;
    win_class.cbClsExtra = 0;
    win_class.cbWndExtra = 0;
    win_class.hInstance = h_instance;
    win_class.hIcon = null;
    win_class.hCursor = h_cursor;
    win_class.hbrBackground = null;
    win_class.lpszMenuName = null;
    win_class.lpszClassName = bar_name;
    win_class.hIconSm = null;

    check(wam.RegisterClassExW(&win_class) != 0, "Unable to register class");

    const style = wam.WINDOW_STYLE.initFlags(.{
        .POPUP = 1,
        .CLIPCHILDREN = 1,
        .CLIPSIBLINGS = 1,
    });

    const maybe_hwnd = wam.CreateWindowExW(
        wam.WS_EX_TOOLWINDOW,
        bar_name,
        null,
        style,
        0,
        0,
        0,
        0,
        null,
        null,
        h_instance,
        null,
    );
    check(maybe_hwnd != null, "Unable to create window");

    wm.bar.hwnd = maybe_hwnd.?;

    //draw_context.hdc = gdi.GetWindowDC(bar.hwnd);
    //var font = @ptrCast(?gdi.HFONT, gdi.GetStockObject(.SYSTEM_FONT));
    //check(font != null, "Unable to get font");

    _ = wam.PostMessage(wm.bar.hwnd, wam.WM_PAINT, 0, 0);
    const clock_interval = 1_000;
    _ = wam.SetTimer(wm.bar.hwnd, 1, clock_interval, null);
}

var ally: std.mem.Allocator = undefined;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    wm.deinit();
    std.debug.panicImpl(error_return_trace, @returnAddress(), msg);
}

pub fn wWinMain(h_instance_param: windows.HINSTANCE, _: ?windows.HINSTANCE, _: [*:0]const u16, _: i32) c_int {
    _ = h_instance_param;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    ally = gpa.allocator();

    defer {
        wm.deinit();
        std.debug.assert(!gpa.deinit());
    }
    const h_instance = @ptrCast(HINSTANCE, h_instance_param);
    init(h_instance);
    var msg = std.mem.zeroes(wam.MSG);

    while (wm.running and wam.GetMessage(&msg, null, 0, 0) > 0) {
        _ = wam.TranslateMessage(&msg);
        _ = wam.DispatchMessage(&msg);
    }
    return @intCast(c_int, msg.wParam);
}
