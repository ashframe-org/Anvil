const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const alliances = main.server.alliances;
const ashutil = @import("ashutil.zig");

pub const description = "Create or join an alliance (village) and pool your claim slots.";
pub const usage =
	\\/alliance create <name> <public/private>
	\\/alliance join <name>
	\\/alliance info <name>
	\\/alliance list [page]
	\\/alliance accept <player>
	\\/alliance deny <player>
	\\/alliance invite <player>
	\\/alliance kick <player>
	\\/alliance leave
	\\/alliance disband
	\\/alliance allow chest <members/anyone>
;

const Visibility = enum { public, private };
const ChestAccess = enum { members, anyone };

// NOTE: the parser matches a union by field *types in order* and takes the first
// variant that parses, so each variant must begin with an enum field holding its
// keyword(s), and longer forms must be listed before shorter ones.
pub const Args = union(enum) {
	@"/alliance create <name> <visibility>": struct { cmd: enum { create }, name: []const u8, visibility: Visibility },
	@"/alliance allow chest <access>": struct { cmd: enum { allow }, what: enum { chest }, access: ChestAccess },
	@"/alliance join <name>": struct { cmd: enum { join }, name: []const u8 },
	@"/alliance info <name>": struct { cmd: enum { info }, name: []const u8 },
	@"/alliance accept <player>": struct { cmd: enum { accept }, player: []const u8 },
	@"/alliance deny <player>": struct { cmd: enum { deny }, player: []const u8 },
	@"/alliance invite <player>": struct { cmd: enum { invite }, player: []const u8 },
	@"/alliance kick <player>": struct { cmd: enum { kick }, player: []const u8 },
	@"/alliance leave": struct { cmd: enum { leave } },
	@"/alliance disband": struct { cmd: enum { disband } },
	@"/alliance list <page>": struct { cmd: enum { list }, page: usize },
	@"/alliance list": struct { cmd: enum { list } },
	@"/alliance help": struct { cmd: enum { help } },
};

fn leaderName(index: usize) []const u8 {
	if (main.server.getUserByIndex(index)) |u| return u.name;
	return "?";
}

fn formatDate(buf: []u8, epochSeconds: i64) []const u8 {
	if (epochSeconds <= 0) return "?";
	const epochSecs = std.time.epoch.EpochSeconds{.secs = @intCast(epochSeconds)};
	const yearDay = epochSecs.getEpochDay().calculateYearDay();
	const monthDay = yearDay.calculateMonthDay();
	return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{yearDay.year, monthDay.month.numeric(), monthDay.day_index + 1}) catch "?";
}

