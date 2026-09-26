const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const chatfilter = main.server.chatfilter;

pub const description = "List active bans (admin).";
pub const usage = "/bans";

pub const Args = union(enum) {
	@"/bans": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (!source.hasPermission("/ashframe/admin/bans")) {
		source.sendMessage("#e6312cYou do not have permission to list bans.", .{});
		return;
	}
	var msg: main.ListManaged(u8) = .init(main.stackAllocator);
	defer msg.deinit();
	msg.appendSlice("#f2f2f2--- Bans ---\n");
	chatfilter.appendBanList(&msg);
	source.sendMessage("{s}", .{msg.items});
}
