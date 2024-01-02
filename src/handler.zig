const std = @import("std");
const zap = @import("zap");
const fs = @import("std").fs;

pub const Handler = struct {
    pub var alloc: std.mem.Allocator = undefined;
    pub var saveDirPath: []const u8 = undefined;
    pub var linkPrefix: []const u8 = undefined;
    pub var linkLength: u16 = 5;
    pub var rand: std.rand.Xoshiro256 = undefined;
    pub var genChars: []u8 = undefined;
    pub var maxDirSize: usize = undefined;

    pub fn on_request(r: zap.SimpleRequest) void {
        var generatedName: []const u8 = undefined;

        // check for FORM parameters
        r.parseBody() catch |err| {
            std.log.err("Parse Body error: {any}. Expected if body is empty", .{err});
            r.sendError(err, 400);
            return;
        };

        // check for query params (for ?terminate=true)
        r.parseQuery();

        const params = r.parametersToOwnedList(Handler.alloc, false) catch |err| {
            r.sendError(err, 500);
            return;
        };

        defer params.deinit();
        var saveDir = fs.openIterableDirAbsolute(saveDirPath, .{}) catch |err| {
            std.log.err("\n\n\nFailed to open save directory {s}: {any}\n\n\n", .{ saveDirPath, err });
            unreachable;
        };
        defer saveDir.close();
        const dirSize = calcDirSize(saveDir) catch |err| {
            r.sendError(err, 500);
            return;
        };

        if (dirSize < maxDirSize) {
            std.debug.print("dir size: {any}MB", .{dirSize / 1024 / 1024});
        }

        for (params.items) |kv| {
            if (kv.value) |v| {
                switch (v) {
                    // single-file upload
                    zap.HttpParam.Hash_Binfile => |*file| {
                        const filename = file.filename orelse "(no filename)";
                        const mimetype = file.mimetype orelse "(no mimetype)";
                        const data = file.data orelse "";

                        std.log.debug("    filename: `{s}`\n", .{filename});
                        std.log.debug("    mimetype: {s}\n", .{mimetype});

                        if (data.len >= maxDirSize) {
                            r.sendError(anyerror.FileTooBig, 500);
                            return;
                        }

                        generatedName = generateName(filename);
                        var genAttempts: usize = 0;
                        while (fileExists(saveDir, generatedName)) : (genAttempts += 1) {
                            generatedName = generateName(filename);
                            if (genAttempts >= 10) {
                                std.log.err("Failed to generate {any}-char long unique file name after 10 tries.\n", .{linkLength});
                                r.sendError(anyerror.FileNamesExhausted, 500);
                                return;
                            }
                        }

                        var f = saveDir.dir.createFile(generatedName, .{}) catch |err| {
                            r.sendError(err, 500);
                            return;
                        };

                        f.writeAll(data) catch |err| {
                            r.sendError(err, 500);
                            return;
                        };
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

        const result_str = std.fmt.allocPrint(alloc, "{s}{s}", .{ linkPrefix, generatedName }) catch unreachable;
        r.sendBody(result_str) catch unreachable;
        alloc.free(result_str);
        alloc.free(generatedName);
    }

    fn calcDirSize(iterable: std.fs.IterableDir) !usize {
        var iterator = iterable.iterate();
        var byteSize: usize = 0;
        while (try iterator.next()) |file| {
            if (file.kind != .file) continue;
            const f = try iterable.dir.openFile(file.name, .{});
            defer f.close();
            const stat = try f.stat();
            byteSize += stat.size;
        }

        return byteSize;
    }

    fn generateName(from_name: []const u8) []u8 {
        rand.random().shuffle(u8, genChars);
        const dotIdx = std.mem.lastIndexOf(u8, from_name, ".");
        var res: []u8 = undefined;
        if (dotIdx) |dIdx| {
            const extLen = from_name.len - dIdx;
            res = alloc.alloc(u8, linkLength + extLen) catch unreachable;
            @memcpy(res[0..linkLength], genChars[0..linkLength]);
            @memcpy(res[linkLength..(linkLength + extLen)], from_name[dIdx..(dIdx + extLen)]);
            return res;
        }

        res = alloc.alloc(u8, linkLength) catch unreachable;
        @memcpy(res[0..linkLength], genChars[0..linkLength]);
        return res;
    }

    fn fileExists(dir: std.fs.IterableDir, name: []const u8) bool {
        var iterator = dir.iterate();
        while (iterator.next() catch unreachable) |file| {
            if (file.kind != .file) continue;
            if (std.mem.eql(u8, file.name, name)) return true;
        }

        return false;
    }
};
