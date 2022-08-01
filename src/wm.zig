const std = @import("std");
const win32 = @import("win32");
const binding = @import("binding.zig");
const Client = @import("client.zig").Client;
const types = @import("types.zig");
const utils = @import("utils.zig");
const Workspace = types.Workspace;
const Direction = types.Direction;
const Cycle = types.Cycle;
const gdi = win32.graphics.gdi;
const wam = win32.ui.windows_and_messaging;
const foundation = win32.foundation;
const RECT = foundation.RECT;
const HDC = gdi.HDC;
const HWND = foundation.HWND;

const print = std.debug.print;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const isCloaked = binding.isCloaked;
const getRoot = binding.getRoot;
const check = utils.check;
const checkLastError = utils.checkLastError;
const setHwndVisibility = binding.setHwndVisibility;

const Bar = struct {
    x: i32,
    y: i32,
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

pub const Wm = struct {
    const Clients = std.ArrayList(Client);
    const WorkspaceStack = std.ArrayList(usize);
    clients: Clients = undefined,
    focused_client: ?usize = null,
    running: bool = true,
    shellHookId: u32 = 0,

    desktop_x: i32 = 0,
    desktop_y: i32 = 0,
    desktop_width: i32 = 0,
    desktop_height: i32 = 0,

    bar: Bar = undefined,
    draw_context: DrawContext = undefined,

    ally: std.mem.Allocator = undefined,

    workspace_stacks: [5]WorkspaceStack = .{
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
    },

    active_workspace: Workspace = Workspace.center,

    pub fn init(ally: std.mem.Allocator) Wm {
        var wm: Wm = .{};
        wm.ally = ally;
        wm.clients = Clients.init(ally);
        wm.running = true;

        for (wm.workspace_stacks) |*stack| {
            stack.* = WorkspaceStack.init(ally);
        }
        return wm;
    }

    pub fn deinit(self: *Wm) void {
        defer {
            self.clients.deinit();
            for (self.workspace_stacks) |*stack| {
                stack.deinit();
            }
        }

        const tray = wam.FindWindowW(L("Shell_TrayWnd"), null);
        if (tray != null) {
            setHwndVisibility(tray.?, true);
        }
        for (self.clients.items) |*client| {
            client.setVisibility(true);
            client.allowMinimize();
        }
    }

    pub fn dumpState(self: *const Wm) void {
        var buffer: [512:0]u16 = undefined;
        const all_ws = [_]Workspace{ .center, .west, .east, .north, .south };
        for (all_ws) |ws| {
            const stack = self.workspace_stacks[@enumToInt(ws)].items;
            if (ws == self.active_workspace) {
                print("{{{}}} has [ ", .{ws});
            } else {
                print("{} has [ ", .{ws});
            }
            for (stack) |c| {
                const client = &self.clients.items[c];
                const title_u16 = writeTitleToBuffer(client, &buffer);
                const title = std.unicode.utf16leToUtf8Alloc(self.ally, title_u16) catch {
                    @panic("Unable to allocate memory!");
                };
                defer self.ally.free(title);
                if (self.focused_client != null and c == self.focused_client.?) {
                    print("(\"{s}\") ", .{title});
                } else {
                    print("\"{s}\" ", .{title});
                }
            }
            print("]\n", .{});
        }
    }

    pub fn updateGeometry(self: *Wm) void {
        self.desktop_x = binding.GetSystemMetrics(binding.SM_XVIRTUALSCREEN);
        self.desktop_y = binding.GetSystemMetrics(binding.SM_YVIRTUALSCREEN);
        self.desktop_width = binding.GetSystemMetrics(binding.SM_CXVIRTUALSCREEN);
        self.desktop_height = binding.GetSystemMetrics(binding.SM_CYVIRTUALSCREEN);

        self.desktop_y = self.desktop_y + self.bar.h;
        self.desktop_height = self.desktop_height - self.bar.h;
        self.bar.y = self.desktop_y - self.bar.h;
        print("updateGeometry: {}\n", .{self.bar});
        print("d_x: {} d_y: {} d_w: {} d_h: {}\n", .{ self.desktop_x, self.desktop_y, self.desktop_width, self.desktop_height });
    }

    pub fn changeWorkspace(self: *Wm, ws: Workspace) void {
        defer {
            self.dumpState();
        }
        for (self.clients.items) |*client| {
            if (client.workspace == self.active_workspace) {
                client.setVisibility(false);
            }
        }

        self.active_workspace = ws;

        for (self.clients.items) |*client| {
            if (client.workspace == self.active_workspace) {
                client.setVisibility(true);
            }
        }

        self.focusTop();
    }

    pub fn moveToWorkspace(self: *Wm, ws: Workspace) !void {
        defer {
            self.dumpState();
        }

        if (self.focused_client == null) {
            return;
        }

        const current_stack = &self.workspace_stacks[@enumToInt(self.active_workspace)];
        const target_stack = &self.workspace_stacks[@enumToInt(ws)];

        if (current_stack.items.len == 0) {
            print("Error: about to perform bad pop\n", .{});
            return;
        }

        const client_idx = self.focused_client.?;
        const maybe_stack_idx = self.findClientInStack(client_idx, self.active_workspace);

        if (maybe_stack_idx == null) {
            print("Error: attempting to move client which does not belong\n", .{});
            return;
        }

        self.focusNext();

        const stack_idx = maybe_stack_idx.?;
        var client = &self.clients.items[client_idx];

        client.setVisibility(false);
        client.workspace = ws;

        try target_stack.append(current_stack.orderedRemove(stack_idx));
    }

    pub fn findClientInStack(self: *Wm, client: usize, ws: Workspace) ?usize {
        const stack = &self.workspace_stacks[@enumToInt(ws)];
        for (stack.items) |client_idx, stack_idx| {
            if (client_idx == client) {
                return stack_idx;
            }
        }
        return null;
    }

    pub fn prepareFocusCloseClient(self: *Wm) void {
        if (self.focused_client == null) {
            return;
        }

        const stack = self.workspace_stacks[@enumToInt(self.active_workspace)].items;
        var maybe_stack_idx: ?usize = 0;
        for (stack) |i, j| {
            if (i == self.focused_client.?) {
                maybe_stack_idx = j;
                break;
            }
        }
        if (maybe_stack_idx == null) {
            self.focused_client = null;
            return;
        }

        const stack_idx = maybe_stack_idx.?;
        if (stack_idx > 0) {
            self.focused_client = stack[stack_idx - 1];
        } else {
            self.focused_client = stack[0];
        }
    }

    pub fn focusTop(self: *Wm) void {
        const stack = self.workspace_stacks[@enumToInt(self.active_workspace)].items;
        if (stack.len == 0) {
            self.focus(null);
        } else {
            self.focus(stack[stack.len - 1]);
        }
    }

    pub fn focusBottom(self: *Wm) void {
        const stack = self.workspace_stacks[@enumToInt(self.active_workspace)].items;
        if (stack.len == 0) {
            self.focus(null);
        } else {
            self.focus(stack[0]);
        }
    }

    pub fn focusPrev(self: *Wm) void {
        const stack = self.workspace_stacks[@enumToInt(self.active_workspace)].items;
        if (self.focused_client) |client_idx| {
            const stack_idx = self.findClientInStack(client_idx, self.active_workspace);
            if (stack_idx) |idx| {
                const to_focus = stack[if (idx == 0) stack.len - 1 else idx - 1];
                self.focus(to_focus);
            } else {
                self.focus(null);
            }
        } else if (stack.len > 0) {
            self.focus(stack[stack.len - 1]);
        } else {
            self.focus(null);
        }
    }

    pub fn focusNext(self: *Wm) void {
        const stack = self.workspace_stacks[@enumToInt(self.active_workspace)].items;
        if (self.focused_client) |client_idx| {
            const stack_idx = self.findClientInStack(client_idx, self.active_workspace);
            if (stack_idx) |idx| {
                const to_focus = stack[if (idx >= stack.len - 1) 0 else idx + 1];
                self.focus(to_focus);
            } else {
                self.focus(null);
            }
        } else if (stack.len > 0) {
            self.focus(stack[stack.len - 1]);
        } else {
            self.focus(null);
        }
    }

    pub fn focus(self: *Wm, client_idx: ?usize) void {
        print("Focusing: {}\n", .{client_idx});
        if (client_idx == null) {
            _ = wam.SetForegroundWindow(null);
            _ = wam.BringWindowToTop(null);
            _ = binding.SetActiveWindow(null);
        } else {
            const client = &self.clients.items[client_idx.?];
            _ = wam.SetForegroundWindow(client.hwnd);
            _ = wam.BringWindowToTop(client.hwnd);
            _ = binding.SetActiveWindow(client.hwnd);
        }
        self.focused_client = client_idx;
        self.drawBar();
    }

    pub fn findClient(self: *Wm, hwnd: ?HWND) ?*Client {
        if (hwnd == null) {
            return null;
        }
        for (self.clients.items) |*client| {
            if (client.hwnd == hwnd.?) {
                return client;
            }
        }
        return null;
    }

    pub fn shouldManage(self: *Wm, hwnd: HWND) bool {
        if (self.findClient(hwnd)) |_| {
            return true;
        }

        const parent = wam.GetParent(hwnd);
        const style = wam.GetWindowLong(hwnd, wam.GWL_STYLE);
        const ex_style = wam.GetWindowLong(hwnd, wam.GWL_EXSTYLE);
        const parent_ok = parent != null and self.shouldManage(parent.?);
        const is_tool = (ex_style & @enumToInt(wam.WS_EX_TOOLWINDOW)) != 0;
        const is_app = (ex_style & @enumToInt(wam.WS_EX_APPWINDOW)) != 0;
        const no_activate = (ex_style & @enumToInt(wam.WS_EX_NOACTIVATE)) != 0;
        const disabled = (ex_style & @enumToInt(wam.WS_DISABLED)) != 0;

        _ = style;
        _ = is_app;
        _ = is_tool;

        if (parent_ok and self.findClient(parent.?) == null) {
            self.manage(parent.?);
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

        if (@import("builtin").mode == .Debug) {
            const ignore_class_debug = [_][:0]const u16{
                L("mintty"),
            };
            for (ignore_class_debug) |str| {
                if (std.mem.eql(u16, class, str)) {
                    return false;
                }
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

    pub fn updateBar(self: *Wm) void {
        const flags = wam.SET_WINDOW_POS_FLAGS.initFlags(.{
            .SHOWWINDOW = 1,
            .NOACTIVATE = 1,
            .NOSENDCHANGING = 1,
        });
        const x = 0;
        const bar = &self.bar;
        _ = wam.SetWindowPos(
            bar.hwnd,
            wam.HWND_TOPMOST,
            x,
            bar.y,
            self.desktop_width,
            bar.h,
            flags,
        );
    }

    pub fn drawBar(self: *Wm) void {
        print("Drawing bar...\n", .{});
        const bar = &self.bar;
        self.draw_context.hdc = gdi.GetWindowDC(bar.hwnd);
        defer _ = gdi.ReleaseDC(bar.hwnd, self.draw_context.hdc);
        self.draw_context.x = 0;
        self.draw_context.y = 0;
        self.draw_context.w = self.desktop_width;
        self.draw_context.h = bar.h;

        var title_buffer: [512:0]u16 = undefined;

        // draw focus
        if (self.focused_client) |idx| {
            const client = &self.clients.items[idx];
            const title_len = @intCast(usize, wam.GetWindowTextW(client.hwnd, &title_buffer, title_buffer.len));
            const title = title_buffer[0..title_len :0];
            self.drawText(title);
        } else {
            const title = L("no window focused\x00");
            self.drawText(title);
        }

        self.draw_context.x = self.desktop_width - 300;
        self.draw_context.y = 0;
        self.draw_context.w = 300;
        self.draw_context.h = bar.h;

        const time = std.time.timestamp();
        const epoch_seconds = std.time.epoch.EpochSeconds{
            .secs = @intCast(u64, time),
        };
        const day_seconds = epoch_seconds.getDaySeconds();
        const hour = day_seconds.getHoursIntoDay();
        const minute = day_seconds.getMinutesIntoHour();
        const second = day_seconds.getSecondsIntoMinute();

        const time_u8 = std.fmt.allocPrint(self.ally, "{:0>2}:{:0>2}:{:0>2}\x00", .{
            hour,
            minute,
            second,
        }) catch {
            return;
        };
        defer self.ally.free(time_u8);
        const time_u16 = std.unicode.utf8ToUtf16LeWithNull(self.ally, time_u8) catch {
            return;
        };
        defer self.ally.free(time_u16);
        self.drawText(time_u16);
    }

    pub fn getStack(self: *Wm, ws: Workspace) *WorkspaceStack {
        return &self.workspace_stacks[@enumToInt(ws)];
    }

    fn writeTitleToBuffer(client: *const Client, buffer: [:0]u16) [:0]u16 {
        const hwnd = client.hwnd;
        const buffer_len = @intCast(i32, buffer.len);
        const title_len = @intCast(usize, wam.GetWindowTextW(hwnd, buffer, buffer_len));
        return buffer[0..title_len :0];
    }

    pub fn drawText(self: *Wm, text: [:0]const u16) void {
        const draw_context = &self.draw_context;
        var r = RECT{
            .left = draw_context.x,
            .top = draw_context.y,
            .right = draw_context.x + draw_context.w,
            .bottom = draw_context.y + draw_context.h,
        };

        const border_px = 1;
        const sel_fg_color = 0x00eeeeee;
        const sel_border_color = 0x00775500;
        const fg_color = 0x00ee0088;
        const pen = gdi.CreatePen(gdi.PS_SOLID, border_px, sel_border_color);
        check(pen != null, "Could not create pen");
        defer _ = gdi.DeleteObject(pen);
        const brush = gdi.CreateSolidBrush(fg_color);
        check(brush != null, "Could not create brush");
        defer _ = gdi.DeleteObject(brush);

        check(gdi.SelectObject(draw_context.hdc, pen) != null, "Could not select pen");
        check(gdi.SelectObject(draw_context.hdc, brush) != null, "Could not select brush");
        check(gdi.FillRect(draw_context.hdc, &r, brush) != 0, "Could not draw rect");

        _ = gdi.SetTextColor(draw_context.hdc, sel_fg_color);
        _ = gdi.SetBkMode(draw_context.hdc, .TRANSPARENT);

        var maybe_font = @ptrCast(?gdi.HFONT, gdi.GetStockObject(.SYSTEM_FONT));
        check(maybe_font != null, "Unable to get font");
        var font = maybe_font.?;
        _ = gdi.SelectObject(draw_context.hdc, font);
        var fmt = gdi.DRAW_TEXT_FORMAT.initFlags(.{
            .CENTER = 1,
            .VCENTER = 1,
            .SINGLELINE = 1,
        });
        _ = gdi.DrawTextW(draw_context.hdc, text, @intCast(i32, text.len), &r, fmt);
    }

    pub fn addClient(self: *Wm, client: Client) void {
        const stack = &self.workspace_stacks[@enumToInt(self.active_workspace)];
        const client_idx = self.clients.items.len;
        self.clients.append(client) catch {
            @panic("Unable to allocate memory for new client");
        };
        stack.append(client_idx) catch {
            @panic("Unable to allocate memory for stack");
        };
    }

    pub fn manage(self: *Wm, hwnd: HWND) void {
        if (self.findClient(hwnd)) |_| {
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
            .isCloaked = isCloaked(hwnd),
            .workspace = self.active_workspace,
        };

        const client_idx = self.clients.items.len;
        self.addClient(client);

        client.disallowMinimize();
        client.restore();
        self.focus(client_idx);
    }

    pub fn unmanage(self: *Wm, client: *Client) void {
        var maybe_client_idx: ?usize = null;
        for (self.clients.items) |*c, idx| {
            if (c.hwnd == client.hwnd) {
                maybe_client_idx = idx;
            }
        }

        if (maybe_client_idx == null) {
            return;
        }

        var buffer: [512:0]u16 = undefined;
        const client_idx = maybe_client_idx.?;
        const title_u16 = writeTitleToBuffer(client, &buffer);
        const title = std.unicode.utf16leToUtf8Alloc(self.ally, title_u16) catch {
            @panic("Unable to allocate memory!");
        };
        defer self.ally.free(title);
        print("Unmanaging {} {s}\n", .{ client_idx, title });

        var stack = &self.workspace_stacks[@enumToInt(self.active_workspace)];
        var stack_idx: usize = 0;
        for (stack.items) |c_idx, s_idx| {
            if (c_idx == client_idx) {
                stack_idx = s_idx;
            }
        }

        // very cheap fix, probably bad
        for (stack.items) |*s| {
            if (s.* > client_idx) {
                s.* -= 1;
            }
        }

        self.prepareFocusCloseClient();
        //focused_client = null;
        _ = stack.orderedRemove(stack_idx);
        _ = self.clients.orderedRemove(client_idx);
        if (self.focused_client != null and self.focused_client.? >= client_idx and self.focused_client.? != 0) {
            self.focused_client.? -= 1;
        }
        self.dumpState();
        self.focus(self.focused_client);
    }
};

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const test_clients = [_]Client{
    .{ .hwnd = @intToPtr(HWND, 1), .parent = @intToPtr(HWND, 1), .root = @intToPtr(HWND, 1), .isCloaked = false, .workspace = .center },
    .{ .hwnd = @intToPtr(HWND, 2), .parent = @intToPtr(HWND, 2), .root = @intToPtr(HWND, 1), .isCloaked = false, .workspace = .center },
    .{ .hwnd = @intToPtr(HWND, 3), .parent = @intToPtr(HWND, 3), .root = @intToPtr(HWND, 1), .isCloaked = false, .workspace = .center },
};

test "wm add clients" {
    var ally = std.testing.allocator;
    var wm = Wm.init(ally);
    defer wm.deinit();

    for (test_clients) |*client| {
        wm.addClient(client.*);
    }

    const stack = wm.getStack(.center);
    try expectEqualSlices(usize, stack.items, &[_]usize{ 0, 1, 2 });
}
