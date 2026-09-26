const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const titles = main.server.titles;

pub const description = "List all titles and which ones you've unlocked.";
pub const usage = "/titles";

pub const Args = union(enum) {
	@"/titles": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const prof = source.user.player();

	var msg: main.ListManaged(u8) = .init(main.stackAllocator);
	defer msg.deinit();
	msg.appendSlice("#f2f2f2--- Titles ---\n");

	for (titles.all, 0..) |title, i| {
		if (i != 0) msg.appendSlice(" ");
		const unlocked = titles.isUnlocked(prof, i);
		if (title.secret and !unlocked) {
			msg.appendSlice("#9a9a9a[Secret]");
		} else if (unlocked) {
			const wearing = prof.active_title != null and prof.active_title.? == @as(u8, @intCast(i));
			msg.appendSlice(if (wearing) "#00ff00[" else "#e6e6e6[");
			msg.appendSlice(title.display);
			msg.appendSlice("]");
			if (titles.isSeasonTitle(i)) msg.appendSlice("#8a8a8a(auto)");
		} else {
			msg.appendSlice("#9a9a9a[");
			msg.appendSlice(title.display);
			msg.appendSlice("]");
		}
	}
	source.sendMessage("{s}", .{msg.items});
}
