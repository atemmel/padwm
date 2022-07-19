const std = @import("std");
const win32 = @import("win32");
const binding = @import("binding.zig");
const windows = std.os.windows;
const gdi = win32.graphics.gdi;
const wam = win32.ui.windows_and_messaging;
const kbm = win32.ui.input.keyboard_and_mouse;
const threading = win32.system.threading;
const foundation = win32.foundation;
const HINSTANCE = foundation.HINSTANCE;
const RECT = foundation.RECT;
const HDC = wam.HDC;
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
const print = std.debug.print;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const TITLE = "padwm";
const WTITLE = L(TITLE);

const KeyBind = struct {
    key: u32,
    extraMod: u32,
    action: []const u8,
    arg: []const u8,

    const InitOptions = struct {
        mod: kbm.HOT_KEY_MODIFIERS = @intToEnum(kbm.HOT_KEY_MODIFIERS, 0),
    };

    fn init(key: kbm.VIRTUAL_KEY, action: []const u8, arg: []const u8, opt: InitOptions) KeyBind {
        return KeyBind{
            .key = @enumToInt(key),
            .extraMod = @enumToInt(opt.mod),
            .action = action,
            .arg = arg,
        };
    }
};

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
};

const Client = struct {
    hwnd: HWND,
    parent: ?HWND,
    root: HWND,
    isAlive: bool,
    isCloaked: bool,
    workspace: Workspace,

    fn resize(self: *Client, x: i32, y: i32, w: i32, h: i32) void {
        _ = wam.SetWindowPos(self.hwnd, null, x, y, w, h, wam.SWP_NOACTIVATE);
    }

    fn setVisibility(self: *Client, visible: bool) void {
        setHwndVisibility(self.hwnd, visible);
    }
};

const Clients = std.ArrayList(Client);
var clients: Clients = undefined;
var focused_client: ?usize = null;
var running = true;
var shellHookId: u32 = 0;

var desktop_x: i32 = 0;
var desktop_y: i32 = 0;
var desktop_width: i32 = 0;
var desktop_height: i32 = 0;

const Bar = struct {
    w: i32,
    h: i32,
    hwnd: HWND,
};

const DrawContext = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hdc: ?HDC,
};

var bar: Bar = undefined;
var draw_context: DrawContext = undefined;

const Workspace = enum(u8) {
    center,
    west,
    east,
    north,
    south,
    _,
};

const Direction = enum(u8) {
    left,
    right,
    up,
    down,
    _,
};

const Cycle = enum(u8) {
    backwards,
    forwards,
};

const WorkspaceStack = std.ArrayList(usize);
var workspace_stacks: [5]WorkspaceStack = .{
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
};

var active_workspace = Workspace.center;

fn dumpState() void {
    const all_ws = [_]Workspace{ .center, .west, .east, .north, .south };
    for (all_ws) |ws| {
        const stack = workspace_stacks[@enumToInt(ws)].items;
        if (ws == active_workspace) {
            print("{{{}}} has [ ", .{ws});
        } else {
            print("{} has [ ", .{ws});
        }
        for (stack) |c| {
            if (focused_client != null and c == focused_client.?) {
                print("({}) ", .{c});
            } else {
                print("{} ", .{c});
            }
        }
        print("]\n", .{});
    }
}

fn updateGeometry() void {
    desktop_x = binding.GetSystemMetrics(binding.SM_XVIRTUALSCREEN);
    desktop_y = binding.GetSystemMetrics(binding.SM_YVIRTUALSCREEN);
    desktop_width = binding.GetSystemMetrics(binding.SM_CXVIRTUALSCREEN);
    desktop_height = binding.GetSystemMetrics(binding.SM_CYVIRTUALSCREEN);
}

fn lookupWorkspace(dir: Direction) Workspace {
    const workspace_jump_table = [5][4]Workspace{
        // Direction: left            right           up               down               // Destination:
        [_]Workspace{ Workspace.west, Workspace.east, Workspace.north, Workspace.south }, // center
        [_]Workspace{ Workspace.east, Workspace.center, Workspace.north, Workspace.south }, // west
        [_]Workspace{ Workspace.center, Workspace.west, Workspace.north, Workspace.south }, // east
        [_]Workspace{ Workspace.west, Workspace.east, Workspace.south, Workspace.center }, // north
        [_]Workspace{ Workspace.west, Workspace.east, Workspace.center, Workspace.north }, // south
    };

    const i = @enumToInt(active_workspace);
    const j = @enumToInt(dir);
    return workspace_jump_table[i][j];
}

