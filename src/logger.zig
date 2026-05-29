const std = @import("std");

pub const Logger = struct {
    pub const Error = error{
        WriteFailed,
    };

    pub const Format = enum {
        text,
        json,

        fn levelStr(self: Format, level: std.log.Level) []const u8 {
            return switch (self) {
                .text => switch (level) {
                    .err => "ERROR",
                    .warn => "WARN",
                    .info => "INFO",
                    .debug => "DEBUG",
                },
                .json => switch (level) {
                    .err => "error",
                    .warn => "warn",
                    .info => "info",
                    .debug => "debug",
                },
            };
        }

        fn write(
            self: Format,
            writer: *std.Io.Writer,
            level: std.log.Level,
            ts: std.Io.Timestamp,
            scope: ?[]const u8,
            comptime msg: []const u8,
            attrs: anytype,
        ) Error!void {
            switch (self) {
                .text => {
                    try writeTimestamp(writer, ts);
                    try writer.print(" [{s}]", .{self.levelStr(level)});
                    if (scope) |name| {
                        if (name.len > 0) try writer.print(" [{s}]", .{name});
                    }
                    if (msg.len > 0) try writer.print(" {s}", .{msg});
                    inline for (std.meta.fields(@TypeOf(attrs))) |field| {
                        const value = @field(attrs, field.name);
                        if (comptime isStringLike(@TypeOf(value))) {
                            try writer.print(" {s}=", .{field.name});
                            try writeQuotedString(writer, value);
                        } else {
                            try writer.print(" {s}={}", .{ field.name, value });
                        }
                    }
                    try writer.writeByte('\n');
                },
                .json => {
                    try writer.writeAll("{\"time\":\"");
                    try writeTimestamp(writer, ts);
                    try writer.writeByte('"');
                    try writer.print(",\"level\":\"{s}\"", .{self.levelStr(level)});
                    if (scope) |name| {
                        if (name.len > 0) {
                            try writer.writeAll(",\"scope\":");
                            try writeQuotedString(writer, name);
                        }
                    }
                    try writer.writeAll(",\"msg\":");
                    try writeQuotedString(writer, msg);
                    inline for (std.meta.fields(@TypeOf(attrs))) |field| {
                        const value = @field(attrs, field.name);
                        if (comptime isStringLike(@TypeOf(value))) {
                            try writer.print(",\"{s}\":", .{field.name});
                            try writeQuotedString(writer, value);
                        } else {
                            try writer.print(",\"{s}\":{}", .{ field.name, value });
                        }
                    }
                    try writer.writeAll("}\n");
                },
            }
        }
    };

    pub const Options = struct {
        level: std.log.Level = .info,
        format: Format = .text,
        scope: ?[]const u8 = null,
        // null のときは Timestamp.now で実時刻を取得する。テスト時に固定値を注入するために使用する。
        fixed_timestamp: ?std.Io.Timestamp = null,
    };

    io: std.Io,
    writer: *std.Io.Writer,
    options: Options,

    pub fn init(io: std.Io, writer: *std.Io.Writer, options: Options) Logger {
        return .{ .io = io, .writer = writer, .options = options };
    }

    pub fn log(
        self: Logger,
        msg_level: std.log.Level,
        comptime msg: []const u8,
        attrs: anytype,
    ) Error!void {
        if (@intFromEnum(msg_level) > @intFromEnum(self.options.level)) return;

        const ts = self.options.fixed_timestamp orelse
            std.Io.Timestamp.now(self.io, .real);
        try self.options.format.write(self.writer, msg_level, ts, self.options.scope, msg, attrs);
        try self.writer.flush();
    }

    pub fn err(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.err, msg, attrs);
    }

    pub fn warn(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.warn, msg, attrs);
    }

    pub fn info(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.info, msg, attrs);
    }

    pub fn debug(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.debug, msg, attrs);
    }
};

