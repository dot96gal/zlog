const std = @import("std");

/// ログ出力時に発生しうるエラー集合。
pub const Error = error{
    /// 出力先への書き込みに失敗した。
    WriteFailed,
};

/// ログの出力フォーマットを表す列挙型。`Logger.withFormat` でフォーマットを切り替えるために利用する。
pub const Format = enum {
    /// テキスト形式のログ。
    text,
    /// JSON オブジェクト形式のログ。
    json,
};

/// 構造化ログを出力するロガーの構造体。`Logger.init` で生成し、`with*` メソッドで設定を変えた新しい Logger を作るために利用する。
pub const Logger = struct {
    /// 内部フィールド。直接アクセスしないこと。
    io: std.Io,
    /// 内部フィールド。直接アクセスしないこと。
    writer: *std.Io.Writer,
    /// 内部フィールド。直接アクセスしないこと。
    level: std.log.Level,
    /// 内部フィールド。直接アクセスしないこと。
    format: Format,
    /// 内部フィールド。直接アクセスしないこと。
    logger_name: ?[]const u8,
    /// 内部フィールド。直接アクセスしないこと。
    fixed_timestamp: ?std.Io.Timestamp,

    /// Logger を生成する関数。出力先・ログレベルを設定するために利用する。
    /// フォーマットはデフォルトでテキスト形式。
    pub fn init(io: std.Io, writer: *std.Io.Writer, level: std.log.Level) Logger {
        return .{
            .io = io,
            .writer = writer,
            .level = level,
            .format = .text,
            .logger_name = null,
            .fixed_timestamp = null,
        };
    }

    /// 出力先の Writer を変更した新しい Logger を返す関数。出力先を切り替えるために利用する。
    pub fn withWriter(self: Logger, writer: *std.Io.Writer) Logger {
        var l = self;
        l.writer = writer;
        return l;
    }

    /// ログレベルを変更した新しい Logger を返す関数。出力するログの最小レベルを切り替えるために利用する。
    pub fn withLevel(self: Logger, level: std.log.Level) Logger {
        var l = self;
        l.level = level;
        return l;
    }

    /// 出力フォーマットを変更した新しい Logger を返す関数。テキストと JSON を切り替えるために利用する。
    pub fn withFormat(self: Logger, format: Format) Logger {
        var l = self;
        l.format = format;
        return l;
    }

    /// ロガー名を設定した新しい Logger を返す関数。コンポーネントやモジュール名を付与してログを区別するために利用する。
    pub fn withLoggerName(self: Logger, name: []const u8) Logger {
        var l = self;
        l.logger_name = name;
        return l;
    }

    /// 固定タイムスタンプを設定した新しい Logger を返す関数。テスト時に出力を決定論的にするために利用する。
    pub fn withTimestamp(self: Logger, ts: std.Io.Timestamp) Logger {
        var l = self;
        l.fixed_timestamp = ts;
        return l;
    }

    /// エラーレベルのログを出力する関数。回復不能なエラーを記録するために利用する。
    pub fn err(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.err, msg, attrs);
    }

    /// 警告レベルのログを出力する関数。注意が必要な状態を記録するために利用する。
    pub fn warn(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.warn, msg, attrs);
    }

    /// 情報レベルのログを出力する関数。通常の動作状態を記録するために利用する。
    pub fn info(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.info, msg, attrs);
    }

    /// デバッグレベルのログを出力する関数。開発時の詳細情報を記録するために利用する。
    pub fn debug(self: Logger, comptime msg: []const u8, attrs: anytype) Error!void {
        try self.log(.debug, msg, attrs);
    }

    fn log(self: Logger, msg_level: std.log.Level, comptime msg: []const u8, attrs: anytype) !void {
        if (@intFromEnum(msg_level) > @intFromEnum(self.level)) return;

        const ts = if (self.fixed_timestamp) |fts| fts else std.Io.Timestamp.now(self.io, .real);

        switch (self.format) {
            .text => try writeText(self.writer, msg_level, ts, self.logger_name, msg, attrs),
            .json => try writeJson(self.writer, msg_level, ts, self.logger_name, msg, attrs),
        }

        try self.writer.flush();
    }
};

fn writeText(
    writer: *std.Io.Writer,
    level: std.log.Level,
    ts: std.Io.Timestamp,
    logger_name: ?[]const u8,
    comptime msg: []const u8,
    attrs: anytype,
) !void {
    try writeTimestamp(writer, ts);

    const levelStr = switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
    try writer.print(" [{s}]", .{levelStr});

    if (logger_name) |name| {
        try writer.print(" [{s}]", .{name});
    }

    try writer.print(" {s}", .{msg});

    inline for (std.meta.fields(@TypeOf(attrs))) |field| {
        const value = @field(attrs, field.name);
        if (comptime isStringLike(@TypeOf(value))) {
            try writer.print(" {s}=\"{s}\"", .{ field.name, value });
        } else {
            try writer.print(" {s}={}", .{ field.name, value });
        }
    }

    try writer.writeByte('\n');
}

