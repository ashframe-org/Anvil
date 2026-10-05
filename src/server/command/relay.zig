const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const discordlink = main.server.discordlink;

// --- ASHFRAME CUSTOM (Discord account link) ---
// Used only by the Discord relay bot (its protected key). Replies go to the bot
// as "[relay-reply] <req> ok|err ..." lines, which the relay matches by <req>.

pub const description = "Discord relay bot only.";
pub const usage =
	\\/relay link <req> <code> <discordId> <discordName>
	\\/relay recover <req> <discordId>
	\\/relay cancel <req> <code>
;

pub const Args = union(enum) {
	@"/relay link <req> <code> <discordId> <discordName>": struct { link: enum { link }, req: []const u8, code: []const u8, discordId: []const u8, discordName: []const u8 },
	@"/relay recover <req> <discordId>": struct { recover: enum { recover }, req: []const u8, discordId: []const u8 },
	@"/relay cancel <req> <code>": struct { cancel: enum { cancel }, req: []const u8, code: []const u8 },
};

fn reply(source: Source, req: []const u8, comptime fmt: []const u8, args: anytype) void {
	var buf: [256]u8 = undefined;
	const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
	source.sendMessage("[relay-reply] {s} {s}", .{req, text});
}

pub fn execute(args: Args, source: Source) void {
	// Defence in depth: only the relay bot is granted /command/relay, but
	// check its key here too.
	if (source != .user or !main.server.chatfilter.isProtected(source.user.newKeyString)) {
		source.sendMessage("#e6312cThis command is for the Discord relay bot.", .{});
		return;
	}
	switch (args) {
		.@"/relay link <req> <code> <discordId> <discordName>" => |a| switch (discordlink.confirmLink(a.code, a.discordId, a.discordName)) {
			.ok => |name| reply(source, a.req, "ok {s}", .{name}),
			.badCode => reply(source, a.req, "err badCode", .{}),
			.discordAlreadyLinked => reply(source, a.req, "err discordAlreadyLinked", .{}),
			.accountAlreadyLinked => reply(source, a.req, "err accountAlreadyLinked", .{}),
			.badDiscordId => reply(source, a.req, "err badDiscordId", .{}),
		},
		.@"/relay recover <req> <discordId>" => |a| switch (discordlink.startRecovery(a.discordId)) {
			.code => |c| reply(source, a.req, "ok {s} {s}", .{&c.code, c.name}),
			.notLinked => reply(source, a.req, "err notLinked", .{}),
			.badDiscordId => reply(source, a.req, "err badDiscordId", .{}),
		},
		.@"/relay cancel <req> <code>" => |a| {
			reply(source, a.req, "ok {s}", .{if (discordlink.cancelCode(a.code)) "cancelled" else "none"});
		},
	}
}
// --- ASHFRAME CUSTOM (Discord account link) ---
