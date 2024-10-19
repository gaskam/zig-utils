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
        self.reader.streamUntilDelimiter(buffer.writer(), '\n', null) catch |err| {
            if (err != error.EndOfStream) return err;
        };
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
        errdefer output.deinit();

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
        errdefer output.deinit();

        for (0..amount) |_| {
            const v = values.next() orelse unreachable;
            output.appendAssumeCapacity(try self.parseType(ReturnType, v));
        }

        return try output.toOwnedSlice();
    }

    /// Returns the amount of lens needed for shape inside of a type
    inline fn readDepth(self: Self, comptime ReturnType: type) !comptime_int {
        const typeInfo = @typeInfo(ReturnType);
        return switch (typeInfo) {
            .Int, .Float => 0,
            .Pointer => blk: {
                const childType = typeInfo.Pointer.child;
                if (ReturnType == []const u8) {
                    break :blk 0;
                }
                switch (@typeInfo(childType)) {
                    .Int, .Float => break :blk 1,
                    .Pointer, .Struct => {
                        if (ReturnType == []const u8) {
                            break :blk 1;
                        }
                        break :blk 1 + try self.readDepth(childType);
                    },
                    else => return error.UnsupportedType,
                }
            },
            .Struct => {
                comptime var depth: usize = 0;
                inline for (typeInfo.Struct.fields) |field| {
                    const fieldInfo = @typeInfo(field.type);
                    switch (fieldInfo) {
                        .Int, .Float => {},
                        .Pointer, .Struct => {
                            depth += try self.readDepth(field.type);
                        },
                        else => return error.UnsupportedType,
                    }
                }
                return depth;
            },
            else => error.UnsupportedType,
        };
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
                        return self.readNElements(childType, delimiter, shape[0]);
                    },
                    .Pointer, .Struct => {
                        if (ReturnType == []const u8) {
                            return try self.read();
                        }
                        var values = try std.ArrayList(childType).initCapacity(self.allocator, shape[0]);
                        errdefer values.deinit();
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
                defer self.allocator.destroy(s);
                var line: []const u8 = "";
                var currentIndex: usize = 0;
                var subShape = shape;
                inline for (typeInfo.Struct.fields) |field| {
                    const fieldInfo = @typeInfo(field.type);
                    switch (fieldInfo) {
                        .Int, .Float => {
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
                        },
                        .Pointer, .Struct => {
                            self.allocator.free(line);
                            line = "";
                            currentIndex = 0;
                            @field(s, field.name) = try self.readType(field.type, subShape, delimiter);
                            if (subShape.len > 0)
                                subShape = subShape[try self.readDepth(field.type)..];
                        },
                        else => return error.UnsupportedType,
                    }
                }
                self.allocator.free(line);
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
        text: []const u8,
    };

    const matrix = try lineReader.readType([]Matrix, &[_]usize{ 2, 3, 3 }, ' ');

    std.debug.print("Matrix: {any}", .{matrix});
}

test "LineReader" {
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
        text: []const u8,
    };

    const matrix = try lineReader.readType([]Matrix, &[_]usize{ 2, 5, 5 }, ' ');
    defer {
        for (matrix) |structs| {
            for (structs.content) |row| {
                allocator.free(row);
            }
            allocator.free(structs.content);
            allocator.free(structs.text);
        }
        allocator.free(matrix);
    }

    const SuperValue = struct { n: i32, s: i32, a: []const u8, b: []const u8 };
    const values = try lineReader.readType([]SuperValue, &[_]usize{3}, ' ');
    defer {
        for (values) |superValue| {
            allocator.free(superValue.a);
            allocator.free(superValue.b);
        }
        allocator.free(values);
    }

    const ArrayStruct = struct {
        a: []i32,
        b: []i32
    };

    const NestedStruct = struct {
        struct1: ArrayStruct,
        struct2: ArrayStruct,
    };

    const nestedStruct = try lineReader.readType([]NestedStruct, &[_]usize{2, 1, 2, 3, 4}, ' ');
    defer {
        for (nestedStruct) |nested| {
            allocator.free(nested.struct1.a);
            allocator.free(nested.struct1.b);
            allocator.free(nested.struct2.a);
            allocator.free(nested.struct2.b);
        }
        allocator.free(nestedStruct);
    }

    try std.testing.expectEqualStrings(line, "Hello world");
    try std.testing.expectEqualDeep(numbers, &[_]i32{ 123, 456, 789 });
    try std.testing.expectEqualDeep(floats, &[_]f64{ -2.5, 2.8, 9.7, 3.14 });
    try std.testing.expectEqualDeep(strings, &[_][]const u8{ "the", "new", "hello", "world" });
    try std.testing.expectEqualDeep(emptyStrings, &[_][]const u8{""});

    const expectedMatrix = &[_]Matrix{
        Matrix{
            .content = @constCast(&[_][]i32 {
                @constCast(&[_]i32{3, 4, 6, 8, 7}),
                @constCast(&[_]i32{7, 8, 9, 5, 6}),
                @constCast(&[_]i32{7, 8, 4, 2, 7}),
                @constCast(&[_]i32{9, 7, 8, 6, 2}),
                @constCast(&[_]i32{2, 5, 6, 8, 4}),
            }),
            .text = "hello world",
        },
        Matrix{
            .content = @constCast(&[_][]i32 {
                @constCast(&[_]i32{7, 8, 9, 6, 5}),
                @constCast(&[_]i32{1, 0, 2, 3, 6}),
                @constCast(&[_]i32{8, 9, 6, 3, 2}),
                @constCast(&[_]i32{7, 8, 9, 6, 5}),
                @constCast(&[_]i32{1, 2, 5, 4, 7}),
            }),
            .text = "see you later",
        }
    };
    try std.testing.expectEqualDeep(matrix, expectedMatrix);

    const expectedValues = &[_]SuperValue{
        SuperValue{ .n = 2, .s = 6, .a = "mjalajdsfk", .b = "mladfsmljqslkf" },
        SuperValue{ .n = 8, .s = 9, .a = "qsdfjqmlfp", .b = "poaljmdflk" },
        SuperValue{ .n = 98645, .s = 8, .a = "apdlfkjqmd", .b = "mladjfqp" },
    };
    try std.testing.expectEqualDeep(values, expectedValues);

    const expectedNestedStruct = &[_]NestedStruct{
        NestedStruct{
            .struct1 = ArrayStruct{ 
                .a = @constCast(&[_]i32{1}), 
                .b = @constCast(&[_]i32{1, 2}) 
            },
            .struct2 = ArrayStruct{ 
                .a = @constCast(&[_]i32{1, 2, 3}), 
                .b = @constCast(&[_]i32{1, 2, 3, 4}) 
            },
        },
        NestedStruct{
            .struct1 = ArrayStruct{ 
                .a = @constCast(&[_]i32{9}), 
                .b = @constCast(&[_]i32{9, 8}) 
            },
            .struct2 = ArrayStruct{ 
                .a = @constCast(&[_]i32{9, 8, 7}), 
                .b = @constCast(&[_]i32{9, 8, 7, 6})
            },
        },
    };

    try std.testing.expectEqualDeep(nestedStruct, expectedNestedStruct);

}