fn writeJson(
    writer: *std.Io.Writer,
    level: std.log.Level,
    ts: std.Io.Timestamp,
    logger_name: ?[]const u8,
    comptime msg: []const u8,
    attrs: anytype,
) !void {
    try writer.writeAll("{\"time\":\"");
    try writeTimestamp(writer, ts);
    try writer.writeByte('"');

    const levelStr = switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
    try writer.print(",\"level\":\"{s}\"", .{levelStr});

    if (logger_name) |name| {
        try writer.print(",\"logger\":\"{s}\"", .{name});
    }

    try writer.print(",\"msg\":\"{s}\"", .{msg});

    inline for (std.meta.fields(@TypeOf(attrs))) |field| {
        const value = @field(attrs, field.name);
        if (comptime isStringLike(@TypeOf(value))) {
            try writer.print(",\"{s}\":\"{s}\"", .{ field.name, value });
        } else {
            try writer.print(",\"{s}\":{}", .{ field.name, value });
        }
    }

    try writer.writeAll("}\n");
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

const DateComponents = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn unixSecondsToDate(seconds: i64) DateComponents {
    const secsPerDay: i64 = 86400;
    var days: i64 = @divFloor(seconds, secsPerDay);
    const timeOfDay: i64 = @mod(seconds, secsPerDay);

    const hour: u8 = @intCast(@divFloor(timeOfDay, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(timeOfDay, 3600), 60));
    const second: u8 = @intCast(@mod(timeOfDay, 60));

    // Howard Hinnant's civil_from_days algorithm
    days += 719468;
    const era: i64 = @divFloor(days, 146097);
    const doe: i64 = days - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    y += if (m <= 2) 1 else 0;

    return .{
        .year = @intCast(y),
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn writeTimestamp(writer: *std.Io.Writer, ts: std.Io.Timestamp) !void {
    const seconds: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    const dc = unixSecondsToDate(seconds);
    try writer.print("{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}Z", .{
        @as(u32, @intCast(dc.year)), dc.month, dc.day, dc.hour, dc.minute, dc.second,
    });
}

test "unixSecondsToDate: epoch" {
    const dc = unixSecondsToDate(0);
    try std.testing.expectEqual(@as(i32, 1970), dc.year);
    try std.testing.expectEqual(@as(u8, 1), dc.month);
    try std.testing.expectEqual(@as(u8, 1), dc.day);
    try std.testing.expectEqual(@as(u8, 0), dc.hour);
    try std.testing.expectEqual(@as(u8, 0), dc.minute);
    try std.testing.expectEqual(@as(u8, 0), dc.second);
}

test "unixSecondsToDate: 2026-04-20T12:34:56Z" {
    // 2026-04-20T12:34:56Z = 1776688496 Unix seconds
    const dc = unixSecondsToDate(1776688496);
    try std.testing.expectEqual(@as(i32, 2026), dc.year);
    try std.testing.expectEqual(@as(u8, 4), dc.month);
    try std.testing.expectEqual(@as(u8, 20), dc.day);
    try std.testing.expectEqual(@as(u8, 12), dc.hour);
    try std.testing.expectEqual(@as(u8, 34), dc.minute);
    try std.testing.expectEqual(@as(u8, 56), dc.second);
}

test "writeTimestamp: epoch" {
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTimestamp(&writer, std.Io.Timestamp.fromNanoseconds(0));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", buf[0..writer.end]);
}

test "Logger.info: text format, no attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.info("server started", .{});
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] server started\n",
        buf[0..writer.end],
    );
}

test "Logger.info: text format, int attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.info("server started", .{ .port = 8080 });
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] server started port=8080\n",
        buf[0..writer.end],
    );
}

test "Logger.info: text format, string attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.info("user logged in", .{ .ip = "127.0.0.1" });
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] user logged in ip=\"127.0.0.1\"\n",
        buf[0..writer.end],
    );
}

test "Logger.info: text format, multiple attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] user logged in user_id=42 ip=\"127.0.0.1\"\n",
        buf[0..writer.end],
    );
}

test "Logger.err: text format" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .err)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.err("something failed", .{});
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [ERROR] something failed\n",
        buf[0..writer.end],
    );
}

test "Logger.warn: text format" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .warn)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.warn("disk full", .{});
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [WARN] disk full\n",
        buf[0..writer.end],
    );
}

test "Logger.debug: text format" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .debug)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
    try logger.debug("verbose info", .{});
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [DEBUG] verbose info\n",
        buf[0..writer.end],
    );
}

