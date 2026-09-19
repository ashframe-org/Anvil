const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Teleport back to your previous location.";
pub const usage = "/back";

pub const Args = union(enum) {
	@"/back": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	const prof = user.player();

	const target_pos = prof.back_pos orelse {
		source.sendMessage("#e6312cYou do not have a previous location to return to.", .{});
		return;
	};

	main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, target_pos);
	source.sendMessage("#cfcfcfTeleported back to your previous location.", .{});

	prof.back_pos = null;
}
