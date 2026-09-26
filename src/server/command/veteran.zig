const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const veterans = main.server.veterans;
const ashutil = @import("ashutil.zig");

pub const description = "(Admin) Grant, revoke or review season veteran badges.";
pub const usage =
	\\/veteran grant <player> <season>
	\\/veteran revoke <player> <season>
	\\/veteran name <name> <season>
	\\/veteran limbo <name>
	\\/veteran key <player>
	\\/veteran help
;

const Season = enum { s0, s1, s2, s3 };

fn seasonIndex(s: Season) u3 {
	return switch (s) {
		.s0 => 0,
		.s1 => 1,
		.s2 => 2,
		.s3 => 3,
	};
}

// Each variant starts with an enum keyword field; longer forms first.
pub const Args = union(enum) {
	@"/veteran grant <player> <season>": struct { cmd: enum { grant }, player: []const u8, season: Season },
	@"/veteran revoke <player> <season>": struct { cmd: enum { revoke }, player: []const u8, season: Season },
	@"/veteran name <name> <season>": struct { cmd: enum { name }, name: []const u8, season: Season },
	@"/veteran limbo <name>": struct { cmd: enum { limbo }, name: []const u8 },
	@"/veteran key <player>": struct { cmd: enum { key }, player: []const u8 },
	@"/veteran help": struct { cmd: enum { help } },
};

pub fn execute(args: Args, source: Source) void {
	if (!source.hasPermission("/ashframe/admin/veteran")) {
		source.sendMessage("#e6312cYou do not have permission to manage veteran badges.", .{});
		return;
	}
	switch (args) {
		.@"/veteran grant <player> <season>" => |p| {
			const target = ashutil.findTargetByNameOrIndex(p.player) orelse {
				source.sendMessage("#e6312cPlayer '#cfcfcf{s}#e6312c' not found or offline. #8a8a8a(Use /veteran name for offline/keyless accounts.)", .{p.player});
				return;
			};
			const key = target.newKeyString orelse {
				source.sendMessage("#e6312cThat account has no public key. #8a8a8a(Use /veteran name <their name> <season> instead.)", .{});
				return;
			};
			veterans.grantKey(target, key, seasonIndex(p.season));

			source.sendMessage("#00ff00Granted {s} veteran badge to #cfcfcf{s}#00ff00 (key {s}).", .{ @tagName(p.season), target.name, key });
		},
		.@"/veteran revoke <player> <season>" => |p| {
			const target = ashutil.findTargetByNameOrIndex(p.player);
			const key = if (target) |t| t.newKeyString else null;
			const name = if (target) |t| t.name else p.player;
			const changed = veterans.revoke(target, name, key, seasonIndex(p.season));
			if (changed == 0) {
				source.sendMessage("#e6312cNo {s} badge found for '#cfcfcf{s}#e6312c' (roster, live or file).", .{ @tagName(p.season), p.player });
			} else {
				source.sendMessage("#00ff00Revoked {s} badge from #cfcfcf{s}#00ff00 ({d} place(s): roster/live/file).", .{ @tagName(p.season), p.player, changed });
			}
		},
		.@"/veteran name <name> <season>" => |p| {
			// Match an online player by that name so they get it live, else store.
			if (ashutil.findTargetByNameOrIndex(p.name)) |target| {
				veterans.grantName(target, p.name, seasonIndex(p.season));
				source.sendMessage("#00ff00Granted {s} veteran badge to online #cfcfcf{s}#00ff00 (name match).", .{ @tagName(p.season), target.name });
			} else {
				veterans.grantName(null, p.name, seasonIndex(p.season));
				source.sendMessage("#00ff00Stored {s} veteran badge for name #cfcfcf{s}#00ff00. #8a8a8a(Applied on their next join.)", .{ @tagName(p.season), p.name });
			}

		},
		.@"/veteran limbo <name>" => |p| {
			if (veterans.addLimbo(p.name)) {
				source.sendMessage("#00ff00Added #cfcfcf{s}#00ff00 to the verify-with-staff list.", .{p.name});
			} else {
				source.sendMessage("#cfcfcf{s} #e6312cis already on the verify list.", .{p.name});
			}
		},
		.@"/veteran key <player>" => |p| {
			const target = ashutil.findTargetByNameOrIndex(p.player) orelse {
				source.sendMessage("#e6312cPlayer '#cfcfcf{s}#e6312c' not found or offline.", .{p.player});
				return;
			};
			if (target.newKeyString) |key| {
				source.sendMessage("#cfcfcf{s} #8a8a8akey: #e6e6e6{s}", .{ target.name, key });
			} else {
				source.sendMessage("#cfcfcf{s} #e6312chas no public key.", .{target.name});
			}
		},
		.@"/veteran help" => {
			source.sendMessage("#f2f2f2--- /veteran ---", .{});
			var it = std.mem.splitScalar(u8, usage, '\n');
			while (it.next()) |line| source.sendMessage("#cfcfcf{s}", .{line});
		},
	}
}

test "veteran command arg parsing" {
	const P = main.argparse.Parser(Args, .{.commandName = "veteran"});
	const cases = [_]struct { input: []const u8, expected: std.meta.Tag(Args) }{
		.{ .input = "grant bob s0", .expected = .@"/veteran grant <player> <season>" },
		.{ .input = "revoke bob s0", .expected = .@"/veteran revoke <player> <season>" },
		.{ .input = "name Some_Name s3", .expected = .@"/veteran name <name> <season>" },
		.{ .input = "limbo Some_Name", .expected = .@"/veteran limbo <name>" },
		.{ .input = "key bob", .expected = .@"/veteran key <player>" },
		.{ .input = "help", .expected = .@"/veteran help" },
	};
	for (cases) |c| {
		var errors: main.ListManaged(u8) = .init(main.stackAllocator);
		defer errors.deinit();
		const parsed = P.parse(main.stackAllocator, c.input, &errors) catch {
			std.debug.print("[cheat-test] veteran parse FAILED for \"{s}\": {s}\n", .{ c.input, errors.items });
			return error.ParseFailed;
		};
		try std.testing.expectEqual(c.expected, std.meta.activeTag(parsed));
	}
}
