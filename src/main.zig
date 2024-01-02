const std = @import("std");
const zap = @import("zap");
const Handler = @import("handler.zig").Handler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    var allocator = gpa.allocator();

    var config = try loadConfig(allocator, "/config.json");
    const u64time: u64 = @intCast(std.time.timestamp());

    Handler.alloc = allocator;
    Handler.saveDirPath = config.absoluteSaveDir;
    Handler.linkPrefix = config.linkPrefix;
    Handler.linkLength = config.filenameLength;
    Handler.rand = std.rand.Xoshiro256.init(u64time);
    Handler.genChars = config.genCharset;
    Handler.maxDirSize = config.maxSaveDirSizeMB * 1024 * 1024;

    // setup listener
    var listener = zap.SimpleHttpListener.init(
        .{
            .port = config.port,
            .on_request = Handler.on_request,
            .log = false,
            .max_clients = 10,
            .max_body_size = 1024 * 1024 * 1024,
            .public_folder = ".",
        },
    );
    zap.enableDebugLog();
    try listener.listen();
    std.log.info("\n\nURL is http://localhost:{any}\n", .{config.port});
    std.log.info("\ncurl -v --request POST -F img=@test012345.bin http://127.0.0.1:{any}\n", .{config.port});
    std.log.info("\n\nTerminate with CTRL+C\n", .{});

    zap.start(.{
        .threads = 1,
        .workers = 1,
    });
}

fn loadConfig(allocator: std.mem.Allocator, name: []const u8) !Config {
    const projPath = std.fs.realpathAlloc(allocator, ".") catch unreachable;
    std.debug.print("Config path: {s}\n", .{projPath});
    defer allocator.free(projPath);
    const configPath = try std.mem.concat(allocator, u8, &[_][]const u8{ projPath, name });
    const file = try std.fs.openFileAbsolute(configPath, .{});
    defer file.close();
    const content = file.reader().readAllAlloc(allocator, 1024) catch unreachable;
    defer allocator.free(content);
    const config = std.json.parseFromSlice(
        Config,
        allocator,
        content,
        .{},
    ) catch unreachable;

    return config.value;
}

const Config = struct {
    port: u16,
    linkPrefix: []u8,
    absoluteSaveDir: []u8,
    maxSaveDirSizeMB: u32,
    filenameLength: u16,
    genCharset: []u8,
};

test "paths" {
    const realPath = try std.fs.realpathAlloc(std.testing.allocator, ".\\");
    defer std.testing.allocator.free(realPath);
    std.debug.print("{s}\n", .{realPath});
}
