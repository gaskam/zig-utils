const std = @import("std");
const builtin = @import("builtin");
const Self = @This();

allocator: std.mem.Allocator,
reader: std.io.AnyReader,

pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) Self {
    return .{ .allocator = allocator, .reader = reader };
}

/// Reads a line without newline characters(\n, and \r\n for windows)
pub fn read(self: Self) ![]const u8 {
    var buffer = std.ArrayList(u8).init(self.allocator);
    errdefer buffer.deinit();
    self.reader.streamUntilDelimiter(buffer.writer(), '\n', null) catch |err| {
        if (err != error.EndOfStream) return err;
    };
    if (builtin.target.os.tag == .windows and buffer.getLastOrNull() == '\r') _ = buffer.pop();
    return buffer.toOwnedSlice();
}

/// Parses a 'level 1' type
/// Only accepts Int, Float, Bool and string([]const u8) types
pub fn parseType(self: Self, comptime ReturnType: type, buf: []const u8) !ReturnType {
    return switch (@typeInfo(ReturnType)) {
        .Int => std.fmt.parseInt(ReturnType, buf, 10),
        .Float => std.fmt.parseFloat(ReturnType, buf),
        .Bool => try std.fmt.parseInt(u1, buf, 10) != 0,
        // Asserts the type is []const u8, otherwise it is a complex type
        .Pointer => blk: {
            if (ReturnType != []const u8) break :blk error.UnsupportedType;
            break :blk self.allocator.dupe(u8, buf);
        },
        else => error.UnsupportedType,
    };
}

/// Parses one line to a value(only supports int, float or bool types)
/// Asserts there is a numeric value
pub fn readValue(self: Self, comptime ReturnType: type) !ReturnType {
    const value = try self.read();
    defer self.allocator.free(value);
    return self.parseType(ReturnType, value);
}