fn listAlliances(source: Source, page: usize) void {
	const all = alliances.list();
	if (all.len == 0) {
		source.sendMessage("#cfcfcfNo alliances yet. #8a8a8a(/alliance create <name> <public/private>)", .{});
		return;
	}
	const pageSize: usize = 8;
	const pageCount = (all.len + pageSize - 1)/pageSize;
	const p = @min(@max(page, 1), pageCount);
	const start = (p - 1)*pageSize;
	source.sendMessage("#f2f2f2--- Alliances ({d}) — page {d}/{d} ---", .{all.len, p, pageCount});
	for (all[start..@min(start + pageSize, all.len)]) |*a| {
		source.sendMessage("#e6312c{s} #8a8a8a({s}) #cfcfcf- leader {s}, {d} member(s)", .{a.name, if (a.isPublic) "public" else "private", leaderName(a.owner), a.memberCount});
	}
	if (p < pageCount) source.sendMessage("#8a8a8aNext: #cfcfcf/alliance list {d}", .{p + 1});
}

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	switch (args) {
		.@"/alliance create <name> <visibility>" => |p| {
			// Alliance names display publicly; filter like any public text.
			if (main.server.chatfilter.findBad(p.name) != null) {
				_ = main.server.chatfilter.strike(user);
				return;
			}
			switch (alliances.create(user, p.name, p.visibility == .public)) {
			.ok => source.sendMessage("#00ff00Alliance #e6312c{s}#00ff00 created ({s}). #8a8a8a(Members' unused claim slots are pooled.)", .{ p.name, @tagName(p.visibility) }),
			.badName => source.sendMessage("#e6312cInvalid name. #8a8a8a(Letters, digits, _ and -, max {d}.)", .{alliances.maxNameLen}),
			.exists => source.sendMessage("#e6312cAn alliance with that name already exists.", .{}),
			.alreadyIn => source.sendMessage("#e6312cYou are already in an alliance.", .{}),
			else => {},
			}
		},
		.@"/alliance help" => {
			source.sendMessage("#f2f2f2--- /alliance ---", .{});
			var it = std.mem.splitScalar(u8, usage, '\n');
			while (it.next()) |line| source.sendMessage("#cfcfcf{s}", .{line});
		},
		.@"/alliance join <name>" => |p| {
			const ai = alliances.findByName(p.name) orelse {
				source.sendMessage("#e6312cNo alliance called #cfcfcf{s}#e6312c.", .{p.name});
				return;
			};
			const a = &alliances.list()[ai];
			const invited = alliances.hasInvite(a.name, user.playerIndex);
			if (a.isPublic or invited) {
				switch (alliances.join(a.owner, user)) {
					.ok => {
						source.sendMessage("#00ff00Joined alliance #e6312c{s}#00ff00.", .{a.name});
						if (main.server.getUserByIndex(a.owner)) |leader| leader.sendMessage("#e6e6e6{s} #cfcfcfjoined your alliance #e6312c{s}#cfcfcf.", .{ user.name, a.name });
					},
					.alreadyIn => source.sendMessage("#e6312cYou are already in an alliance.", .{}),
					.memberLimit => source.sendMessage("#e6312cThat alliance is full.", .{}),
					else => source.sendMessage("#e6312cCould not join that alliance.", .{}),
				}
			} else {
				_ = alliances.requestJoin(a.name, user);
				source.sendMessage("#cfcfcfRequested to join #e6312c{s}#cfcfcf. The leader must accept.", .{a.name});
				if (main.server.getUserByIndex(a.owner)) |leader| leader.sendMessage("#e6e6e6{s} #cfcfcfwants to join your alliance #e6312c{s}#cfcfcf — #e6312c/alliance accept {s}", .{ user.name, a.name, user.name });
			}
		},
		.@"/alliance info <name>" => |p| {
			const ai = alliances.findByName(p.name) orelse {
				source.sendMessage("#e6312cNo alliance called #cfcfcf{s}#e6312c.", .{p.name});
				return;
			};
			const a = &alliances.list()[ai];
		source.sendMessage("#f2f2f2--- #e6312c{s}#f2f2f2 ({s}) ---", .{ a.name, if (a.isPublic) "public" else "private" });
		source.sendMessage("#cfcfcfLeader: #e6312c{s}#cfcfcf. Members: {d}. Max claims: {d}.", .{ leaderName(a.owner), a.memberCount, alliances.baseMaxClaims + alliances.pooledSlots(a) });
		for (a.members[0..a.memberCount]) |m| {
			source.sendMessage("#cfcfcf- {s}", .{m.name});
		}
		},
		.@"/alliance list <page>" => |p| listAlliances(source, p.page),
		.@"/alliance list" => listAlliances(source, 1),
		.@"/alliance accept <player>" => |p| {
			const ai = alliances.findLedBy(user.playerIndex) orelse {
				source.sendMessage("#e6312cYou don't lead an alliance.", .{});
				return;
			};
			const a = &alliances.list()[ai];
			// Prefer an online target so we can notify them; otherwise accept the
			// stored request so an offline requester can still join.
			const online = ashutil.findTargetByNameOrIndex(p.player);
			if (online) |target| {
				if (!alliances.hasRequest(a.name, target.playerIndex)) {
					source.sendMessage("#e6312cThat player has no pending request.", .{});
					return;
				}
			}
			const result = if (online) |target| alliances.join(user.playerIndex, target) else alliances.acceptRequest(user, p.player);
			switch (result) {
				.ok => {
					const name = if (online) |target| target.name else p.player;
					source.sendMessage("#00ff00{s} #cfcfcfjoined #e6312c{s}#00ff00.", .{ name, a.name });
					if (online) |target| target.sendMessage("#00ff00You joined alliance #e6312c{s}#00ff00.", .{a.name});
				},
				.notFound => source.sendMessage("#e6312cThat player has no pending request.", .{}),
				.alreadyIn => source.sendMessage("#e6312cThey are already in an alliance.", .{}),
				.memberLimit => source.sendMessage("#e6312cYour alliance is full.", .{}),
				else => source.sendMessage("#e6312cCould not accept.", .{}),
			}
		},
		.@"/alliance deny <player>" => |p| {
			_ = alliances.findLedBy(user.playerIndex) orelse {
				source.sendMessage("#e6312cYou don't lead an alliance.", .{});
				return;
			};
			if (!alliances.denyRequestByName(user, p.player)) {
				source.sendMessage("#e6312cNo pending request from #cfcfcf{s}#e6312c.", .{p.player});
				return;
			}
			source.sendMessage("#cfcfcfDenied #e6312c{s}#cfcfcf's request.", .{p.player});
		},
		.@"/alliance invite <player>" => |p| {
			const ai = alliances.findLedBy(user.playerIndex) orelse {
				source.sendMessage("#e6312cYou don't lead an alliance.", .{});
				return;
			};
			const name = alliances.list()[ai].name;
			const target = ashutil.findTargetByNameOrIndex(p.player) orelse {
				source.sendMessage("#e6312cPlayer not found or offline.", .{});
				return;
			};
			switch (alliances.invite(user, target)) {
				.ok => {
					source.sendMessage("#00ff00Invited #e6312c{s}#00ff00. #8a8a8a(They accept with /alliance join.)", .{target.name});
					target.sendMessage("#00ff00{s} #cfcfcfinvited you to their alliance #e6312c{s}#cfcfcf — #e6312c/alliance join {s}#cfcfcf to accept.", .{ user.name, name, name });
				},
				.alreadyIn => source.sendMessage("#e6312cThey are already in an alliance.", .{}),
				else => source.sendMessage("#e6312cCould not invite.", .{}),
			}
		},
		.@"/alliance kick <player>" => |p| {
			_ = alliances.findLedBy(user.playerIndex) orelse {
				source.sendMessage("#e6312cYou don't lead an alliance.", .{});
				return;
			};
			if (!alliances.kickByName(user, p.player)) {
				source.sendMessage("#e6312cNo member called #cfcfcf{s}#e6312c.", .{p.player});
				return;
			}
			source.sendMessage("#cfcfcfKicked #e6312c{s}#cfcfcf. Their claim slots were returned.", .{p.player});
			if (ashutil.findTargetByNameOrIndex(p.player)) |target| {
				target.sendMessage("#e6312cYou were removed from the alliance. #cfcfcf(Your claim slots were returned.)", .{});
			}
		},
		.@"/alliance allow chest <access>" => |p| {
			if (!alliances.setChestMembersOnly(user, p.access == .members)) {
				source.sendMessage("#e6312cYou don't lead an alliance.", .{});
				return;
			}
			source.sendMessage("#00ff00Alliance chests are now accessible to: #cfcfcf{s}#00ff00.", .{@tagName(p.access)});
		},
		.@"/alliance leave" => {
			if (alliances.allianceOf(user.playerIndex) == null) {
				source.sendMessage("#e6312cYou aren't in an alliance.", .{});
				return;
			}
			const wasLeader = alliances.findLedBy(user.playerIndex) != null;
			alliances.leave(user);
			if (wasLeader) {
				source.sendMessage("#cfcfcfAlliance disbanded. #8a8a8a(Everyone's claim slots were returned.)", .{});
			} else {
				source.sendMessage("#cfcfcfLeft the alliance. #8a8a8a(Your claim slots were returned.)", .{});
			}
		},
		.@"/alliance disband" => {
			const ai = alliances.findLedBy(user.playerIndex) orelse {
				source.sendMessage("#e6312cYou don't lead an alliance.", .{});
				return;
			};
			// Copy the name first: `disband` frees it.
			const name = main.stackAllocator.dupe(u8, alliances.list()[ai].name);
			defer main.stackAllocator.free(name);
			alliances.disband(user);
			source.sendMessage("#cfcfcfAlliance #e6312c{s}#cfcfcf disbanded. #8a8a8a(All members' claim slots were returned.)", .{name});
		},
	}
}

