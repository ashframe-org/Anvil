const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const ashutil = @import("ashutil.zig");

pub const description = "Send a private message to another player.";
pub const usage = "/msg <player> <message>";

pub const Args = union(enum) {
	@"/msg <target> <message>": struct {target: []const u8, message: command.RestOfLine},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const params = args.@"/msg <target> <message>";

	const target = ashutil.findTargetByNameOrIndex(params.target) orelse {
		source.sendMessage("#e6312cPlayer '#cfcfcf{s}#e6312c' not found or offline.", .{params.target});
		return;
	};

	if (target.playerIndex == user.playerIndex) {
		source.sendMessage("#e6312cYou cannot message yourself!", .{});
		return;
	}

	// Private messages go through the same slur filter as public chat;
	// otherwise PMs become a consequence-free channel around the ban system.
	if (main.server.chatfilter.findBad(params.message.text) != null) {
		_ = main.server.chatfilter.strike(user);
		return;
	}

	source.sendMessage("#8a8a8a[you -> #e6312c{s}#8a8a8a] #cfcfcf{s}", .{target.name, params.message.text});
	target.sendMessage("#8a8a8a[#e6312c{s}#8a8a8a -> you] #cfcfcf{s}", .{user.name, params.message.text});
}
