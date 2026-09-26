const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const User = main.server.User;

pub const description = "Get or set a player's / the world spawn point";
pub const usage =
	\\/spawn
	\\/spawn <x> <y> <z>
	\\/spawn @<playerIndex>
	\\/spawn @<playerIndex> <x> <y> <z>
	\\/spawn world
	\\/spawn world <x> <y> <z>
;

pub const Args = union(enum) {
	@"/spawn <playerIndex> <x> <y> <z>": struct { playerIndex: ?command.PlayerIndex, x: command.Coordinate, y: command.Coordinate, z: command.Coordinate },
	@"/spawn <world> <x> <y> <z>": struct { world: enum { world }, x: command.Coordinate, y: command.Coordinate, z: command.Coordinate },
	@"/spawn <world>": struct { world: enum { world } },
	@"/spawn <playerIndex>": struct { playerIndex: ?command.PlayerIndex },
};

// --- ASHFRAME CUSTOM (Spawn admin gate) ---
/// /spawn is granted to every player by default so they can teleport to spawn,
/// but setting another player's spawn point or moving world spawn is an admin
/// action - gated separately since argparse only has one permission per command.
fn requireAdmin(source: Source) bool {
	if (!source.hasPermission("/ashframe/admin/spawn")) {
		source.sendMessage("#e6312cYou do not have permission to change spawn points.", .{});
		return false;
	}
	return true;
}
// --- ASHFRAME CUSTOM (Spawn admin gate) ---

pub fn execute(args: Args, source: Source) void {
	switch (args) {
		.@"/spawn <playerIndex> <x> <y> <z>" => |params| {
			if (!requireAdmin(source)) return;
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;
			target.user.spawnPos = command.resolveCoordinates(params.x, params.y, params.z, source) catch return;
		},
		.@"/spawn <playerIndex>" => |params| {
			// --- ASHFRAME CUSTOM (Bare /spawn teleports the caller) ---
			if (params.playerIndex == null and source == .user) {
				const user = source.user;
				main.server.anticheat.expectTeleport(user);
				main.network.protocols.genericUpdate.sendTPCoordinates(user.conn, user.getSpawnPos());
				source.sendMessage("#cfcfcfTeleported to spawn.", .{});
				return;
			}
			// --- ASHFRAME CUSTOM (Bare /spawn teleports the caller) ---

			if (!requireAdmin(source)) return;
			const target = command.Target.fromPlayerIndex(params.playerIndex, source) catch return;
			source.sendMessage("#ffff00{}", .{target.user.getSpawnPos()});
		},
		.@"/spawn <world> <x> <y> <z>" => |params| {
			if (!requireAdmin(source)) return;
			const pos = command.resolveCoordinates(params.x, params.y, params.z, source) catch return;
			const world = main.server.world.?;
			world.spawn = @trunc(pos);
		},
		.@"/spawn <world>" => {
			if (!requireAdmin(source)) return;
			const world = main.server.world.?;
			source.sendMessage("#ffff00World spawn: {}", .{world.spawn});
		},
	}
}
