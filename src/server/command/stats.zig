const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Show your personal stats.";
pub const usage = "/stats";

pub const Args = union(enum) {
	@"/stats": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const prof = source.user.player();
	const cur: i64 = @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
	const session: u64 = @intCast(if (cur > prof.login_time) cur - prof.login_time else 0);
	const totalPlaytime = prof.playtime + session;

	var msg: main.ListManaged(u8) = .init(main.stackAllocator);
	defer msg.deinit();
	msg.appendSlice("#f2f2f2--- Your stats ---\n");
	msg.print("#cfcfcfPlaytime: #e6312c{}h {}m #8a8a8a({} distinct days)\n", .{ totalPlaytime/3600, (totalPlaytime%3600)/60, prof.days_played });
	msg.print("#cfcfcfBlocks: #e6312c{} #8a8a8amined / #e6312c{} #8a8a8aplaced\n", .{ prof.blocksMined, prof.blocksPlaced });
	if (prof.distance_travelled >= 1000) {
		msg.print("#cfcfcfDistance traveled: #e6312c{d:.1} km\n", .{prof.distance_travelled/1000});
	} else {
		msg.print("#cfcfcfDistance traveled: #e6312c{d:.0} m\n", .{prof.distance_travelled});
	}
	if (prof.min_y) |minY| {
		msg.print("#cfcfcfDeepest depth: #e6312cy {d:.0}\n", .{minY});
	} else {
		msg.appendSlice("#cfcfcfDeepest depth: #8a8a8a—\n");
	}
	msg.print("#cfcfcfChat messages: #e6312c{} #8a8a8a· Apples eaten: #e6312c{} #8a8a8a· Shop trades: #e6312c{}", .{ prof.messages_sent, prof.apples_eaten, prof.shopTrades });
	source.sendMessage("{s}", .{msg.items});
}
