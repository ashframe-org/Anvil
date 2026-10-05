const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const ashutil = @import("ashutil.zig");

pub const description = "Clear a player's chat-filter strikes (admin). Works live, no restart needed.";
pub const usage = "/unstrike <name|@playerIndex>";

pub const Args = union(enum) {
	@"/unstrike <target>": struct { target: []const u8 },
};

pub fn execute(args: Args, source: Source) void {
	if (!source.hasPermission("/ashframe/admin/unban")) {
		source.sendMessage("#e6312cYou do not have permission to clear strikes.", .{});
		return;
	}
	const target = ashutil.findTargetByNameOrIndex(args.@"/unstrike <target>".target) orelse {
		source.sendMessage("#e6312cPlayer '#cfcfcf{s}#e6312c' not found or offline.", .{args.@"/unstrike <target>".target});
		return;
	};
	target.player().strikes = 0;
	source.sendMessage("#00ff00Cleared strikes for #cfcfcf{s}#00ff00.", .{target.name});
}
