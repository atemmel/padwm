const std = @import("std");
const windows = std.os.windows;
const GetLastError = windows.kernel32.GetLastError;
const print = std.debug.print;

pub fn checkLastError(msg: []const u8) void {
    const err = GetLastError();
    if (err != .SUCCESS) {
        print("error code: {}\n", .{err});
        @panic(msg);
    }
}

pub fn check(expr: bool, msg: []const u8) void {
    if (!expr) {
        @panic(msg);
    }
}
