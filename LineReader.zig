const std = @import("std");

const List = struct {
    size1: usize,
    int_list: []i32,
};

const String = struct {
    size2: usize,
    string_list: []const u8,
};

const LineReader = struct{
    line: []const u8,
    allocator: std.mem.Allocator,
    fn init(allocator: std.mem.Allocator, reader) Self {
        return .{
            ...
        }
    }
}

/// Reads one line of stdin using an allocator an returns the result as a string
fn readStdInLine(allocator: std.mem.Allocator) ![]const u8 {
    const stdin = std.io.getStdIn().reader();
    var buffer = std.ArrayList(u8).init(allocator);
    try stdin.streamUntilDelimiter(buffer.writer(), '\n', null);
    return std.mem.trimRight(u8, buffer.items, "\r\n");
}

/// Uses `readStdInLine` to read a line from stdin and converts it into an integer
fn readStdInInt(allocator: std.mem.Allocator) !i32 {
    const Input = union {
        string: []const u8,
        number: i32,
    };
    var out = Input{ .string = try readStdInLine(allocator) };
    out = Input{ .number = try std.fmt.parseInt(i32, out.string, 10) };

    return out.number;
}

fn readStdInFloat(allocator: std.mem.Allocator) !f64 {
    const Input = union {
        string: []const u8,
        number: f64,
    };
    var out = Input{ .string = try readStdInLine(allocator) };
    out = Input{ .number = try std.fmt.parseFloat(f64, out.string) };

    return out.number;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const n: usize = @intCast(try readStdInInt(allocator));

    var listsList = try std.ArrayList(List).initCapacity(allocator, n);
    for (0..n) |_| {
        const subListLen: usize = @intCast(try readStdInInt(allocator));

        var subList = try std.ArrayList(i32).initCapacity(allocator, subListLen);

        const line = try allocator.dupe(u8, try readStdInLine(allocator));
        var values = std.mem.splitScalar(u8, line, ' ');

        while (values.next()) |v| {
            const value = try std.fmt.parseInt(i32, v, 10);
            subList.appendAssumeCapacity(value);
        }
        listsList.appendAssumeCapacity(List{ .int_list = subList.items, .size1 = subListLen });
    }
    const lists = listsList.items;

    var stringsList = try std.ArrayList(String).initCapacity(allocator, n);
    for (0..n) |_| {
        const subListLen: usize = @intCast(try readStdInInt(allocator));

        const line = try allocator.dupe(u8, try readStdInLine(allocator));

        stringsList.appendAssumeCapacity(String{ .string_list = line, .size2 = subListLen });
    }
    const strings = stringsList.items;

    var matricesList = try std.ArrayList(Matrix).initCapacity(allocator, n);
    for (0..2) |_| {
        const subListLen: usize = @intCast(try readStdInInt(allocator));

        var subList = try std.ArrayList([]i32).initCapacity(allocator, subListLen);

        for (0..subListLen) |_| {
            const line = try allocator.dupe(u8, try readStdInLine(allocator));
            var subSubList = try std.ArrayList(i32).initCapacity(allocator, line.len);

            var values = std.mem.splitScalar(u8, line, ' ');

            while (values.next()) |v| {
                const buf = v;
                const value = try std.fmt.parseInt(i32, buf, 10);
                subSubList.appendAssumeCapacity(value);
            }
            subList.appendAssumeCapacity(subSubList.items);
        }

        matricesList.appendAssumeCapacity(Matrix{ .list_list = subList.items, .size3 = subListLen });
    }
    const matrices = matricesList.items;

    try simple(@intCast(n), lists, strings, matrices);
}