fn writeQuotedString(writer: *std.Io.Writer, s: []const u8) Logger.Error!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeTimestamp(writer: *std.Io.Writer, ts: std.Io.Timestamp) Logger.Error!void {
    // RFC 3339 は秒精度まで。サブ秒は切り捨てる。
    const seconds = @divFloor(ts.nanoseconds, std.time.ns_per_s);
    if (seconds < 0) @panic("pre-1970 timestamps are not supported");
    if (seconds > std.math.maxInt(u64)) @panic("timestamp out of range");

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    try writer.print("{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

// --- Format.levelStr ---

test "Format.levelStr" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { level: std.log.Level, format: Logger.Format },
        expected: []const u8,
    }{
        .{
            .name = "text/err",
            .input = .{ .level = .err, .format = .text },
            .expected = "ERROR",
        },
        .{
            .name = "text/warn",
            .input = .{ .level = .warn, .format = .text },
            .expected = "WARN",
        },
        .{
            .name = "text/info",
            .input = .{ .level = .info, .format = .text },
            .expected = "INFO",
        },
        .{
            .name = "text/debug",
            .input = .{ .level = .debug, .format = .text },
            .expected = "DEBUG",
        },
        .{
            .name = "json/err",
            .input = .{ .level = .err, .format = .json },
            .expected = "error",
        },
        .{
            .name = "json/warn",
            .input = .{ .level = .warn, .format = .json },
            .expected = "warn",
        },
        .{
            .name = "json/info",
            .input = .{ .level = .info, .format = .json },
            .expected = "info",
        },
        .{
            .name = "json/debug",
            .input = .{ .level = .debug, .format = .json },
            .expected = "debug",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqualStrings(tc.expected, tc.input.format.levelStr(tc.input.level));
    }
}

// --- Format.write ---

test "Format.write: text, no attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.text.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        null,
        "server started",
        .{},
    );

    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] server started\n",
        buf[0..writer.end],
    );
}

test "Format.write: text, with scope" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?[]const u8,
        expected: []const u8,
    }{
        .{
            .name = "no scope",
            .input = null,
            .expected = "1970-01-01T00:00:00Z [INFO] server started\n",
        },
        .{
            .name = "empty scope",
            .input = "",
            .expected = "1970-01-01T00:00:00Z [INFO] server started\n",
        },
        .{
            .name = "with scope",
            .input = "database",
            .expected = "1970-01-01T00:00:00Z [INFO] [database] server started\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try Logger.Format.text.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            tc.input,
            "server started",
            .{},
        );

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Format.write: text, with int attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.text.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        null,
        "server started",
        .{ .port = 8080 },
    );

    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] server started port=8080\n",
        buf[0..writer.end],
    );
}

test "Format.write: text, with string attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.text.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        null,
        "user logged in",
        .{ .ip = "127.0.0.1" },
    );

    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] user logged in ip=\"127.0.0.1\"\n",
        buf[0..writer.end],
    );
}

test "Format.write: text, string attr with special chars" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "newline",
            .input = "hello\nworld",
            .expected = "1970-01-01T00:00:00Z [INFO] msg msg=\"hello\\nworld\"\n",
        },
        .{
            .name = "double quote",
            .input = "say \"hi\"",
            .expected = "1970-01-01T00:00:00Z [INFO] msg msg=\"say \\\"hi\\\"\"\n",
        },
        .{
            .name = "backslash",
            .input = "C:\\path",
            .expected = "1970-01-01T00:00:00Z [INFO] msg msg=\"C:\\\\path\"\n",
        },
        .{
            .name = "tab",
            .input = "col1\tcol2",
            .expected = "1970-01-01T00:00:00Z [INFO] msg msg=\"col1\\tcol2\"\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try Logger.Format.text.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            null,
            "msg",
            .{ .msg = tc.input },
        );

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Format.write: text, write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        Logger.Format.text.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            null,
            "msg",
            .{},
        ),
    );
}

test "Format.write: json, no attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.json.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        null,
        "server started",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"msg\":\"server started\"}\n",
        buf[0..writer.end],
    );
}

test "Format.write: json, write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        Logger.Format.json.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            null,
            "msg",
            .{},
        ),
    );
}