fn changeWorkspace(ws: Workspace) void {
    for (clients.items) |*client| {
        if (client.workspace == active_workspace) {
            client.setVisibility(false);
        }
    }

    active_workspace = ws;

    for (clients.items) |*client| {
        if (client.workspace == active_workspace) {
            client.setVisibility(true);
        }
    }

    focusTop();
}

fn moveToWorkspace(ws: Workspace) !void {
    if (focused_client == null) {
        return;
    }

    const current_stack = &workspace_stacks[@enumToInt(active_workspace)];
    const target_stack = &workspace_stacks[@enumToInt(ws)];

    if (current_stack.items.len == 0) {
        print("Error: about to perform bad pop\n", .{});
        return;
    }

    const client_idx = focused_client.?;
    var client = &clients.items[client_idx];

    client.setVisibility(false);
    client.workspace = ws;

    try target_stack.append(current_stack.pop());
}

fn findClientInStack(client: usize, ws: Workspace) ?usize {
    const stack = &workspace_stacks[@enumToInt(ws)];
    for (stack.items) |client_idx, stack_idx| {
        if (client_idx == client) {
            return stack_idx;
        }
    }
    return null;
}

fn findFirstClientInWs(ws: Workspace, slice: []Client) ?usize {
    var i: usize = 0;
    while (i < slice.len) {
        const client = &slice[i];
        if (client.workspace == ws) {
            return i;
        }
    }
    return null;
}

fn findLastClientInWs(ws: Workspace, slice: []Client) ?usize {
    if (slice.len == 0) {
        return null;
    }
    var i = slice.len - 1;
    while (true) {
        const client = &slice[i];
        if (client.workspace == ws) {
            return i;
        }

        if (i == 0) {
            break;
        }
        i -= 1;
    }
    return null;
}

fn focusTop() void {
    const stack = workspace_stacks[@enumToInt(active_workspace)].items;
    if (stack.len == 0) {
        focus(null);
    } else {
        focus(stack[stack.len - 1]);
    }
}

fn focusPrev() void {
    const stack = workspace_stacks[@enumToInt(active_workspace)].items;
    if (focused_client) |client_idx| {
        const stack_idx = findClientInStack(client_idx, active_workspace);
        if (stack_idx) |idx| {
            const to_focus = stack[if (idx == 0) stack.len - 1 else idx - 1];
            focus(to_focus);
        } else {
            focus(null);
        }
    } else if (stack.len > 0) {
        focus(stack[stack.len - 1]);
    } else {
        focus(null);
    }
}

fn focusNext() void {
    const stack = workspace_stacks[@enumToInt(active_workspace)].items;
    if (focused_client) |client_idx| {
        const stack_idx = findClientInStack(client_idx, active_workspace);
        if (stack_idx) |idx| {
            const to_focus = stack[if (idx == stack.len - 1) 0 else idx + 1];
            focus(to_focus);
        } else {
            focus(null);
        }
    } else if (stack.len > 0) {
        focus(stack[stack.len - 1]);
    } else {
        focus(null);
    }
}

fn focus(client_idx: ?usize) void {
    if (client_idx == null) {
        _ = wam.SetForegroundWindow(null);
        _ = wam.BringWindowToTop(null);
        _ = binding.SetActiveWindow(null);
    } else {
        const client = &clients.items[client_idx.?];
        _ = wam.SetForegroundWindow(client.hwnd);
        _ = wam.BringWindowToTop(client.hwnd);
        _ = binding.SetActiveWindow(client.hwnd);
    }
    focused_client = client_idx;
}

fn findClient(hwnd: ?HWND) ?*Client {
    if (hwnd == null) {
        return null;
    }
    for (clients.items) |*client| {
        if (client.hwnd == hwnd.?) {
            return client;
        }
    }
    return null;
}

