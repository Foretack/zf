const std = @import("std");
const zap = @import("zap");
const fs = @import("std").fs;
const IterableDir = @import("std").fs.IterableDir;

pub const Handler = struct {
    pub var alloc: std.mem.Allocator = undefined;
    pub var saveDirPath: []const u8 = undefined;
    pub var linkPrefix: []const u8 = undefined;
    pub var linkLength: u16 = 5;
    pub var rand: std.rand.Xoshiro256 = undefined;
    pub var genChars: []u8 = undefined;
    pub var maxDirSize: usize = undefined;

    var dirSize: usize = 0;

    pub fn on_request(r: zap.SimpleRequest) void {
        if (!std.mem.eql(u8, r.method.?, "POST") or !std.mem.eql(u8, r.path.?, "/upload")) {
            r.setStatus(zap.StatusCode.method_not_allowed);
            r.sendBody("only POST /upload is allowed.") catch return;
            return;
        }

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
        if (ensureDirExists(saveDirPath)) {
            std.log.info("Directory created: {s}\n", .{saveDirPath});
        }

        var saveDir = fs.openIterableDirAbsolute(saveDirPath, .{}) catch |err| {
            std.log.err("\n\n\nFailed to open save directory {s}: {any}\n\n\n", .{ saveDirPath, err });
            unreachable;
        };
        defer saveDir.close();

        if (dirSize == 0) dirSize = calcDirSize(saveDir) catch |err| {
            r.sendError(err, 500);
            return;
        };

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

                        if (dirSize + data.len > maxDirSize) {
                            makeSpace(saveDir, data.len) catch |err| {
                                r.sendError(err, 500);
                                return;
                            };
                        }

                        dirSize += data.len;

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
                        defer files.*.deinit();
                        var arena = std.heap.ArenaAllocator.init(alloc);
                        const a_alloc = arena.allocator();
                        defer arena.deinit();
                        var list = a_alloc.create(std.ArrayList([]const u8)) catch |err| {
                            r.sendError(err, 500);
                            return;
                        };

                        for (files.*.items) |file| {
                            const filename = file.filename orelse "(no filename)";
                            const mimetype = file.mimetype orelse "(no mimetype)";
                            const data = file.data orelse "";

                            std.log.debug("    filename: `{s}`\n", .{filename});
                            std.log.debug("    mimetype: {s}\n", .{mimetype});

                            if (data.len >= maxDirSize) {
                                r.sendError(anyerror.FileTooBig, 500);
                                return;
                            }

                            if (dirSize + data.len > maxDirSize) {
                                makeSpace(saveDir, data.len) catch |err| {
                                    r.sendError(err, 500);
                                    return;
                                };
                            }

                            dirSize += data.len;

                            generatedName = generateName(filename);
                            list.append(a_alloc.dupe(u8, generatedName) catch unreachable) catch |err| {
                                r.sendError(err, 500);
                                return;
                            };

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
                        }

                        const res = a_alloc.alloc(u8, list.items.len * (linkLength + linkPrefix.len + 1)) catch |err| {
                            r.sendError(err, 500);
                            return;
                        };

                        var i: usize = 0;
                        for (list.items) |linkName| {
                            const link = std.fmt.allocPrint(a_alloc, "{s}{s}\n", .{ linkPrefix, linkName }) catch |err| {
                                r.sendError(err, 500);
                                return;
                            };

                            @memcpy(res[i .. linkLength + linkLength.len + 1], link);
                            i += linkLength + linkLength.len + 1;
                        }

                        r.sendBody(res) catch unreachable;
                        return;
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

    fn makeSpace(dir: IterableDir, bytes: usize) !void {
        var min: i128 = 0;
        var freed: i128 = 0;
        while (freed < bytes) {
            var itr = dir.iterate();
            while (try itr.next()) |item| {
                if (item.kind != .file) continue;
                const file = try dir.dir.openFile(item.name, .{});
                defer file.close();
                const stat = try file.stat();
                if (min == 0 or min > stat.mtime) min = stat.mtime;
            }

            itr = dir.iterate();
            while (try itr.next()) |item| {
                if (item.kind != .file) continue;
                const file = try dir.dir.openFile(item.name, .{});
                const stat = try file.stat();
                file.close();
                if (stat.mtime == min) {
                    try dir.dir.deleteFile(item.name);
                    freed += stat.size;
                    min = 0;
                    break;
                }
            }
        }

        dirSize -= @intCast(freed);
        std.log.info("Freed {any} byes\n", .{freed});
    }

    fn ensureDirExists(path: []const u8) bool {
        fs.makeDirAbsolute(path) catch return false;
        return true;
    }

    fn calcDirSize(iterable: IterableDir) !usize {
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

    fn fileExists(dir: IterableDir, name: []const u8) bool {
        var iterator = dir.iterate();
        while (iterator.next() catch unreachable) |file| {
            if (file.kind != .file) continue;
            if (std.mem.eql(u8, file.name, name)) return true;
        }

        return false;
    }
};
