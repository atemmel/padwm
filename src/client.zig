const std = @import("std");
const win32 = @import("win32");
const Workspace = @import("types.zig").Workspace;
const gdi = win32.graphics.gdi;
const wam = win32.ui.windows_and_messaging;
const foundation = win32.foundation;
const HWND = foundation.HWND;
const RECT = foundation.RECT;

pub const Client = struct {
    hwnd: HWND,
    parent: ?HWND,
    root: HWND,
    isCloaked: bool,
    workspace: Workspace,
    old_x: i32 = 0,
    old_y: i32 = 0,
    old_w: i32 = 0,
    old_h: i32 = 0,
    floating: bool = false,
    still_lives: bool = false,

    pub fn resize(self: *Client, x: i32, y: i32, w: i32, h: i32) void {
        var rect = std.mem.zeroes(RECT);
        _ = wam.GetWindowRect(self.hwnd, &rect);
        self.old_x = rect.left;
        self.old_y = rect.top;
        self.old_w = rect.right - rect.left;
        self.old_h = rect.bottom - rect.top;
        self.resizeKeepingCoords(x, y, w, h);
    }

    pub fn resizeKeepingCoords(self: *Client, x: i32, y: i32, w: i32, h: i32) void {
        _ = wam.SetWindowPos(self.hwnd, null, x, y, w, h, wam.SWP_NOACTIVATE);
    }

    pub fn disallowMinimize(self: *const Client) void {
        const long_styles = wam.GetWindowLongW(self.hwnd, wam.GWL_STYLE) & ~@intCast(i32, @enumToInt(wam.WS_MINIMIZEBOX));
        _ = wam.SetWindowLongW(self.hwnd, wam.GWL_STYLE, long_styles);
    }

    pub fn allowMinimize(self: *Client) void {
        const long_styles = wam.GetWindowLongW(self.hwnd, wam.GWL_STYLE) | @intCast(i32, @enumToInt(wam.WS_MINIMIZEBOX));
        _ = wam.SetWindowLongW(self.hwnd, wam.GWL_STYLE, long_styles);
    }

    pub fn restore(self: *Client) void {
        const placement = self.getPlacement();
        const flag = switch (placement.showCmd) {
            wam.SW_SHOWMAXIMIZED => wam.SW_SHOWMAXIMIZED,
            wam.SW_SHOWMINIMIZED => wam.SW_RESTORE,
            else => wam.SW_NORMAL,
        };
        self.setWindowFlag(flag);
    }

    pub fn maximize(self: *Client, x: i32, y: i32, w: i32, h: i32) void {
        // must set window state before setting flag
        self.resize(x, y, w, h);
        self.setWindowFlag(wam.SW_SHOWMAXIMIZED);
    }

    pub fn unMaximize(self: *Client) void {
        // must set normal before resetting window state
        self.setWindowFlag(wam.SW_NORMAL);
        self.resize(self.old_x, self.old_y, self.old_w, self.old_h);
    }

    fn setWindowFlag(self: *Client, flag: wam.SHOW_WINDOW_CMD) void {
        const hwnd = self.hwnd;
        _ = wam.ShowWindow(hwnd, flag);
    }

    fn getPlacement(self: *Client) wam.WINDOWPLACEMENT {
        const hwnd = self.hwnd;
        var placement = std.mem.zeroes(wam.WINDOWPLACEMENT);
        placement.length = @sizeOf(@TypeOf(placement));
        _ = wam.GetWindowPlacement(hwnd, &placement);
        return placement;
    }

    pub fn toggleMaximized(self: *Client, x: i32, y: i32, w: i32, h: i32) void {
        if (self.floating) {
            self.maximize(x, y, w, h);
        } else {
            self.unMaximize();
        }
        self.floating = !self.floating;
    }

    pub fn setVisibility(self: *Client, visible: bool) void {
        // this sends HSHELL_WINDOWDESTROYED for some reason
        setHwndVisibility(self.hwnd, visible);
        if (!visible) {
            // make a note that we only meant to hide it
            self.still_lives = true;
        }
    }
};

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
