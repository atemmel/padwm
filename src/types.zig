const win32 = @import("win32");
const kbm = win32.ui.input.keyboard_and_mouse;

pub const Workspace = enum(u8) {
    center,
    west,
    east,
    north,
    south,
    _,
};

pub const Direction = enum(u8) {
    left,
    right,
    up,
    down,
    _,
};

pub const Cycle = enum(u8) {
    backwards,
    forwards,
};

pub const KeyBind = struct {
    key: u32,
    extraMod: u32,
    action: []const u8,
    arg: []const u8,

    const InitOptions = struct {
        mod: kbm.HOT_KEY_MODIFIERS = @intToEnum(kbm.HOT_KEY_MODIFIERS, 0),
    };

    pub fn init(key: kbm.VIRTUAL_KEY, action: []const u8, arg: []const u8, opt: InitOptions) KeyBind {
        return KeyBind{
            .key = @enumToInt(key),
            .extraMod = @enumToInt(opt.mod),
            .action = action,
            .arg = arg,
        };
    }
};
