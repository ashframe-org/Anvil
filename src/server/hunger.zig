// --- ASHFRAME CUSTOM (Hunger) ---
// Hunger uses the vanilla energy bar: `energy` is the calorie count (0..maxEnergy,
// default 8). This is 100% server-side — the vanilla client already renders the
// synced energy value, so no packet or client change is needed.
//
// Rules (hunger fuels healing; healing never consumes hunger):
//  - Energy drains over time, faster while moving (and sprinting).
//  - Health regenerates whenever energy > 0, faster the fuller the bar. Regen
//    does NOT spend energy - only time/movement drains it.
//  - Empty (energy == 0): no regen, and health drains down to a 1 HP floor
//    (you are stuck at 1 HP until you eat).
//  - Food (`/eat`) restores energy AND health by the item's food value.
//  - Paused while AFK. Creative is handled by the caller (only survival ticks).

const std = @import("std");

const main = @import("main");
const User = main.server.User;

/// Energy (calories) drained per second while idle.
const drainIdlePerSec: f32 = 1.0/225.0;
/// Energy drained per second while moving.
const drainMovingPerSec: f32 = 1.0/110.0;
/// Energy drained per second while sprinting (added to movement).
const drainSprintPerSec: f32 = 1.0/75.0;
/// Speed (squared) above which movement drain applies.
const moveSpeedSqThreshold: f32 = 0.01;
/// Speed (squared) above which sprint drain is added.
const sprintSpeedSqThreshold: f32 = 16.0;

/// Regen only needs any hunger at all; the rate scales with how full the bar is.
/// At full energy health regenerates every `regenIntervalFullSec`, slowing
/// linearly toward `regenIntervalLowSec` as energy approaches 1.
const regenIntervalFullSec: f32 = 4.0;
const regenIntervalLowSec: f32 = 16.0;

/// Health drained per second while starving (energy == 0), as `-1 HP` every
/// `starveIntervalSec`.
const starveIntervalSec: f32 = 4.0;
/// Never drains health below this while starving (stuck at 1 HP until you eat).
const starveHealthFloor: f32 = 1.0;

pub fn tick(user: *User, deltaTime: f32, speedSq: f32) void {
	const prof = user.player();

	// AFK players don't burn calories (they're not "doing" anything, and it
	// would punish people for stepping away).
	if (!prof.is_afk) {
		var rate = drainIdlePerSec;
		if (speedSq > moveSpeedSqThreshold) rate += drainMovingPerSec;
		if (speedSq > sprintSpeedSqThreshold) rate += drainSprintPerSec;

		prof.hungerDebt += rate*deltaTime;
		// Apply half-pip changes only, so we don't spam the client with tiny
		// per-tick energy syncs.
		if (prof.hungerDebt >= 0.5 and prof.energy > 0) {
			const step = @min(prof.hungerDebt, prof.energy);
			prof.hungerDebt -= step;
			// Negative delta = drain.
			main.sync.addEnergy(-step, .server, user.id);
		}
	}

	// Health handling based on the (possibly just-updated) energy value.
	if (prof.energy > 0) {
		prof.hungerStarveTimer = 0;
		prof.hungerStarveNotified = false;
		if (prof.health < prof.maxHealth) {
			// Faster regen the fuller the bar: full -> regenIntervalFullSec,
			// nearly empty -> regenIntervalLowSec.
			const fullness = @min(1, prof.energy/prof.maxEnergy);
			const interval = regenIntervalFullSec + (regenIntervalLowSec - regenIntervalFullSec)*(1 - fullness);
			prof.hungerRegenTimer += deltaTime;
			while (prof.hungerRegenTimer >= interval and prof.health < prof.maxHealth) {
				prof.hungerRegenTimer -= interval;
				main.sync.addHealth(1, .heal, .server, user.id);
			}
		} else {
			prof.hungerRegenTimer = 0;
		}
	} else {
		// Starving: no regen; health drains to a 1 HP floor and holds there.
		prof.hungerRegenTimer = 0;
		if (prof.health > starveHealthFloor) {
			prof.hungerStarveTimer += deltaTime;
			while (prof.hungerStarveTimer >= starveIntervalSec and prof.health > starveHealthFloor) {
				prof.hungerStarveTimer -= starveIntervalSec;
				// Never overkill below the floor: clamp the applied delta.
				const amount = @min(1, prof.health - starveHealthFloor);
				main.sync.addHealth(-amount, .starve, .server, user.id);
			}
		}
		// Edge-triggered notice: once per starvation episode, at the floor.
		if (!prof.hungerStarveNotified and prof.health <= starveHealthFloor) {
			prof.hungerStarveNotified = true;
			user.sendMessage("#e6312cYou are starving! Eat food with #cfcfcf/eat#e6312c to recover.", .{});
		}
	}
}
// --- ASHFRAME CUSTOM (Hunger) ---