test "alliance command arg parsing" {
	const P = main.argparse.Parser(Args, .{.commandName = "alliance"});
	const cases = [_]struct { input: []const u8, expected: std.meta.Tag(Args) }{
		.{ .input = "create test private", .expected = .@"/alliance create <name> <visibility>" },
		.{ .input = "create test public", .expected = .@"/alliance create <name> <visibility>" },
		.{ .input = "allow chest anyone", .expected = .@"/alliance allow chest <access>" },
		.{ .input = "allow chest members", .expected = .@"/alliance allow chest <access>" },
		.{ .input = "join someName", .expected = .@"/alliance join <name>" },
		.{ .input = "info someName", .expected = .@"/alliance info <name>" },
		.{ .input = "accept bob", .expected = .@"/alliance accept <player>" },
		.{ .input = "deny bob", .expected = .@"/alliance deny <player>" },
		.{ .input = "invite bob", .expected = .@"/alliance invite <player>" },
		.{ .input = "kick bob", .expected = .@"/alliance kick <player>" },
		.{ .input = "leave", .expected = .@"/alliance leave" },
		.{ .input = "disband", .expected = .@"/alliance disband" },
		.{ .input = "list", .expected = .@"/alliance list" },
		.{ .input = "list 2", .expected = .@"/alliance list <page>" },
		.{ .input = "help", .expected = .@"/alliance help" },
		// A name that collides with a keyword must still parse as join.
		.{ .input = "join list", .expected = .@"/alliance join <name>" },
	};
	for (cases) |c| {
		var errors: main.ListManaged(u8) = .init(main.stackAllocator);
		defer errors.deinit();
		const parsed = P.parse(main.stackAllocator, c.input, &errors) catch {
			std.debug.print("[cheat-test] alliance parse FAILED for \"{s}\": {s}\n", .{ c.input, errors.items });
			return error.ParseFailed;
		};
		std.testing.expectEqual(c.expected, std.meta.activeTag(parsed)) catch {
			std.debug.print("[cheat-test] alliance parsed \"{s}\" as {s}, expected {s}\n", .{ c.input, @tagName(std.meta.activeTag(parsed)), @tagName(c.expected) });
			return error.WrongVariant;
		};
	}
	std.debug.print("[cheat-test] alliance arg parsing OK ({d} cases)\n", .{cases.len});
}
