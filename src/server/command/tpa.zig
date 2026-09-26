const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const ashutil = @import("ashutil.zig");

pub const description = "Request to teleport to another player. Costs 1 Amber Orb on accept.";
pub const usage = "/tpa <player>";

pub const Args = union(enum) {
	@"/tpa <target>": struct {target: []const u8},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const targetStr = args.@"/tpa <target>".target;

	const target = ashutil.findTargetByNameOrIndex(targetStr) orelse {
		source.sendMessage("#e6312cPlayer '#cfcfcf{s}#e6312c' not found or offline.", .{targetStr});
		return;
	};

	if (target.playerIndex == user.playerIndex) {
		source.sendMessage("#e6312cYou cannot teleport to yourself!", .{});
		return;
	}

	ashutil.sendTpaRequest(user, target);
}
