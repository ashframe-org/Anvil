const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const chatfilter = main.server.chatfilter;
const veterans = main.server.veterans;

pub const description = "Unban a player (admin). Also resets their strike counter.";
pub const usage = "/unban <name>";

pub const Args = union(enum) {
	@"/unban <name>": struct { name: []const u8 },
};

/// Zeroes strikes in offline player files matching `cleanedName`, so an
/// unbanned player doesn't rejoin one slur away from a re-ban. Strikes persist
/// in `saves/<world>/players/<index>.zon`; removing the ban entry alone would
/// leave them behind.
fn resetOfflineStrikes(cleanedName: []const u8) void {
	const world = main.server.world orelse return;
	const dirPath = main.stackAllocator.print("saves/{s}/players", .{world.path});
	defer main.stackAllocator.free(dirPath);
	var playerDir = main.files.cubyzDir().openIterableDir(dirPath) catch return;
	defer playerDir.close();
	var iterator = playerDir.iterate();
	while (iterator.next(main.io) catch return) |file| {
		if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".zon")) continue;
		var zon = playerDir.readToZon(main.stackAllocator, file.name) catch continue;
		defer zon.deinit(main.stackAllocator);
		const storedName = zon.get([]const u8, "name") orelse continue;
		if (!veterans.rosterMatch(storedName, cleanedName)) continue;
		const strikes = zon.get(u8, "strikes") orelse continue;
		if (strikes == 0) continue;
		if (zon.removeChild("strikes")) |removed| {
			var r = removed;
			defer r.deinit(main.stackAllocator);
		}
		playerDir.writeZon(file.name, zon) catch |err| {
			std.log.err("Could not reset strikes in player file {s}: {s}", .{ file.name, @errorName(err) });
			continue;
		};
		std.log.info("Reset strikes for unbanned player {s} ({s})", .{ storedName, file.name });
	}
}

pub fn execute(args: Args, source: Source) void {
	if (!source.hasPermission("/ashframe/admin/unban")) {
		source.sendMessage("#e6312cYou do not have permission to unban players.", .{});
		return;
	}
	const name = args.@"/unban <name>".name;
	if (!chatfilter.unban(name)) {
		source.sendMessage("#e6312cNo ban found for '#cfcfcf{s}#e6312c'.", .{name});
		return;
	}
	// An unban wipes the strike counter too — otherwise the player rejoins at
	// 2/3 and a single slur re-bans them instantly.
	var cleaned = main.ListManaged(u8).init(main.stackAllocator);
	defer cleaned.deinit();
	veterans.appendCleaned(&cleaned, name);
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |u| {
		if (veterans.rosterMatch(u.name, cleaned.items)) u.player().strikes = 0;
	}
	resetOfflineStrikes(cleaned.items);
	chatfilter.saveCurrentWorld();
	source.sendMessage("#00ff00Unbanned #cfcfcf{s}#00ff00 (strikes reset).", .{name});
}
