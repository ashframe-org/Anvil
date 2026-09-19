const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "List online players.";
pub const usage = "/players";

pub const Args = union(enum) {
	@"/players": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);

	if (userList.len == 0) {
		source.sendMessage("#cfcfcfThere are no players online.", .{});
		return;
	}

	source.sendMessage("#f2f2f2--- Online Players ({d}) ---", .{userList.len});
	for (userList) |user| {
		source.sendMessage("#cfcfcf- #e6312c{s} #8a8a8a(@{d})", .{user.name, user.playerIndex});
	}
}
