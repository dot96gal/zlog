const std = @import("std");

const logger_mod = @import("logger.zig");

pub const Logger = logger_mod.Logger;
pub const DefaultLogger = logger_mod.DefaultLogger;
pub const Error = logger_mod.Error;
pub const Format = logger_mod.Format;
pub const Options = logger_mod.Options;

test {
    _ = logger_mod;
}
