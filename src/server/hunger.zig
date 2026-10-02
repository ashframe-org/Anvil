// --- ASHFRAME CUSTOM (Hunger) ---
// Hunger uses the vanilla energy bar: `energy` is the calorie count (0..maxEnergy,
// default 8). This is 100% server-side — the vanilla client already renders the
// synced energy value, so no packet or client change is needed.
//
// Rules:
//  - Energy drains over time, faster while moving (and sprinting).
//  - Well-fed (energy >= regenThreshold): health slowly regenerates.
//  - Empty (energy == 0): no regen, and health drains down to a 1 HP floor
//    (you are stuck at 1 HP until you eat).
//  - Food (`/eat`) restores energy by the item's food value.
//  - Paused while AFK. Creative is handled by the caller (only survival ticks).

const std = @import("std");

const main = @import("main");
const User = main.server.User;

/// Energy (calories) drained per second while idle.
const drainIdlePerSec: f32 = 1.0/90.0;
/// Energy drained per second while moving.
const drainMovingPerSec: f32 = 1.0/45.0;
/// Energy drained per second while sprinting (added to movement).
const drainSprintPerSec: f32 = 1.0/30.0;
/// Speed (squared) above which movement drain applies.
const moveSpeedSqThreshold: f32 = 0.01;
/// Speed (squared) above which sprint drain is added.
const sprintSpeedSqThreshold: f32 = 16.0;

/// Energy at/above which health regenerates.
const regenThreshold: f32 = 7.0;
/// Seconds per +1 health while well-fed.
const regenIntervalSec: f32 = 4.0;

/// Health drained per second while starving (energy == 0). Implemented as
/// `-1 HP` every `starveIntervalSec`, applied in fractional accumulation.
const starveIntervalSec: f32 = 4.0;
/// Never drains health below this while starving (stuck at 1 HP until you eat).
const starveHealthFloor: f32 = 1.0;
/// Once health is at the floor, only starve-damage is skipped while still at 0
/// energy; the message is rate-limited to avoid spamming.
const starveWarnIntervalSec: f32 = 10.0;

pub fn tick(user: *User, deltaTime: f32, speedSq: f32) void {
	const prof = user.player();

	// AFK players don't burn calories (they're not "doing" anything, and it
	// would punish people for stepping away).
	if (!prof.is_afk) {
		var rate = drainIdlePerSec;
		if (speedSq > moveSpeedSqThreshold) rate += drainMovingPerSec;
		if (speedSq > sprintSpeedSqThreshold) rate += drainSprintPerSec;

		prof.hungerDebt += rate*deltaTime;
		// Apply whole-pip (and half-pip) changes only, so we don't spam the
		// client with tiny per-tick energy syncs.
		if (prof.hungerDebt >= 0.5 and prof.energy > 0) {
			const step = @min(prof.hungerDebt, prof.energy);
			prof.hungerDebt -= step;
			// Negative delta = drain.
			main.sync.addEnergy(-step, .server, user.id);
		}
	}

	// Health handling based on the (possibly just-updated) energy value.
	if (prof.energy >= regenThreshold) {
		prof.hungerStarveTimer = 0;
		if (prof.health < prof.maxHealth) {
			prof.hungerRegenTimer += deltaTime;
			while (prof.hungerRegenTimer >= regenIntervalSec and prof.health < prof.maxHealth) {
				prof.hungerRegenTimer -= regenIntervalSec;
				main.sync.addHealth(1, .heal, .server, user.id);
			}
		} else {
			prof.hungerRegenTimer = 0;
		}
	} else if (prof.energy <= 0) {
		prof.hungerRegenTimer = 0;
		if (prof.health > starveHealthFloor) {
			prof.hungerStarveTimer += deltaTime;
			while (prof.hungerStarveTimer >= starveIntervalSec and prof.health > starveHealthFloor) {
				prof.hungerStarveTimer -= starveIntervalSec;
				// Never overkill below the floor: clamp the applied delta.
				const amount = @min(1, prof.health - starveHealthFloor);
				main.sync.addHealth(-amount, .starve, .server, user.id);
			}
			prof.hungerWarnTimer = 0;
		} else if (prof.health <= starveHealthFloor) {
			// At the floor: warn occasionally so the player knows to eat.
			prof.hungerWarnTimer += deltaTime;
			if (prof.hungerWarnTimer >= starveWarnIntervalSec) {
				prof.hungerWarnTimer = 0;
				user.sendMessage("#e6312cYou are starving! Find food and use #cfcfcf/eat#e6312c to restore energy.", .{});
			}
		}
	} else {
		prof.hungerRegenTimer = 0;
		prof.hungerStarveTimer = 0;
	}
}
// --- ASHFRAME CUSTOM (Hunger) ---
