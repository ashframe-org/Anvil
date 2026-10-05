const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;

pub const description = "Get or set a player's gamemode.";
pub const usage =
	\\/gamemode <survival/creative>
	\\/gamemode @playerIndex <survival/creative>
	\\/gamemode
	\\/gamemode @playerIndex
;

pub const Args = union(enum) {
	@"/gamemode <playerIndex> <mode>": struct { playerIndex: ?command.PlayerIndex, mode: ?main.game.Gamemode },
};

pub fn execute(args: Args, source: Source) void {
	// --- ASHFRAME CUSTOM (Anticheat: gamemode is admin-gated) ---
	// The command grant alone must not confer the power to flip a player to
	// creative: that's the classic self-grant exploit if the command is ever
	// handed to a non-admin group. Setting a mode requires the disjoint admin
	// path; querying your own mode stays open to anyone with the command.
	// --- ASHFRAME CUSTOM (Anticheat) ---
	switch (args) {
		.@"/gamemode <playerIndex> <mode>" => |params| {
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;

			if (params.mode) |mode| {
				// --- ASHFRAME CUSTOM (Anticheat: gamemode is admin-gated) ---
				if (!source.hasPermission("/ashframe/admin/gamemode")) {
					source.sendMessage("#e6312cYou do not have permission to change gamemodes.", .{});
					return;
				}
				// --- ASHFRAME CUSTOM (Anticheat) ---
				main.sync.setGamemode(target.user, mode);
			} else {
				source.sendMessage("#ffff00{s}", .{@tagName(target.user.gamemode.load(.monotonic))});
			}
		},
	}
}