test "Logger: level filtering" {
    const Case = struct {
        min_level: std.log.Level,
        msg_level: std.log.Level,
        should_output: bool,
    };
    const cases = [_]Case{
        // min_level=err: err のみ出力
        .{ .min_level = .err, .msg_level = .err, .should_output = true },
        .{ .min_level = .err, .msg_level = .warn, .should_output = false },
        .{ .min_level = .err, .msg_level = .info, .should_output = false },
        .{ .min_level = .err, .msg_level = .debug, .should_output = false },
        // min_level=warn: err・warn を出力
        .{ .min_level = .warn, .msg_level = .err, .should_output = true },
        .{ .min_level = .warn, .msg_level = .warn, .should_output = true },
        .{ .min_level = .warn, .msg_level = .info, .should_output = false },
        .{ .min_level = .warn, .msg_level = .debug, .should_output = false },
        // min_level=info: err・warn・info を出力
        .{ .min_level = .info, .msg_level = .err, .should_output = true },
        .{ .min_level = .info, .msg_level = .warn, .should_output = true },
        .{ .min_level = .info, .msg_level = .info, .should_output = true },
        .{ .min_level = .info, .msg_level = .debug, .should_output = false },
        // min_level=debug: すべて出力
        .{ .min_level = .debug, .msg_level = .err, .should_output = true },
        .{ .min_level = .debug, .msg_level = .warn, .should_output = true },
        .{ .min_level = .debug, .msg_level = .info, .should_output = true },
        .{ .min_level = .debug, .msg_level = .debug, .should_output = true },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, c.min_level)
            .withTimestamp(std.Io.Timestamp.fromNanoseconds(0));
        switch (c.msg_level) {
            .err => try logger.err("msg", .{}),
            .warn => try logger.warn("msg", .{}),
            .info => try logger.info("msg", .{}),
            .debug => try logger.debug("msg", .{}),
        }
        if (c.should_output) {
            try std.testing.expect(writer.end > 0);
        } else {
            try std.testing.expectEqual(@as(usize, 0), writer.end);
        }
    }
}

test "Logger.info: text format, with logger name" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withLoggerName("database");
    try logger.info("server started", .{ .port = 8080 });
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] [database] server started port=8080\n",
        buf[0..writer.end],
    );
}

test "Logger.info: JSON format, no attrs" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withFormat(.json);
    try logger.info("server started", .{});
    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"msg\":\"server started\"}\n",
        buf[0..writer.end],
    );
}

test "Logger.info: JSON format, int attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withFormat(.json);
    try logger.info("server started", .{ .port = 8080 });
    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"msg\":\"server started\",\"port\":8080}\n",
        buf[0..writer.end],
    );
}

test "Logger.info: JSON format, string attr" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withFormat(.json);
    try logger.info("user logged in", .{ .ip = "127.0.0.1" });
    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"msg\":\"user logged in\",\"ip\":\"127.0.0.1\"}\n",
        buf[0..writer.end],
    );
}

test "Logger.info: JSON format, with logger name" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withFormat(.json)
        .withLoggerName("database");
    try logger.info("server started", .{ .port = 8080 });
    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"logger\":\"database\",\"msg\":\"server started\",\"port\":8080}\n",
        buf[0..writer.end],
    );
}

test "Logger.withWriter: output redirected" {
    var buf1: [256]u8 = undefined;
    var writer1 = std.Io.Writer.fixed(&buf1);
    var buf2: [256]u8 = undefined;
    var writer2 = std.Io.Writer.fixed(&buf2);
    const logger = Logger.init(std.testing.io, &writer1, .info)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withWriter(&writer2);
    try logger.info("redirected", .{});
    try std.testing.expectEqual(@as(usize, 0), writer1.end);
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [INFO] redirected\n",
        buf2[0..writer2.end],
    );
}

test "Logger: JSON format level labels" {
    const cases = .{
        .{ .level = std.log.Level.err, .label = "error" },
        .{ .level = std.log.Level.warn, .label = "warn" },
        .{ .level = std.log.Level.debug, .label = "debug" },
    };
    inline for (cases) |c| {
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const logger = Logger.init(std.testing.io, &writer, c.level)
            .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
            .withFormat(.json);
        switch (c.level) {
            .err => try logger.err("msg", .{}),
            .warn => try logger.warn("msg", .{}),
            .debug => try logger.debug("msg", .{}),
            else => unreachable,
        }
        const expected = "{\"time\":\"1970-01-01T00:00:00Z\",\"level\":\"" ++ c.label ++ "\",\"msg\":\"msg\"}\n";
        try std.testing.expectEqualStrings(expected, buf[0..writer.end]);
    }
}

test "Logger.withLevel: level change" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(std.testing.io, &writer, .warn)
        .withTimestamp(std.Io.Timestamp.fromNanoseconds(0))
        .withLevel(.debug);
    try logger.debug("now visible", .{});
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z [DEBUG] now visible\n",
        buf[0..writer.end],
    );
}
