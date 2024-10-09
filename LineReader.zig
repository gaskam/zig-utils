const std = @import("std");
const builtin = @import("builtin");

const LineReader = struct {
    line: []const u8,
    allocator: std.mem.Allocator,
    reader: std.fs.File.Reader,
    const Self = @This();
    fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader) Self {
        return .{ .allocator = allocator, .reader = reader, .line = "" };
    }

    fn read(self: Self) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();
        try self.reader.streamUntilDelimiter(buffer.writer(), '\n', null);
        if (builtin.target.os.tag == .windows and buffer.getLast() == '\r') _ = buffer.pop();
        return buffer.toOwnedSlice();
    }

    fn readValue(self: Self, comptime ReturnType: type) !ReturnType {
        const value = try read(self);
        defer self.allocator.free(value);
        return switch (@typeInfo(ReturnType)) {
            .Int => try std.fmt.parseInt(ReturnType, value, 10),
            .Float => try std.fmt.parseFloat(ReturnType, value),
            else => error.UnsupportedType,
        };
    }

    fn readList(self: Self, comptime ReturnType: type, delimiter: u8) ![]ReturnType {
        const line = try self.read();
        defer self.allocator.free(line);
        var values = std.mem.splitScalar(u8, line, delimiter);
        var output = std.ArrayList(ReturnType).init(self.allocator);

        while (values.next()) |v| {
            try output.append(switch (@typeInfo(ReturnType)) {
                .Int => try std.fmt.parseInt(ReturnType, v, 10),
                .Float => try std.fmt.parseFloat(ReturnType, v),
                else => error.UnsupportedType,
            });
        }

        return try output.toOwnedSlice();
    }

    fn readStrings(self: Self, delimiter: u8) ![][]const u8 {
        const line = try self.read();
        defer self.allocator.free(line);
        var values = std.mem.splitScalar(u8, line, delimiter);

        var output = std.ArrayList([]const u8).init(self.allocator);

        while (values.next()) |v| {
            try output.append(try self.allocator.dupe(u8, v));
        }

        return try output.toOwnedSlice();
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdin = std.io.getStdIn().reader();

    std.debug.print("Enter some numbers: ", .{});

    const lineReader = LineReader.init(allocator, stdin);

    std.debug.print("Result: {any}\n", .{try lineReader.readList(f128, ' ')});
}

test "LineReader" {
    const expect = std.testing.expect;

    const allocator = std.testing.allocator;
    const input = try std.fs.cwd().openFile("tests/LineReader.input", .{});

    var lineReader = LineReader.init(allocator, input.reader());
    const line = try lineReader.read();
    defer allocator.free(line);
    const numbers = try lineReader.readList(i32, ' ');
    defer allocator.free(numbers);
    const floats = try lineReader.readList(f64, ',');
    defer allocator.free(floats);
    const strings = try lineReader.readStrings(' ');
    defer {
        for (strings) |string| {
            allocator.free(string);
        }
        allocator.free(strings);
    }

    try expect(std.mem.eql(u8, line, "Hello world"));
    try expect(std.mem.eql(i32, numbers, &[_]i32{ 123, 456, 789 }));
    try expect(std.mem.eql(f64, floats, &[_]f64{ -2.5, 2.8, 9.7, 3.14 }));

    const expectedStrings = [_][]const u8{ "the", "new", "hello", "world" };
    for (strings, expectedStrings) |output, expected| {
        try expect(std.mem.eql(u8, output, expected));
    }
}
