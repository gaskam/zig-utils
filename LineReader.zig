const std = @import("std");
const builtin = @import("builtin");

const LineReader = struct {
    allocator: std.mem.Allocator,
    reader: std.fs.File.Reader,
    const Self = @This();

    fn init(allocator: std.mem.Allocator, reader: std.fs.File.Reader) Self {
        return .{ .allocator = allocator, .reader = reader };
    }

    /// Reads a line and removes the newline characters(\n, and \r\n for windows)
    fn read(self: Self) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();
        try self.reader.streamUntilDelimiter(buffer.writer(), '\n', null);
        if (builtin.target.os.tag == .windows and buffer.getLastOrNull() == '\r') _ = buffer.pop();
        return buffer.toOwnedSlice();
    }

    /// Parses a level 1 type
    /// Only accepts Int, Float and string([]const u8) types
    fn parseType(self: Self, comptime ReturnType: type, buf: []const u8) !ReturnType {
        return switch (@typeInfo(ReturnType)) {
            .Int => std.fmt.parseInt(ReturnType, buf, 10),
            .Float => std.fmt.parseFloat(ReturnType, buf),
            // Asserts the type is []const u8
            .Pointer => blk: {
                if (ReturnType != []const u8) return error.UnsupportedType;
                break :blk self.allocator.dupe(u8, buf);
            },
            else => error.UnsupportedType,
        };
    }

    /// Parses one line to a value(only supports int or float types)
    /// Asserts there is a numeric value
    fn readValue(self: Self, comptime ReturnType: type) !ReturnType {
        const value = try read(self);
        defer self.allocator.free(value);
        return self.parseType(ReturnType, value);
    }

    /// Reads all elements on a line, splits them by `delimiter` and parses them
    /// Asserts there is atlease 1 element
    fn readList(self: Self, comptime ReturnType: type, delimiter: u8) ![]ReturnType {
        const line = try self.read();
        defer self.allocator.free(line);
        var values = std.mem.splitScalar(u8, line, delimiter);
        var output = std.ArrayList(ReturnType).init(self.allocator);

        while (values.next()) |v| {
            try output.append(try self.parseType(ReturnType, v));
        }

        return try output.toOwnedSlice();
    }

    /// Reads N elements on a line, splits them by `delimiter` and parses them
    /// Asserts there is atlease 1 element
    fn readNElements(self: Self, comptime ReturnType: type, delimiter: u8, amount: usize) ![]ReturnType {
        const line = try self.read();
        defer self.allocator.free(line);
        var values = std.mem.splitScalar(u8, line, delimiter);
        var output = try std.ArrayList(ReturnType).initCapacity(self.allocator, amount);

        for (0..amount) |_| {
            const v = values.next() orelse unreachable;
            output.appendAssumeCapacity(try self.parseType(ReturnType, v));
        }

        return try output.toOwnedSlice();
    }

    /// Reads a complex type
    /// The shape needs to contain atleast n - 1 shapes, and the shapes of inside structs should be flattened
    /// The caller is responsible for freeing all the memory
    fn readType(self: Self, comptime ReturnType: type, shape: []const usize, delimiter: u8) !ReturnType {
        const typeInfo = @typeInfo(ReturnType);
        switch (typeInfo) {
            .Int, .Float => {
                return self.readValue(ReturnType);
            },
            .Pointer => {
                const childType = typeInfo.Pointer.child;
                if (ReturnType == []const u8) {
                    return self.read();
                }
                switch (@typeInfo(childType)) {
                    .Int, .Float => {
                        if (shape.len == 0) {
                            return self.readList(childType, delimiter);
                        } else return self.readNElements(childType, delimiter, shape[0]);
                    },
                    .Pointer, .Struct => {
                        if (ReturnType == []const u8) {
                            return try self.read();
                        }
                        var values = try std.ArrayList(childType).initCapacity(self.allocator, shape[0]);
                        for (shape[0]) |_| {
                            values.appendAssumeCapacity(try self.readType(childType, subShape[1..], delimiter));
                        }
                        return values.toOwnedSlice();
                    },
                    else => return error.UnsupportedType,
                }
            },
            .Struct => {
                const s = try self.allocator.create(ReturnType);
                var line: []const u8 = "";
                var currentIndex: usize = 0;
                var subShape = shape;
                inline for (typeInfo.Struct.fields) |field| {
                    const fieldInfo = @typeInfo(field.type);
                    switch (fieldInfo) {
                        .Int, .Float, .Pointer, .Struct => {
                            if (fieldInfo == .Int or fieldInfo == .Float or field.type == []const u8) {
                                if (line.len == currentIndex) {
                                    line = try self.read();
                                }
                                const index = std.mem.indexOfScalarPos(u8, line, currentIndex, delimiter);
                                if (index == null) {
                                    @field(s, field.name) = try self.parseType(field.type, line[currentIndex..]);
                                    self.allocator.free(line);
                                    currentIndex = 0;
                                    line = "";
                                } else {
                                    @field(s, field.name) = try self.parseType(field.type, line[currentIndex..index.?]);
                                    currentIndex = index.? + 1;
                                }
                            } else {
                                self.allocator.free(line);
                                line = "";
                                currentIndex = 0;
                                @field(s, field.name) = try self.readType(field.type, shape, delimiter);
                                if (subShape.len > 0)
                                    subShape = subShape[1..];
                            }
                        },
                        else => return error.UnsupportedType,
                    }
                }
                self.allocator.free(line);
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

    const matrix = try lineReader.readType([]Matrix, &[_]usize{ 2, 5, 5 }, ' ');

    std.debug.print("Matrix: {any}", .{matrix});
}

test "LineReader" {
    const expect = std.testing.expect;

    const allocator = std.testing.allocator;
    const input = try std.fs.cwd().openFile("tests/LineReader.input", .{});

    var lineReader = LineReader.init(allocator, input.reader());
    const line = try lineReader.readType([]const u8, &[_]usize{}, ' ');
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

    const matrix = try lineReader.readType([]Matrix, &[_]usize{ 2, 5, 5 }, ' ');
    defer {
        for (matrix) |structs| {
            std.debug.print("Matrix content: {any}\n", .{structs.content});
            for (structs.content) |row| {
                allocator.free(row);
            }
            std.debug.print("Matrix fun: {s}\n", .{structs.fun});
            allocator.free(structs.content);
            allocator.free(structs.fun);
        }
        allocator.free(matrix);
    }

    const SuperValue = struct { n: i32, s: i32, a: []const u8, b: []const u8 };
    const values = try lineReader.readType([]SuperValue, &[_]usize{3}, ' ');
    defer {
        for (values) |superValue| {
            std.debug.print("SuperValue.a: {s}\n", .{superValue.a});
            std.debug.print("SuperValue.b: {s}\n", .{superValue.b});
            std.debug.print("SuperValue.n: {d}\n", .{superValue.n});
            std.debug.print("SuperValue.s: {d}\n", .{superValue.s});
            allocator.free(superValue.a);
            allocator.free(superValue.b);
        }
        allocator.free(values);
    }

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
