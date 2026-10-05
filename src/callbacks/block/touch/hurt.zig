const std = @import("std");

const main = @import("main");

dps: f32,
damageType: main.game.DamageType,
// --- ASHFRAME CUSTOM (Consolidated damage reports) ---
// Contact damage used to emit one sync report per physics tick (60+/s per
// block touched, more inside cactus clusters), saturating the damage rate
// gate so the fatal tick could be dropped and the player sat immortal at 0.
// Accumulate instead and flush at >=0.5 HP or twice per second: identical
// damage over time at a fraction of the packet rate, and the fatal chunk is
// never diced below detection. (Damage also bypasses rate limiting entirely
// now, see protocols.zig, so reports always land.)
pendingDamage: f32 = 0,
lastFlushMs: i64 = 0,
// --- ASHFRAME CUSTOM (Consolidated damage reports) ---

pub fn init(zon: main.ZonElement, _: main.callbacks.Creator) ?*@This() {
	const result = main.worldArena.create(@This());
	result.* = .{
		.dps = zon.get(f32, "dps") orelse {
			std.log.err("Missing field \"dps\" for hurt event", .{});
			return null;
		},
		.damageType = std.meta.stringToEnum(main.game.DamageType, zon.get([]const u8, "damageType") orelse {
			std.log.err("Missing field \"damageType\" for hurt event", .{});
			return null;
		}) orelse {
			std.log.err("Unknown damage type for hurt event", .{});
			return null;
		},
	};
	return result;
}

pub fn run(self: *@This(), params: main.callbacks.BlockTouchCallback.Params) main.callbacks.Result {
	std.debug.assert(params.entity == &main.game.Player.super); // TODO: Implement on the server side
	self.pendingDamage += self.dps*@as(f32, @floatCast(params.deltaTime));
	const now = main.timestamp().toMilliseconds();
	if (self.pendingDamage >= 0.5 or now - self.lastFlushMs >= 500) {
		if (self.pendingDamage > 0.01) {
			main.sync.addHealth(-self.pendingDamage, self.damageType, .client, main.game.Player.id);
		}
		self.pendingDamage = 0;
		self.lastFlushMs = now;
	}
	return .handled;
}