test "Format.write: json, with scope" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?[]const u8,
        expected: []const u8,
    }{
        .{
            .name = "no scope",
            .input = null,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"server started\"}\n",
        },
        .{
            .name = "empty scope",
            .input = "",
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"server started\"}\n",
        },
        .{
            .name = "with scope",
            .input = "database",
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"scope\":\"database\",\"msg\":\"server started\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try Logger.Format.json.write(
            &writer,
            .info,
            std.Io.Timestamp.fromNanoseconds(0),
            tc.input,
            "server started",
            .{},
        );

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Format.write: json, special chars in scope" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.json.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        "my\"logger",
        "msg",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
            "\"scope\":\"my\\\"logger\",\"msg\":\"msg\"}\n",
        buf[0..writer.end],
    );
}

test "Format.write: json, special chars in msg" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.json.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        null,
        "say \"hello\"",
        .{},
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
            "\"msg\":\"say \\\"hello\\\"\"}\n",
        buf[0..writer.end],
    );
}

test "Format.write: json, special chars in string attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try Logger.Format.json.write(
        &writer,
        .info,
        std.Io.Timestamp.fromNanoseconds(0),
        null,
        "msg",
        .{ .path = "C:\\Users\\test" },
    );

    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
            "\"msg\":\"msg\",\"path\":\"C:\\\\Users\\\\test\"}\n",
        buf[0..writer.end],
    );
}

// --- Logger.init ---

test "Logger.init" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.Io.Timestamp,
        expected: []const u8,
    }{
        .{
            .name = "default values",
            .input = std.Io.Timestamp.fromNanoseconds(0),
            .expected = "1970-01-01T00:00:00Z [INFO] msg\n",
        },
        .{
            .name = "fixed_timestamp option",
            .input = std.Io.Timestamp.fromNanoseconds(1776688496 * std.time.ns_per_s),
            .expected = "2026-04-20T12:34:56Z [INFO] msg\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .fixed_timestamp = tc.input,
        });

        try logger.info("msg", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

// --- Logger.log ---

test "Logger.log: level filtering, passes" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { min_level: std.log.Level, msg_level: std.log.Level },
        expected: []const u8,
    }{
        .{
            .name = "err:err",
            .input = .{ .min_level = .err, .msg_level = .err },
            .expected = "1970-01-01T00:00:00Z [ERROR] msg\n",
        },
        .{
            .name = "warn:err",
            .input = .{ .min_level = .warn, .msg_level = .err },
            .expected = "1970-01-01T00:00:00Z [ERROR] msg\n",
        },
        .{
            .name = "warn:warn",
            .input = .{ .min_level = .warn, .msg_level = .warn },
            .expected = "1970-01-01T00:00:00Z [WARN] msg\n",
        },
        .{
            .name = "info:err",
            .input = .{ .min_level = .info, .msg_level = .err },
            .expected = "1970-01-01T00:00:00Z [ERROR] msg\n",
        },
        .{
            .name = "info:warn",
            .input = .{ .min_level = .info, .msg_level = .warn },
            .expected = "1970-01-01T00:00:00Z [WARN] msg\n",
        },
        .{
            .name = "info:info",
            .input = .{ .min_level = .info, .msg_level = .info },
            .expected = "1970-01-01T00:00:00Z [INFO] msg\n",
        },
        .{
            .name = "debug:err",
            .input = .{ .min_level = .debug, .msg_level = .err },
            .expected = "1970-01-01T00:00:00Z [ERROR] msg\n",
        },
        .{
            .name = "debug:warn",
            .input = .{ .min_level = .debug, .msg_level = .warn },
            .expected = "1970-01-01T00:00:00Z [WARN] msg\n",
        },
        .{
            .name = "debug:info",
            .input = .{ .min_level = .debug, .msg_level = .info },
            .expected = "1970-01-01T00:00:00Z [INFO] msg\n",
        },
        .{
            .name = "debug:debug",
            .input = .{ .min_level = .debug, .msg_level = .debug },
            .expected = "1970-01-01T00:00:00Z [DEBUG] msg\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .level = tc.input.min_level,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.log(tc.input.msg_level, "msg", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.log: level filtering, filtered" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { min_level: std.log.Level, msg_level: std.log.Level },
    }{
        .{ .name = "err:warn", .input = .{ .min_level = .err, .msg_level = .warn } },
        .{ .name = "err:info", .input = .{ .min_level = .err, .msg_level = .info } },
        .{ .name = "err:debug", .input = .{ .min_level = .err, .msg_level = .debug } },
        .{ .name = "warn:info", .input = .{ .min_level = .warn, .msg_level = .info } },
        .{ .name = "warn:debug", .input = .{ .min_level = .warn, .msg_level = .debug } },
        .{ .name = "info:debug", .input = .{ .min_level = .info, .msg_level = .debug } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .level = tc.input.min_level,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.log(tc.input.msg_level, "msg", .{});

        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}

test "Logger.log: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger.init(std.testing.io, &writer, .{
        .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
    });

    try std.testing.expectError(error.WriteFailed, logger.log(.info, "msg", .{}));
}