/// Reads all elements on a line, splits them by `delimiter` and parses them
/// Asserts there is atleast 1 element
pub fn readList(self: Self, comptime ReturnType: type, delimiter: u8) ![]ReturnType {
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

pub fn readArray(self: Self, comptime ReturnType: type, delimiter: u8) !ReturnType {
    const typeInfo = @typeInfo(ReturnType);
    const line = try self.read();
    defer self.allocator.free(line);
    var values = std.mem.splitScalar(u8, line, delimiter);
    var buf: ReturnType = undefined;

    for (0..typeInfo.Array.len) |i| {
        buf[i] = try self.parseType(typeInfo.Array.child, values.next().?);
    }
    return buf;
}

/// Reads N elements on a line, splits them by `delimiter` and parses them
pub fn readNElements(self: Self, comptime ReturnType: type, delimiter: u8, amount: usize) ![]ReturnType {
    const line = try self.read();
    defer self.allocator.free(line);

    var values = std.mem.splitScalar(u8, line, delimiter);
    var output = try self.allocator.alloc(ReturnType, amount);

    for (0..amount) |i| {
        const v = values.next() orelse unreachable;
        output[i] = try self.parseType(ReturnType, v);
    }

    return output;
}

/// Returns the amount of lens needed for shape inside of a type
inline fn readDepth(self: Self, comptime ReturnType: type) !comptime_int {
    const typeInfo = @typeInfo(ReturnType);
    return switch (typeInfo) {
        .Int, .Float, .Bool => 0,
        .Array => 0,
        .Pointer => blk: {
            const childType = typeInfo.Pointer.child;
            if (ReturnType == []const u8) {
                break :blk 0;
            }

            break :blk 1 + try self.readDepth(childType);
        },
        .Struct => {
            comptime var depth: usize = 0;
            inline for (typeInfo.Struct.fields) |field| {
                const fieldInfo = @typeInfo(field.type);
                switch (fieldInfo) {
                    .Pointer, .Struct => {
                        depth += try self.readDepth(field.type);
                    },
                    else => {},
                }
            }
            return depth;
        },
        else => error.UnsupportedType,
    };
}

/// Struct only implementation to simplify `readType` function
pub fn readStruct(self: Self, comptime ReturnType: type, shape: ?[]const usize, delimiter: u8) !ReturnType {
    const typeInfo = @typeInfo(ReturnType);
    std.debug.assert(typeInfo == .Struct);

    const s = try self.allocator.create(ReturnType);
    defer self.allocator.destroy(s);
    var line: []const u8 = "";
    var currentIndex: usize = 0;
    var subShape = shape orelse &[0]usize{};
    inline for (typeInfo.Struct.fields) |field| {
        const fieldInfo = @typeInfo(field.type);
        switch (fieldInfo) {
            .Int, .Float, .Bool => {
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
            .Array => {
                @field(s, field.name) = try self.readArray(field.type, delimiter);
            },
            .Pointer, .Struct => {
                self.allocator.free(line);
                line = "";
                currentIndex = 0;

                const depth = try self.readDepth(field.type);
                @field(s, field.name) = try self.readType(field.type, subShape[0..depth], delimiter);
                if (subShape.len > 0)
                    subShape = subShape[depth..];
            },
            else => return error.UnsupportedType,
        }
    }
    self.allocator.free(line);
    return s.*;
}

/// Reads a complex type
/// The shape needs to contain the required amount of lens (you can check the required amount with `readDepth`)
/// The caller is responsible for freeing all the memory
pub fn readType(self: Self, comptime ReturnType: type, shape: ?[]const usize, delimiter: u8) !ReturnType {
    const typeInfo = @typeInfo(ReturnType);
    std.debug.assert(try self.readDepth(ReturnType) == (shape orelse &[_]usize{}).len);

    switch (typeInfo) {
        .Int, .Float, .Bool => {
            return self.readValue(ReturnType);
        },
        .Pointer, .Array => {
            const childType = if (typeInfo == .Pointer) typeInfo.Pointer.child else typeInfo.Array.child;
            if (ReturnType == []const u8) {
                return self.read();
            }
            switch (@typeInfo(childType)) {
                .Int, .Float, .Bool => {
                    if (typeInfo == .Pointer) {
                        return self.readNElements(childType, delimiter, shape.?[0]);
                    } else {
                        const values = try self.readNElements(childType, delimiter, typeInfo.Array.len);
                        defer self.allocator.free(values);
                        return values[0..typeInfo.Array.len].*;
                    }
                },
                .Pointer, .Struct, .Array => {
                    if (ReturnType == []const u8) {
                        return try self.read();
                    }

                    const amount = if (typeInfo == .Pointer) shape.?[0] else typeInfo.Array.len;
                    var values = try std.ArrayList(childType).initCapacity(self.allocator, amount);
                    errdefer values.deinit();
                    for (amount) |_| {
                        values.appendAssumeCapacity(try self.readType(childType, (shape orelse @as([]const usize, &[_]usize{0}))[1..], delimiter));
                    }
                    if (typeInfo == .Pointer) {
                        return values.toOwnedSlice();
                    } else {
                        const result = try values.toOwnedSlice();
                        defer self.allocator.free(result);
                        return result[0..typeInfo.Array.len].*;
                    }
                },
                else => return error.UnsupportedType,
            }
        },
        .Struct => {
            return try self.readStruct(ReturnType, shape, delimiter);
        },
        else => return error.UnsupportedType,
    }
}

test "LineReader" {
    const LineReader = @This();

    const allocator = std.testing.allocator;
    const input = try std.fs.cwd().openFile("tests/LineReader.input", .{});
    defer input.close();

    var lineReader = LineReader.init(allocator, input.reader().any());
    const line = try lineReader.readType([]const u8, &[_]usize{}, ' ');
    defer allocator.free(line);
    const bools = try lineReader.readArray([5]bool, ' ');
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

    const ArrayStruct = struct { a: []i32, b: []i32 };

    const NestedStruct = struct {
        struct1: ArrayStruct,
        struct2: ArrayStruct,
    };

    const nestedStruct = try lineReader.readType([]NestedStruct, &[_]usize{ 2, 1, 2, 3, 4 }, ' ');
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
    try std.testing.expectEqualDeep(bools, (&[5]bool{ true, false, true, false, true }).*);
    try std.testing.expectEqualDeep(numbers, &[_]i32{ 123, 456, 789 });
    try std.testing.expectEqualDeep(floats, &[_]f64{ -2.5, 2.8, 9.7, 3.14 });
    try std.testing.expectEqualDeep(strings, &[_][]const u8{ "the", "new", "hello", "world" });
    try std.testing.expectEqualDeep(emptyStrings, &[_][]const u8{""});

    const expectedMatrix = &[_]Matrix{ Matrix{
        .content = @constCast(&[_][]i32{
            @constCast(&[_]i32{ 3, 4, 6, 8, 7 }),
            @constCast(&[_]i32{ 7, 8, 9, 5, 6 }),
            @constCast(&[_]i32{ 7, 8, 4, 2, 7 }),
            @constCast(&[_]i32{ 9, 7, 8, 6, 2 }),
            @constCast(&[_]i32{ 2, 5, 6, 8, 4 }),
        }),
        .text = "hello world",
    }, Matrix{
        .content = @constCast(&[_][]i32{
            @constCast(&[_]i32{ 7, 8, 9, 6, 5 }),
            @constCast(&[_]i32{ 1, 0, 2, 3, 6 }),
            @constCast(&[_]i32{ 8, 9, 6, 3, 2 }),
            @constCast(&[_]i32{ 7, 8, 9, 6, 5 }),
            @constCast(&[_]i32{ 1, 2, 5, 4, 7 }),
        }),
        .text = "see you later",
    } };
    try std.testing.expectEqualDeep(matrix, expectedMatrix);

    const expectedValues = &[_]SuperValue{
        SuperValue{ .n = 2, .s = 6, .a = "mjalajdsfk", .b = "mladfsmljqslkf" },
        SuperValue{ .n = 8, .s = 9, .a = "qsdfjqmlfp", .b = "poaljmdflk" },
        SuperValue{ .n = 98645, .s = 8, .a = "apdlfkjqmd", .b = "mladjfqp" },
    };
    try std.testing.expectEqualDeep(values, expectedValues);

    const expectedNestedStruct = &[_]NestedStruct{
        NestedStruct{
            .struct1 = ArrayStruct{ .a = @constCast(&[_]i32{1}), .b = @constCast(&[_]i32{ 1, 2 }) },
            .struct2 = ArrayStruct{ .a = @constCast(&[_]i32{ 1, 2, 3 }), .b = @constCast(&[_]i32{ 1, 2, 3, 4 }) },
        },
        NestedStruct{
            .struct1 = ArrayStruct{ .a = @constCast(&[_]i32{9}), .b = @constCast(&[_]i32{ 9, 8 }) },
            .struct2 = ArrayStruct{ .a = @constCast(&[_]i32{ 9, 8, 7 }), .b = @constCast(&[_]i32{ 9, 8, 7, 6 }) },
        },
    };

    try std.testing.expectEqualDeep(nestedStruct, expectedNestedStruct);
}
