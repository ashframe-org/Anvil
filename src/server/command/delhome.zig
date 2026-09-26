const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Delete your saved home.";
pub const usage = "/delhome";

pub const Args = union(enum) {
	@"/delhome": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const prof = source.user.player();
	if (prof.home_pos == null) {
		source.sendMessage("#e6312cYou do not have a home set.", .{});
	} else {
		prof.home_pos = null;
		source.sendMessage("#cfcfcfYour home has been removed.", .{});
	}
}
