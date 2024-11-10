const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "Run tests");

    const zigFiles = blk: {
        var directory = try std.fs.cwd().openDir(".", .{
            .iterate = true,
        });
        var iterator = directory.iterate();
        defer directory.close();
        var fileList = std.ArrayList([]const u8).init(b.allocator);
        while (try iterator.next()) |entry| {
            switch (entry.kind) {
                .directory => continue,
                .file => {
                    if (std.mem.eql(u8, entry.name, "build.zig")) continue;
                    if (std.mem.endsWith(u8, entry.name, ".zig"))
                        try fileList.append(try b.allocator.dupe(u8, entry.name));
                },
                else => unreachable,
            }
        }
        break :blk try fileList.toOwnedSlice();
    };

    for (zigFiles) |file| {
        const run_step = b.addRunArtifact(b.addTest(.{
            .root_source_file = b.path(file),
        }));
        test_step.dependOn(&run_step.step);
    }
}
