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

    /// Reads a line and removes the newline characters(\n, and \r\n for windows)
    fn read(self: Self) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();
        try self.reader.streamUntilDelimiter(buffer.writer(), '\n', null);
        if (builtin.target.os.tag == .windows and buffer.getLastOrNull() == '\r') _ = buffer.pop();
        return buffer.toOwnedSlice();
    }

    /// Parses one line to a value(only supports int or float types)
    /// Asserts there is a numeric value
    fn readValue(self: Self, comptime ReturnType: type) !ReturnType {
        const value = try read(self);
        defer self.allocator.free(value);
        return switch (@typeInfo(ReturnType)) {
            .Int => try std.fmt.parseInt(ReturnType, value, 10),
            .Float => try std.fmt.parseFloat(ReturnType, value),
            else => error.UnsupportedType,
        };
    }

    /// Reads all elements on a line, splits them by `delimiter` and parses them
    /// Asserts there is atlease 1 element
    fn readList(self: Self, comptime ReturnType: type, delimiter: u8) ![]ReturnType {
        const line = try self.read();
        defer self.allocator.free(line);
        var values = std.mem.splitScalar(u8, line, delimiter);
        var output = std.ArrayList(ReturnType).init(self.allocator);

        while (values.next()) |v| {
            try output.append(switch (@typeInfo(ReturnType)) {
                .Int => try std.fmt.parseInt(ReturnType, v, 10),
                .Float => try std.fmt.parseFloat(ReturnType, v),
                // Asserts the type is []u8
                .Pointer => blk: {
                    if (ReturnType != []const u8) return error.UnsupportedType;
                    break :blk try self.allocator.dupe(u8, v);
                },
                else => error.UnsupportedType,
            });
        }

        return try output.toOwnedSlice();
    }

    /// Reads N elements on a line, splits them by `delimiter` and parses them
    /// Asserts there is atlease 1 element
    fn readNElements(self: Self, comptime ReturnType: type, delimiter: u8, amount: u32) ![]ReturnType {
        const line = try self.read();
        defer self.allocator.free(line);
        var values = std.mem.splitScalar(u8, line, delimiter);
        var output = try std.ArrayList(ReturnType).initCapacity(self.allocator, amount);

        for (0..amount) |_| {
            const v = values.next() orelse unreachable;
            output.appendAssumeCapacity(switch (@typeInfo(ReturnType)) {
                .Int => try std.fmt.parseInt(ReturnType, v, 10),
                .Float => try std.fmt.parseFloat(ReturnType, v),
                // Asserts the type is []u8
                .Pointer => blk: {
                    if (ReturnType != []const u8) return error.UnsupportedType;
                    break :blk try self.allocator.dupe(u8, v);
                },
                else => error.UnsupportedType,
            });
        }

        return try output.toOwnedSlice();
    }

    /// Reads a complex type
    /// The shape needs to contain atleast n - 1 shapes
    /// The caller is responsible for freeing all the memory
    fn readType(self: Self, comptime ReturnType: type, shape: []const u32, delimiter: u8) !ReturnType {
        const typeInfo = @typeInfo(ReturnType);
        switch (typeInfo) {
            .Int, .Float => {
                return self.readValue(ReturnType, delimiter);
            },
            .Pointer => {
                const childType = typeInfo.Pointer.child;
                if (ReturnType == []const u8) {
                    return try self.read();
                }
                switch (@typeInfo(childType)) {
                    .Int, .Float => {
                        if (shape.len == 0) {
                            return try self.readList(childType, delimiter);
                        } else return try self.readNElements(childType, delimiter, shape[0]);
                    },
                    .Pointer, .Struct => {
                        if (childType == []const u8) {
                            return try self.read();
                        }
                        var values = try std.ArrayList(childType).initCapacity(self.allocator, shape[0]);
                        for (shape[0]) |_| {
                            values.appendAssumeCapacity(try self.readType(childType, shape[1..], delimiter));
                        }
                        return values.toOwnedSlice();
                    },
                    else => return error.UnsupportedType,
                }
            },
            .Struct => {
                const s = try self.allocator.create(ReturnType);
                inline for (typeInfo.Struct.fields) |field| {
                    @field(s, field.name) = try self.readType(field.type, shape, delimiter);
                }
                defer self.allocator.destroy(s);
                return s.*;
            },
            else => return error.UnsupportedType,
        }
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdin = std.io.getStdIn().reader();
    const lineReader = LineReader.init(allocator, stdin);

    const Matrix = struct {
        content: [][]i32,
        fun: []const u8,
    };

    const matrix = try lineReader.readType([]Matrix, &[_]u32{ 2, 5, 5 }, ' ');

    std.debug.print("Matrix: {any}", .{matrix});
}

test "LineReader" {
    const expect = std.testing.expect;

    const allocator = std.testing.allocator;
    const input = try std.fs.cwd().openFile("tests/LineReader.input", .{});

    var lineReader = LineReader.init(allocator, input.reader());
    const line = try lineReader.read();
    defer allocator.free(line);
    const numbers = try lineReader.readNElements(i32, ' ', 3);
    defer allocator.free(numbers);
    const floats = try lineReader.readList(f64, ',');
    defer allocator.free(floats);
    const strings = try lineReader.readList([]const u8, ' ');
    defer {
        for (strings) |string| {
            allocator.free(string);
        }
        allocator.free(strings);
    }
    const emptyStrings = try lineReader.readList([]const u8, ' ');
    defer {
        // Not needed: (as there is nothing to free)
        // for (emptyStrings) |string| {
        //     allocator.free(string);
        // }
        allocator.free(emptyStrings);
    }

    const Matrix = struct {
        content: [][]i32,
        fun: []const u8,
    };

    const matrix = try lineReader.readType([]Matrix, &[_]u32{ 2, 5, 5 }, ' ');
    defer {
        for (matrix) |structs| {
            for (structs.content) |row| {
                allocator.free(row);
            }
            allocator.free(structs.content);
            allocator.free(structs.fun);
        }
        allocator.free(matrix);
    }

    std.debug.print("Matrix: {any}", .{matrix});

    try expect(std.mem.eql(u8, line, "Hello world"));
    try expect(std.mem.eql(i32, numbers, &[_]i32{ 123, 456, 789 }));
    try expect(std.mem.eql(f64, floats, &[_]f64{ -2.5, 2.8, 9.7, 3.14 }));

    const expectedStrings = [_][]const u8{ "the", "new", "hello", "world" };
    for (strings, expectedStrings) |output, expected| {
        try expect(std.mem.eql(u8, output, expected));
    }

    try expect(emptyStrings.len == 1);
    try expect(std.mem.eql(u8, emptyStrings[0], &[0]u8{}));
}
