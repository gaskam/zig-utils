const std = @import("std");
const builtin = @import("builtin");

const List = struct {
    size1: usize,
    int_list: []i32,
};

const String = struct {
    size2: usize,
    string_list: []const u8,
};

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
            try output.append(v);
        }

        return try output.toOwnedSlice();
    }
};

fn writeStdOutLine(line: []const u8, writer: std.fs.File.Writer) !void {
    try writer.print("{s}\n", .{line});
}

pub fn main() !void {
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // const allocator = arena.allocator();

    // const stdin = std.io.getStdIn().reader();

    // std.debug.print("Enter a number: ", .{});

    // const lineReader = LineReader.init(allocator, stdin);

    // // std.debug.print("Line read: {d}", .{try lineReader.readList(i32)});
    // std.debug.print("Result: {any}\n", .{try lineReader.readList(f128, ' ')});

    // var a: u128 = 0;
    for (0..1000000) |i| {
        var buf: [15]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{}", .{i});
        try writeStdOutLine(str, std.io.getStdOut().writer());
    }

    // std.debug.print("a: {d}\n", .{a});

    // try writeStdOutLine("Hello, World!", std.io.getStdOut().writer());

    // const n: usize = @intCast(try readStdInInt(allocator));

    // var listsList = try std.ArrayList(List).initCapacity(allocator, n);
    // for (0..n) |_| {
    //     const subListLen: usize = @intCast(try readStdInInt(allocator));

    //     var subList = try std.ArrayList(i32).initCapacity(allocator, subListLen);

    //     const line = try allocator.dupe(u8, try readStdInLine(allocator));
    //     var values = std.mem.splitScalar(u8, line, ' ');

    //     while (values.next()) |v| {
    //         const value = try std.fmt.parseInt(i32, v, 10);
    //         subList.appendAssumeCapacity(value);
    //     }
    //     listsList.appendAssumeCapacity(List{ .int_list = subList.items, .size1 = subListLen });
    // }
    // const lists = listsList.items;

    // var stringsList = try std.ArrayList(String).initCapacity(allocator, n);
    // for (0..n) |_| {
    //     const subListLen: usize = @intCast(try readStdInInt(allocator));

    //     const line = try allocator.dupe(u8, try readStdInLine(allocator));

    //     stringsList.appendAssumeCapacity(String{ .string_list = line, .size2 = subListLen });
    // }
    // const strings = stringsList.items;

    // var matricesList = try std.ArrayList(Matrix).initCapacity(allocator, n);
    // for (0..2) |_| {
    //     const subListLen: usize = @intCast(try readStdInInt(allocator));

    //     var subList = try std.ArrayList([]i32).initCapacity(allocator, subListLen);

    //     for (0..subListLen) |_| {
    //         const line = try allocator.dupe(u8, try readStdInLine(allocator));
    //         var subSubList = try std.ArrayList(i32).initCapacity(allocator, line.len);

    //         var values = std.mem.splitScalar(u8, line, ' ');

    //         while (values.next()) |v| {
    //             const buf = v;
    //             const value = try std.fmt.parseInt(i32, buf, 10);
    //             subSubList.appendAssumeCapacity(value);
    //         }
    //         subList.appendAssumeCapacity(subSubList.items);
    //     }

    //     matricesList.appendAssumeCapacity(Matrix{ .list_list = subList.items, .size3 = subListLen });
    // }
    // const matrices = matricesList.items;
}

const expect = std.testing.expect;

test "LineReader" {
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
    _ = strings;

    try expect(std.mem.eql(u8, line, "Hello world"));
    try expect(std.mem.eql(i32, numbers, &[_]i32{ 123, 456, 789 }));
    try expect(std.mem.eql(f64, floats, &[_]f64{ -2.5, 2.8, 9.7, 3.14 }));
    // try expect(std.mem.eql([]const u8, strings, &[_][]const u8{ "the", "new", "hello", "world" }));
}
