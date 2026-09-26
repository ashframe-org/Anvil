const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const ashutil = @import("ashutil.zig");

pub const description = "Set your home here. First time costs 20 Orbs; moving it after is free.";
pub const usage = "/sethome";

const unlockCost: u16 = 20;

pub const Args = union(enum) {
	@"/sethome": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const prof = user.player();
	if (!prof.homeUnlocked) {
		// First use: charge once, unlock, and set the home to where you stand.
		if (!ashutil.chargeOrbs(user, source, unlockCost)) return;
		prof.homeUnlocked = true;
		prof.home_pos = prof.pos;
		source.sendMessage("#00ff00Home established! #cfcfcf(-{d} Orbs, one time.) Use #e6312c/sethome#cfcfcf to move it for free later.", .{unlockCost});
		return;
	}
	prof.home_pos = prof.pos;
	source.sendMessage("#cfcfcfHome moved to your current position!", .{});
}
