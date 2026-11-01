const std = @import("std");
const vt = @import("ghostty-vt");

const boundaries = [_]u21{ 0, ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };
const scroll_interval_ms = 30;

pub const State = struct {
    gesture: vt.SelectionGesture = .init,
    pointer: ?vt.SelectionGesture.AutoscrollTick = null,
    deadline: ?i64 = null,

    pub fn deinit(self: *State, term: *vt.Terminal) void {
        self.gesture.deinit(term);
    }

    pub fn cancel(self: *State, term: *vt.Terminal) void {
        self.gesture.reset(term);
        self.pointer = null;
        self.deadline = null;
    }

    fn position(term: *vt.Terminal, x: i32, y: i32) vt.SelectionGesture.AutoscrollTick {
        // 鼠标报告字符坐标，转换为格子中心位置供 Ghostty 计算选择边界。
        return .{
            .viewport = .{ .x = @intCast(std.math.clamp(x, 0, term.cols - 1)), .y = @intCast(std.math.clamp(y, 0, term.rows - 1)) },
            .xpos = @as(f64, @floatFromInt(x)) * 10 + 5,
            .ypos = @as(f64, @floatFromInt(y)) * 10 + 5,
            .rectangle = false,
            .word_boundary_codepoints = &boundaries,
            .geometry = .{ .columns = term.cols, .cell_width = 10, .padding_left = 0, .screen_height = @as(u32, term.rows) * 10 },
        };
    }

    pub fn press(self: *State, term: *vt.Terminal, io: std.Io, x: i32, y: i32) !void {
        self.pointer = null;
        self.deadline = null;
        const p = position(term, x, y);
        const pin = term.screens.active.pages.pin(.{ .viewport = p.viewport }).?;
        try term.screens.active.select(try self.gesture.press(term, .{
            .time = .now(io, .awake),
            .pin = pin,
            .xpos = p.xpos,
            .ypos = p.ypos,
            .max_distance = 10,
            .repeat_interval = 400 * std.time.ns_per_ms,
            .word_boundary_codepoints = &boundaries,
        }));
    }

    pub fn move(self: *State, term: *vt.Terminal, x: i32, y: i32, now: i64) !void {
        const p = position(term, x, y);
        self.pointer = p;
        const pin = term.screens.active.pages.pin(.{ .viewport = p.viewport }).?;
        if (self.gesture.drag(term, .{ .pin = pin, .xpos = p.xpos, .ypos = p.ypos, .rectangle = p.rectangle, .word_boundary_codepoints = p.word_boundary_codepoints, .geometry = p.geometry })) |sel| {
            try term.screens.active.select(sel);
        }
        self.deadline = if (self.gesture.left_drag_autoscroll == .none) null else self.deadline orelse now + scroll_interval_ms;
    }

    pub fn release(self: *State, term: *vt.Terminal, x: i32, y: i32, now: i64) !bool {
        try self.move(term, x, y, now);
        const valid = self.gesture.validatedLeftClickPin(&term.screens) != null;
        self.gesture.release(term, .{ .pin = term.screens.active.pages.pin(.{ .viewport = position(term, x, y).viewport }) });
        self.pointer = null;
        self.deadline = null;
        return valid;
    }

    pub fn tick(self: *State, term: *vt.Terminal, now: i64) !void {
        const until = self.deadline orelse return;
        if (now < until) return;
        if (self.gesture.autoscrollTick(term, self.pointer.?)) |sel| try term.screens.active.select(sel);
        self.deadline = if (self.gesture.left_drag_autoscroll == .none) null else now + scroll_interval_ms;
    }
};
