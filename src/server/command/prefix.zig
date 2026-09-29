const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Add or remove chat prefixes for players.";
pub const usage =
	\\/prefix add @<playerIndex> <text>
	\\/prefix remove @<playerIndex>
;

pub const Args = union(enum) {
	@"/prefix add <playerIndex> <text>": struct {add: enum {add}, playerIndex: ?command.PlayerIndex, text: command.RestOfLine},
	@"/prefix remove <playerIndex>": struct {remove: enum {remove}, playerIndex: ?command.PlayerIndex},
};

pub fn execute(args: Args, source: Source) void {
	if (!source.hasPermission("/ashframe/admin/prefix")) {
		source.sendMessage("#e6312cYou do not have permission to manage player prefixes.", .{});
		return;
	}

	switch (args) {
		.@"/prefix add <playerIndex> <text>" => |params| {
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;

			// Prefixes land in every chat line and nametag of the target, so
			// they get the same validation as player names at handshake:
			// valid UTF-8, bounded visible length. (Previously unvalidated —
			// a single hostile paste could crash every viewer.)
			const maxPrefixVisible: usize = 32;
			if (!std.unicode.utf8ValidateSlice(params.text.text)) {
				source.sendMessage("#e6312cPrefix contains invalid characters.", .{});
				return;
			}
			if (main.graphics.TextBuffer.Parser.countVisibleCharacters(params.text.text) > maxPrefixVisible) {
				source.sendMessage("#e6312cPrefix too long (max {d} visible characters).", .{maxPrefixVisible});
				return;
			}

			if (target.user.player().prefix) |oldPrefix| {
				main.globalAllocator.free(oldPrefix);
			}

			target.user.player().prefix = main.globalAllocator.dupe(u8, params.text.text);
			source.sendMessage("#cfcfcfSuccessfully assigned prefix to #e6312c{s}#cfcfcf.", .{target.user.name});
			target.user.sendMessage("#cfcfcfYour chat prefix has been updated to: #8a8a8a[#e6312c{s}#8a8a8a]", .{params.text.text});
		},
		.@"/prefix remove <playerIndex>" => |params| {
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;

			if (target.user.player().prefix) |oldPrefix| {
				main.globalAllocator.free(oldPrefix);
				target.user.player().prefix = null;
				source.sendMessage("#cfcfcfSuccessfully cleared prefix from #e6312c{s}#cfcfcf.", .{target.user.name});
				target.user.sendMessage("#e6312cYour chat prefix has been removed.", .{});
			} else {
				source.sendMessage("#e6312cPlayer #cfcfcf{s}#e6312c does not currently have a prefix.", .{target.user.name});
			}
		},
	}
}
