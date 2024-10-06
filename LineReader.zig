const std = @import("std");

const LineReader = struct{
    line: []const u8,
    allocator: std.mem.Allocator,
    fn init(allocator: std.mem.Allocator, reader) Self {
        return .{
            ...
        }
    }
}

pub fn main() !void { }