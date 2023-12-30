const std = @import("std");
const zap = @import("zap");
const fs = @import("std").fs;

const Handler = struct {
    var alloc: std.mem.Allocator = undefined;
    var saveDirPath: []const u8 = undefined;
    var linkPrefix: []const u8 = undefined;

    pub fn on_request(r: zap.SimpleRequest) void {
        var generatedName: []const u8 = undefined;

        // check for FORM parameters
        r.parseBody() catch |err| {
            std.log.err("Parse Body error: {any}. Expected if body is empty", .{err});
        };

        if (r.body) |body| {
            std.log.info("Body length is {any}\n", .{body.len});
        }
        // check for query params (for ?terminate=true)
        r.parseQuery();

        var param_count = r.getParamCount();
        std.log.info("param_count: {}", .{param_count});

        // iterate over all params
        //
        // HERE WE HANDLE THE BINARY FILE
        //
        const params = r.parametersToOwnedList(Handler.alloc, false) catch unreachable;
        defer params.deinit();
        var saveDir = fs.openIterableDirAbsolute(saveDirPath, .{}) catch unreachable;
        defer saveDir.close();
        for (params.items) |kv| {
            if (kv.value) |v| {
                std.debug.print("\n", .{});
                std.log.info("Param `{s}` in owned list is {any}\n", .{ kv.key.str, v });
                switch (v) {
                    // single-file upload
                    zap.HttpParam.Hash_Binfile => |*file| {
                        const filename = file.filename orelse "(no filename)";
                        const mimetype = file.mimetype orelse "(no mimetype)";
                        const data = file.data orelse "";

                        std.log.debug("    filename: `{s}`\n", .{filename});
                        std.log.debug("    mimetype: {s}\n", .{mimetype});
                        std.log.debug("    contents: {any}\n", .{data});

                        var f = saveDir.dir.createFile(filename, .{}) catch |err| switch (err) {
                            fs.File.OpenError.PathAlreadyExists => {
                                // generate new name
                            },
                            else => unreachable,
                        };
                        f.writeAll(data) catch unreachable;
                    },
                    // multi-file upload
                    zap.HttpParam.Array_Binfile => |*files| {
                        for (files.*.items) |file| {
                            const filename = file.filename orelse "(no filename)";
                            const mimetype = file.mimetype orelse "(no mimetype)";
                            const data = file.data orelse "";

                            std.log.debug("    filename: `{s}`\n", .{filename});
                            std.log.debug("    mimetype: {s}\n", .{mimetype});
                            std.log.debug("    contents: {any}\n", .{data});
                        }
                        files.*.deinit();
                    },
                    else => {
                        // might be a string param, we don't care
                        // let's just get it as string
                        if (r.getParamStr(kv.key.str, Handler.alloc, false)) |maybe_str| {
                            const value: []const u8 = if (maybe_str) |s| s.str else "(no value)";
                            std.log.debug("   {s} = {s}", .{ kv.key.str, value });
                        } else |err| {
                            std.log.err("Error: {any}\n", .{err});
                        }
                    },
                }
            }
        }

        // check if we received a terminate=true parameter
        if (r.getParamStr("terminate", Handler.alloc, false)) |maybe_str| {
            if (maybe_str) |*s| {
                defer s.deinit();
                std.log.info("?terminate={s}\n", .{s.str});
                if (std.mem.eql(u8, s.str, "true")) {
                    zap.fio_stop();
                }
            }
        } else |err| {
            std.log.err("cannot check for terminate param: {any}\n", .{err});
        }

        const result_str = std.fmt.allocPrint(alloc, "{s}{s}", .{ linkPrefix, generatedName });
        r.sendBody(result_str) catch unreachable;
    }
};