fn setHwndVisibility(hwnd: HWND, visible: bool) void {
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

fn shouldManage(hwnd: HWND) bool {
    if (findClient(hwnd)) |_| {
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

    if (parent_ok and findClient(parent.?) == null) {
        manage(parent.?);
    }

    const is_cloaked = isCloaked(hwnd);
    if (disabled or no_activate or is_cloaked) {
        return false;
    }

    var title_buffer: [512:0]u16 = undefined;
    const title_len = @intCast(usize, wam.GetWindowTextW(hwnd, &title_buffer, title_buffer.len));
    const title = title_buffer[0..title_len];

    var class_buffer: [512:0]u16 = undefined;
    const class_len = @intCast(usize, wam.GetClassNameW(hwnd, &class_buffer, class_buffer.len));
    const class = class_buffer[0..class_len];

    @setEvalBranchQuota(10_000);
    const ignore_title = [_][:0]const u16{
        L("Windows.UI.Core.CoreWindow"),
        L("Windows Shell Experience Host"),
        L("Microsoft Text Input Application"),
        L("Action Center"),
        L("New Notification"),
        L("Date And Time Information"),
        L("Volume Control"),
        L("Network Connections"),
        L("Cortana"),
        L("Start"),
        L("Windows Default Lock Screen"),
        L("Search"),
        L(""),
    };

    const ignore_class = [_][:0]const u16{
        L("ForegroundStaging"),
        L("ApplicationManager_DesktopShellWindow"),
        L("Static"),
        L("Scrollbar"),
        L("Progman"),
        L("tooltips_class32"),

        // Use when debugging
        //L("mintty"),
    };

    for (ignore_title) |str| {
        if (std.mem.eql(u16, title, str)) {
            //print("Not handling: {s}\n", .{std.unicode.fmtUtf16le(title)});
            return false;
        }
    }

    for (ignore_class) |str| {
        if (std.mem.eql(u16, class, str)) {
            //print("Not handling: {s}\n", .{std.unicode.fmtUtf16le(title)});
            return false;
        }
    }

    if ((parent == null and wam.IsWindowVisible(hwnd) != 0) or parent_ok) {
        if ((!is_tool and parent == null) or (is_tool and parent_ok)) {
            print("Handling: {s} {s}\n", .{ std.unicode.fmtUtf16le(title), std.unicode.fmtUtf16le(class) });
            return true;
        }
        if (is_app and parent != null) {
            print("Handling: {s} {s}\n", .{ std.unicode.fmtUtf16le(title), std.unicode.fmtUtf16le(class) });
            return true;
        }
    }

    //print("Not handling: {s}\n", .{std.unicode.fmtUtf16le(title)});
    return false;
}

fn drawBar() void {
    draw_context.hdc = wam.GetWindowDC(bar.hwnd);
    draw_context.h = bar.h;
    defer wam.ReleaseDC(bar.hwnd, draw_context.hdc);

    var x: i32 = undefined;
    draw_context.x = 0;

    var i: i32 = 0;
    _ = x;
    _ = i;

    const str = []const u16{};
    drawText(&str);
}

fn drawText(text: []const u16) void {
    _ = text;
    const r = RECT{
        .left = draw_context.x,
        .top = draw_context.y,
        .right = draw_context.x + draw_context.w,
        .bottom = draw_context.y + draw_context.h,
    };

    const border_px = 1;
    const sel_border_color = 0x00775500;
    const fg_color = 0x00eeeeee;
    const pen = gdi.CreatePen(gdi.PS_SOLID, border_px, sel_border_color);
    const brush = gdi.CreateSolidBrush(fg_color);

    defer {
        gdi.DeleteObject(pen);
        gdi.DeleteObject(brush);
    }

    wam.SelectObject(draw_context.hdc, pen);
    wam.SelectObject(draw_context.hdc, brush);

    gdi.FillRect(draw_context.hdc, &r, brush);
}

fn manage(hwnd: HWND) void {
    if (findClient(hwnd)) |_| {
        return;
    }

    var wi: wam.WINDOWINFO = undefined;
    wi.cbSize = @sizeOf(wam.WINDOWINFO);

    if (wam.GetWindowInfo(hwnd, &wi) == 0) {
        return;
    }

    var client = Client{
        .hwnd = hwnd,
        .parent = wam.GetParent(hwnd),
        .root = getRoot(hwnd),
        .isAlive = true,
        .isCloaked = isCloaked(hwnd),
        .workspace = active_workspace,
    };

    const stack = &workspace_stacks[@enumToInt(active_workspace)];
    const client_idx = clients.items.len;
    clients.append(client) catch {
        @panic("Unable to allocate memory for new client");
    };
    stack.append(client_idx) catch {
        @panic("Unable to allocate memory for stack");
    };
    focused_client = client_idx;
}

fn getRoot(hwnd: HWND) HWND {
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

fn isCloaked(hwnd: HWND) bool {
    var value: i32 = undefined;
    const h_res = binding.DwmGetWindowAttribute(hwnd, binding.DWMA_CLOAKED, &value, @sizeOf(i32));
    if (h_res != 0) {
        value = 0;
    }
    return value != 0;
}

fn wndProc(hwnd: HWND, msg: c_uint, wparam: WPARAM, lparam: LPARAM) callconv(.C) LRESULT {
    switch (msg) {
        wam.WM_HOTKEY => {
            if (wparam >= 0 and wparam < binds.len) {
                const bind = binds[wparam];
                if (std.mem.eql(u8, bind.action, "exit")) {
                    print("Exiting...\n", .{});
                    running = false;
                } else if (std.mem.eql(u8, bind.action, "walk")) {
                    if (std.meta.stringToEnum(Direction, bind.arg)) |direction| {
                        const next_workspace = lookupWorkspace(direction);
                        changeWorkspace(next_workspace);
                    }
                } else if (std.mem.eql(u8, bind.action, "move")) {
                    if (std.meta.stringToEnum(Direction, bind.arg)) |direction| {
                        const next_workspace = lookupWorkspace(direction);
                        print("\n\nAsking to move client {} from {} to {}\n\n", .{ focused_client, active_workspace, next_workspace });
                        moveToWorkspace(next_workspace) catch |err| {
                            print("Unable to move to workspace: {s}\n", .{err});
                        };
                    }
                } else if (std.mem.eql(u8, bind.action, "cycle")) {
                    if (std.meta.stringToEnum(Cycle, bind.arg)) |cycle| {
                        switch (cycle) {
                            .backwards => {
                                focusPrev();
                            },
                            .forwards => {
                                focusNext();
                            },
                        }
                    }
                }
                dumpState();
            }
        },
        else => {
            if (msg == shellHookId) {
                const client_hwnd = @intToPtr(?HWND, @intCast(usize, lparam));
                const client = findClient(client_hwnd);
                switch (wparam & 0x7FFF) {
                    wam.HSHELL_WINDOWCREATED => {
                        print("Window created\n", .{});
                        if (client == null and shouldManage(client_hwnd.?)) {
                            print("Managing...", .{});
                            manage(client_hwnd.?);
                            var n_client = clients.items[clients.items.len - 1];
                            n_client.resize(0, 0, desktop_width, desktop_height);
                        } else {
                            print("Did not manage!\n", .{});
                        }
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
    if (findClient(hwnd)) |client| {
        client.isAlive = true;
    } else if (shouldManage(hwnd)) {
        manage(hwnd);
    }
    return 1;
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
    _ = h_instance;
    var win_class = std.mem.zeroes(wam.WNDCLASSW);
    _ = win_class;
}

fn init(h_instance: HINSTANCE, alloc: std.mem.Allocator) void {
    clients = Clients.init(alloc);
    for (workspace_stacks) |*stack| {
        stack.* = WorkspaceStack.init(alloc);
    }
    _ = wam.SetProcessDPIAware();
    // mutex is freed automatically by windows when process dies
    const mutex = threading.CreateMutexW(null, 1, WTITLE);
    assert(mutex != null);
    if (GetLastError() == windows.Win32Error.ALREADY_EXISTS) {
        @panic(TITLE ++ " is already running.");
    }

    const tray = wam.FindWindowW(L("Shell_TrayWnd"), null);
    if (tray != null) {
        setHwndVisibility(tray.?, false);
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

    var opt_wmhwnd = wam.CreateWindowExW(ex_style, WTITLE, WTITLE, style, 0, 0, 0, 0, wam.HWND_MESSAGE, null, h_instance, null);
    if (opt_wmhwnd == null) {
        std.debug.print("{}\n", .{GetLastError()});
        @panic("Unable to create window");
    }
    info("Window created", .{});

    var wmhwnd = opt_wmhwnd.?;

    _ = wam.EnumWindows(enumWndProc, 0);

    registerKeys(wmhwnd);

    if (wam.RegisterShellHookWindow(wmhwnd) == 0) {
        @panic("Could not RegisterShellHookWindow");
    }

    shellHookId = wam.RegisterWindowMessageW(L("SHELLHOOK"));
    updateGeometry();
}

fn deinit() void {
    defer {
        clients.deinit();
        for (workspace_stacks) |*stack| {
            stack.deinit();
        }
    }

    const tray = wam.FindWindowW(L("Shell_TrayWnd"), null);
    if (tray != null) {
        setHwndVisibility(tray.?, true);
    }
    for (clients.items) |*client| {
        client.setVisibility(true);
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    deinit();
    std.debug.panicImpl(error_return_trace, @returnAddress(), msg);
}

pub fn wWinMain(h_instance_param: windows.HINSTANCE, _: ?windows.HINSTANCE, _: [*:0]const u16, _: i32) c_int {
    _ = h_instance_param;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        deinit();
        std.debug.assert(!gpa.deinit());
    }
    const h_instance = @ptrCast(HINSTANCE, h_instance_param);
    init(h_instance, gpa.allocator());
    var msg = std.mem.zeroes(wam.MSG);
    while (running and GetMessage(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessage(&msg);
    }
    return @intCast(c_int, msg.wParam);
}
