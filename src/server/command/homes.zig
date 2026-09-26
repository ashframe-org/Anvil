const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Show your saved home location.";
pub const usage = "/homes";

pub const Args = union(enum) {
	@"/homes": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const prof = source.user.player();
	if (prof.home_pos) |hp| {
		source.sendMessage("#cfcfcfHome: #e6312c{d}, {d}, {d}", .{ @as(i32, @intFromFloat(hp[0])), @as(i32, @intFromFloat(hp[1])), @as(i32, @intFromFloat(hp[2])) });
	} else {
		source.sendMessage("#8a8a8aNo home set. #b8221e(Use /sethome to save one)", .{});
	}
}
