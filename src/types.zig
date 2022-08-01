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

pub fn lookupWorkspace(from: Workspace, dir: Direction) Workspace {
    const workspace_jump_table = [5][4]Workspace{
        // Direction: left            right           up               down               // Destination:
        [_]Workspace{ Workspace.west, Workspace.east, Workspace.north, Workspace.south }, // center
        [_]Workspace{ Workspace.east, Workspace.center, Workspace.north, Workspace.south }, // west
        [_]Workspace{ Workspace.center, Workspace.west, Workspace.north, Workspace.south }, // east
        [_]Workspace{ Workspace.west, Workspace.east, Workspace.south, Workspace.center }, // north
        [_]Workspace{ Workspace.west, Workspace.east, Workspace.center, Workspace.north }, // south
    };

    const i = @enumToInt(from);
    const j = @enumToInt(dir);
    return workspace_jump_table[i][j];
}
