const std = @import("std");

const loggerMod = @import("logger.zig");

pub const Logger = loggerMod.Logger;
pub const Format = loggerMod.Format;
pub const Error = loggerMod.Error;

test {
    _ = loggerMod;
}
