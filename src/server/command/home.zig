const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const ashutil = @import("ashutil.zig");

pub const description = "Teleport to your saved home location. Free.";
pub const usage = "/home";

pub const Args = union(enum) {
	@"/home": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const dest = user.player().home_pos orelse {
		source.sendMessage("#e6312cYou do not have a home set yet. #b8221e(Use /sethome to save one)", .{});
		return;
	};
	ashutil.teleportTo(user, dest);
	source.sendMessage("#cfcfcfTeleporting to your home...", .{});
}
