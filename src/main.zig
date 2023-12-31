const std = @import("std");
const zap = @import("zap");
const Handler = @import("handler.zig").Handler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    var allocator = gpa.allocator();

    Handler.alloc = allocator;

    // setup listener
    var listener = zap.SimpleHttpListener.init(
        .{
            .port = 3000,
            .on_request = Handler.on_request,
            .log = true,
            .max_clients = 10,
            .max_body_size = 10 * 1024 * 1024,
            .public_folder = ".",
        },
    );
    zap.enableDebugLog();
    try listener.listen();
    std.log.info("\n\nURL is http://localhost:3000\n", .{});
    std.log.info("\ncurl -v --request POST -F img=@test012345.bin http://127.0.0.1:3000\n", .{});
    std.log.info("\n\nTerminate with CTRL+C or by sending query param terminate=true\n", .{});

    zap.start(.{
        .threads = 1,
        .workers = 1,
    });
}

const Settings = struct {
    port: u16,
    linkPrefix: []u8,
    absoluteSaveDir: []u8,
    maxFolderSizeMB: u32,
};

test "paths" {
    const realPath = try std.fs.realpathAlloc(std.testing.allocator, ".\\");
    defer std.testing.allocator.free(realPath);
    std.debug.print("{s}\n", .{realPath});
}