test "Logger.log: JSON format level labels" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.log.Level,
        expected: []const u8,
    }{
        .{
            .name = "err",
            .input = .err,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"error\",\"msg\":\"msg\"}\n",
        },
        .{
            .name = "warn",
            .input = .warn,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"warn\",\"msg\":\"msg\"}\n",
        },
        .{
            .name = "info",
            .input = .info,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"msg\":\"msg\"}\n",
        },
        .{
            .name = "debug",
            .input = .debug,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"debug\",\"msg\":\"msg\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .level = tc.input,
            .format = .json,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.log(tc.input, "msg", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

// --- Logger.err ---

test "Logger.err" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [ERROR] something failed\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"error\"," ++
                "\"msg\":\"something failed\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .level = .err,
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.err("something failed", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.err: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger.init(std.testing.io, &writer, .{
        .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
    });

    try std.testing.expectError(error.WriteFailed, logger.err("msg", .{}));
}

// --- Logger.warn ---

test "Logger.warn" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [WARN] disk full\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"warn\"," ++
                "\"msg\":\"disk full\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .level = .warn,
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.warn("disk full", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.warn: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger.init(std.testing.io, &writer, .{
        .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
    });

    try std.testing.expectError(error.WriteFailed, logger.warn("msg", .{}));
}

// --- Logger.info ---

test "Logger.info: no attrs" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO] server started\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"server started\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("server started", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: int attr" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO] server started port=8080\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"server started\",\"port\":8080}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("server started", .{ .port = 8080 });

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: string attr" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO] user logged in ip=\"127.0.0.1\"\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"user logged in\",\"ip\":\"127.0.0.1\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("user logged in", .{ .ip = "127.0.0.1" });

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: bool attr" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO] server started enabled=true\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"server started\",\"enabled\":true}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("server started", .{ .enabled = true });

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: multiple attrs" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO] user logged in user_id=42 ip=\"127.0.0.1\"\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"msg\":\"user logged in\",\"user_id\":42,\"ip\":\"127.0.0.1\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: with scope" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO] [database] server started port=8080\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\"," ++
                "\"scope\":\"database\",\"msg\":\"server started\",\"port\":8080}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .scope = "database",
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("server started", .{ .port = 8080 });

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: empty message" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [INFO]\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"msg\":\"\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.info("", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.info: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger.init(std.testing.io, &writer, .{
        .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
    });

    try std.testing.expectError(error.WriteFailed, logger.info("msg", .{}));
}

// --- Logger.debug ---

