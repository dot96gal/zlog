const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file_writer.interface;

    // テキスト形式（デフォルト）
    const logger = zlog.Logger.init(io, stdout, .debug);

    try logger.info("server started", .{ .port = 8080 });
    try logger.warn("disk usage high", .{ .percent = 85 });
    try logger.err("connection failed", .{ .host = "db.example.com" });
    try logger.debug("request received", .{ .method = "GET", .path = "/api/v1/users" });

    // スコープ付きロガー
    const db_logger = logger.withLoggerName("database");
    try db_logger.info("query executed", .{ .duration_ms = 42 });

    // JSON 形式
    const json_logger = logger.withFormat(.json);
    try json_logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });
}