test "Logger.debug" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Logger.Format,
        expected: []const u8,
    }{
        .{
            .name = "text format",
            .input = .text,
            .expected = "1970-01-01T00:00:00Z [DEBUG] verbose info\n",
        },
        .{
            .name = "JSON format",
            .input = .json,
            .expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"debug\"," ++
                "\"msg\":\"verbose info\"}\n",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, .{
            .level = .debug,
            .format = tc.input,
            .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
        });

        try logger.debug("verbose info", .{});

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "Logger.debug: write fails" {
    var writer = std.Io.Writer.failing;
    const logger = Logger.init(std.testing.io, &writer, .{
        .level = .debug,
        .fixed_timestamp = std.Io.Timestamp.fromNanoseconds(0),
    });

    try std.testing.expectError(error.WriteFailed, logger.debug("msg", .{}));
}

// --- writeQuotedString ---

test "writeQuotedString: escaping" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "plain string", .input = "hello", .expected = "\"hello\"" },
        .{ .name = "empty string", .input = "", .expected = "\"\"" },
        .{ .name = "double quote", .input = "say \"hi\"", .expected = "\"say \\\"hi\\\"\"" },
        .{ .name = "backslash", .input = "a\\b", .expected = "\"a\\\\b\"" },
        .{ .name = "newline", .input = "a\nb", .expected = "\"a\\nb\"" },
        .{ .name = "carriage return", .input = "a\rb", .expected = "\"a\\rb\"" },
        .{ .name = "tab", .input = "a\tb", .expected = "\"a\\tb\"" },
        .{ .name = "control char NUL", .input = "\x00", .expected = "\"\\u0000\"" },
        .{ .name = "control char SOH", .input = "\x01", .expected = "\"\\u0001\"" },
        .{ .name = "control char BS (0x08)", .input = "\x08", .expected = "\"\\u0008\"" },
        .{ .name = "form feed", .input = "\x0C", .expected = "\"\\u000c\"" },
        .{ .name = "vertical tab", .input = "\x0B", .expected = "\"\\u000b\"" },
        .{ .name = "control char SO (0x0E)", .input = "\x0E", .expected = "\"\\u000e\"" },
        .{ .name = "unit separator", .input = "\x1F", .expected = "\"\\u001f\"" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeQuotedString(&writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeQuotedString: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeQuotedString(&writer, "test"),
    );
}

// --- writeTimestamp ---

test "writeTimestamp" {
    const test_cases = [_]struct {
        name: []const u8,
        input: std.Io.Timestamp,
        expected: []const u8,
    }{
        .{
            .name = "epoch",
            .input = std.Io.Timestamp.fromNanoseconds(0),
            .expected = "1970-01-01T00:00:00Z",
        },
        .{
            .name = "2026-04-20T12:34:56Z",
            .input = std.Io.Timestamp.fromNanoseconds(1776688496 * std.time.ns_per_s),
            .expected = "2026-04-20T12:34:56Z",
        },
        .{
            .name = "sub-second truncation",
            .input = std.Io.Timestamp.fromNanoseconds(1_500_000_000),
            .expected = "1970-01-01T00:00:01Z",
        },
        .{
            .name = "year-end (2023-12-31T23:59:59Z)",
            .input = std.Io.Timestamp.fromNanoseconds(1704067199 * std.time.ns_per_s),
            .expected = "2023-12-31T23:59:59Z",
        },
        .{
            .name = "leap year Feb 29 (2024-02-29T00:00:00Z)",
            .input = std.Io.Timestamp.fromNanoseconds(1709164800 * std.time.ns_per_s),
            .expected = "2024-02-29T00:00:00Z",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        var buf: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        try writeTimestamp(&writer, tc.input);

        try std.testing.expectEqualStrings(tc.expected, buf[0..writer.end]);
    }
}

test "writeTimestamp: write fails" {
    var writer = std.Io.Writer.failing;

    try std.testing.expectError(
        error.WriteFailed,
        writeTimestamp(&writer, std.Io.Timestamp.fromNanoseconds(0)),
    );
}

// --- isStringLike ---

test "isStringLike" {
    // input が type（コンパイル時専用型）のため [_]struct + for では扱えず、comptime タプル + inline for を使用する
    const test_cases = .{
        .{ .name = "[]const u8", .input = []const u8, .expected = true },
        .{ .name = "[]u8", .input = []u8, .expected = true },
        .{ .name = "*const [3]u8", .input = *const [3]u8, .expected = true },
        .{ .name = "*[3]u8", .input = *[3]u8, .expected = true },
        .{ .name = "u32", .input = u32, .expected = false },
        .{ .name = "*u8", .input = *u8, .expected = false },
        .{ .name = "[*]u8", .input = [*]u8, .expected = false },
        .{ .name = "[*c]u8", .input = [*c]u8, .expected = false },
    };

    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isStringLike(tc.input));
    }
}
