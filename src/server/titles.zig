const std = @import("std");

const main = @import("main");
const User = main.server.User;
const Entity = main.server.Entity;

// --- ASHFRAME CUSTOM (Titles) ---
// Small collectable achievements that a player can wear in front of their name
// in chat, e.g. "[Chatty] iNiKKo". Unlock conditions are intentionally never
// shown to players; secret titles are only listed as "[Secret]" until earned.

const Trigger = enum {
	messages,
	afkTime,
	daysPlayed,
	playtime,
	distance,
	minY,
	applesEaten,
	sessionTime,
	skyIsland,
	mined,
	placed,
	explorer,
	completionist,
	trades,
	claims,
	allianceMembers,
	voidRoots,
	hermit,
	// Granted externally (season veterans, events) — never auto-fires.
	manual,
};

pub const Title = struct {
	id: []const u8,
	display: []const u8,
	secret: bool,
	trigger: Trigger,
	threshold: f64,
};

pub const all = [_]Title{
	.{.id = "busy", .display = "Busy", .secret = false, .trigger = .afkTime, .threshold = 3600},
	.{.id = "chatty", .display = "Chatty", .secret = false, .trigger = .messages, .threshold = 250},
	.{.id = "chatterbox", .display = "Chatterbox", .secret = false, .trigger = .messages, .threshold = 500},
	.{.id = "loyal", .display = "Loyal", .secret = false, .trigger = .daysPlayed, .threshold = 14},
	.{.id = "veteran", .display = "Veteran", .secret = false, .trigger = .playtime, .threshold = 10*3600},
	.{.id = "elder", .display = "Elder", .secret = false, .trigger = .playtime, .threshold = 20*3600},
	.{.id = "ancient", .display = "Ancient", .secret = false, .trigger = .playtime, .threshold = 30*3600},
	.{.id = "wanderer", .display = "Wanderer", .secret = true, .trigger = .distance, .threshold = 10000},
	.{.id = "mole", .display = "Mole", .secret = true, .trigger = .minY, .threshold = -5000},
	.{.id = "dwarf", .display = "Dwarf", .secret = true, .trigger = .minY, .threshold = -10000},
	.{.id = "skyborn", .display = "Skyborn", .secret = true, .trigger = .skyIsland, .threshold = 0},
	.{.id = "ravenous", .display = "Ravenous", .secret = true, .trigger = .applesEaten, .threshold = 100},
	.{.id = "insomniac", .display = "Insomniac", .secret = true, .trigger = .sessionTime, .threshold = 6*3600},
	.{.id = "miner", .display = "Miner", .secret = false, .trigger = .mined, .threshold = 5000},
	.{.id = "builder", .display = "Builder", .secret = false, .trigger = .placed, .threshold = 5000},
	.{.id = "explorer", .display = "Explorer", .secret = true, .trigger = .explorer, .threshold = 15},
	.{.id = "completionist", .display = "Completionist", .secret = true, .trigger = .completionist, .threshold = 0},
	.{.id = "seasoned", .display = "Seasoned", .secret = false, .trigger = .daysPlayed, .threshold = 100},
	.{.id = "legend", .display = "Legend", .secret = false, .trigger = .playtime, .threshold = 100*3600},
	.{.id = "landlord", .display = "Landlord", .secret = true, .trigger = .claims, .threshold = 10},
	.{.id = "trader", .display = "Trader", .secret = false, .trigger = .trades, .threshold = 25},
	.{.id = "diplomat", .display = "Diplomat", .secret = false, .trigger = .allianceMembers, .threshold = 5},
	.{.id = "hermit", .display = "Hermit", .secret = true, .trigger = .hermit, .threshold = 10*3600},
	.{.id = "voidwalker", .display = "Voidwalker", .secret = true, .trigger = .voidRoots, .threshold = -49000},
	.{.id = "s0", .display = "S0", .secret = false, .trigger = .manual, .threshold = 0},
	.{.id = "s1", .display = "S1", .secret = false, .trigger = .manual, .threshold = 0},
	.{.id = "s2", .display = "S2", .secret = false, .trigger = .manual, .threshold = 0},
	.{.id = "s3", .display = "S3", .secret = false, .trigger = .manual, .threshold = 0},
};

const skyIslandTagName = "sky_island_layer";
const skyIslandMinY = 10000;
const skyIslandCheckIntervalSeconds: i64 = 2;

pub fn indexOf(name: []const u8) ?usize {
	for (all, 0..) |title, i| {
		if (std.ascii.eqlIgnoreCase(title.id, name)) return i;
		if (std.ascii.eqlIgnoreCase(title.display, name)) return i;
	}
	return null;
}

pub fn isUnlocked(prof: *const Entity, index: usize) bool {
	return prof.titles & (@as(u64, 1) << @intCast(index)) != 0;
}

/// True for the S0–S3 season veteran badges (externally granted, `.manual`
/// trigger). Season badges show automatically in chat and can never be worn
/// above the head; gameplay titles are the reverse.
pub fn isSeasonTitle(index: usize) bool {
	if (index >= all.len) return false;
	return all[index].trigger == .manual;
}

/// Lowest unlocked season (0–3), if any. The lowest season is the flex (S0),
/// so that is what shows in chat — never the highest.
pub fn lowestSeason(prof: *const Entity) ?u3 {
	const ids = [_][]const u8{ "s0", "s1", "s2", "s3" };
	for (ids, 0..) |id, s| {
		const idx = indexOf(id) orelse continue;
		if (isUnlocked(prof, idx)) return @intCast(s);
	}
	return null;
}

pub fn unlockedCount(prof: *const Entity) u8 {
	var n: u8 = 0;
	var mask = prof.titles;
	while (mask != 0) : (mask &= mask - 1) {
		n += 1;
	}
	return n;
}

/// Titles earned through play, excluding externally granted ones (season
/// badges). Used for Completionist and the count milestones so veteran
/// grants never fast-track gameplay rewards.
pub fn earnedTotal() usize {
	var n: usize = 0;
	for (all) |title| {
		if (title.trigger != .manual) n += 1;
	}
	return n;
}

pub fn earnedCount(prof: *const Entity) u8 {
	var n: u8 = 0;
	for (all, 0..) |title, i| {
		if (title.trigger == .manual) continue;
		if (isUnlocked(prof, i)) n += 1;
	}
	return n;
}

pub fn countFamilies(prof: *const Entity) u8 {
	const s = prof.seenBiomes orelse return 0;
	if (s.len == 0) return 0;
	var n: u8 = 1;
	for (s) |c| {
		if (c == ',') n += 1;
	}
	return n;
}

pub fn addFamily(user: *User, family: []const u8) void {
	if (family.len == 0 or family.len > 32) return;
	const prof = user.player();
	if (countFamilies(prof) >= 32) return;
	if (prof.seenBiomes) |s| {
		var it = std.mem.splitScalar(u8, s, ',');
		while (it.next()) |part| {
			if (std.mem.eql(u8, part, family)) return;
		}
		const combined = main.globalAllocator.alloc(u8, s.len + 1 + family.len);
		@memcpy(combined[0..s.len], s);
		combined[s.len] = ',';
		@memcpy(combined[s.len + 1 ..], family);
		main.globalAllocator.free(s);
		prof.seenBiomes = combined;
	} else {
		prof.seenBiomes = main.globalAllocator.dupe(u8, family);
	}
}

/// Records the player's current base biome family for Explorer. The caller
/// throttles this; a biome lookup is not free.
pub fn sampleBiome(user: *User) void {
	const prof = user.player();
	const world = main.server.world orelse return;
	const bx = main.server.anticheat.toI32(prof.pos[0]) orelse return;
	const bz = main.server.anticheat.toI32(prof.pos[1]) orelse return;
	const bv = main.server.anticheat.toI32(prof.pos[2]) orelse return;
	const biome = world.getBiome(bx, bz, bv);
	if (biome.isCave) return;
	const id = biome.id;
	const rest = if (std.mem.startsWith(u8, id, "cubyz:")) id["cubyz:".len..] else id;
	const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
	const family = rest[0..end];
	if (std.mem.eql(u8, family, "rare")) return;
	if (std.mem.eql(u8, family, "ocean")) return;
	if (std.mem.eql(u8, family, "cave")) return;
	if (std.mem.eql(u8, family, "decorative")) return;
	if (std.mem.eql(u8, family, "development")) return;
	addFamily(user, family);
}

/// Seconds on the monotonic clock used for session/playtime math (matches playtime.zig).
fn monoSeconds() i64 {
	return @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
}

/// Wall-clock seconds since the epoch, used for day tracking and time-of-day.
fn realSeconds() i64 {
	return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(main.io, .real).raw.toNanoseconds(), 1000000000));
}

pub fn currentDay() i64 {
	return @divTrunc(realSeconds(), 86400);
}

fn sessionSeconds(prof: *const Entity) i64 {
	const cur = monoSeconds();
	return if (cur > prof.login_time) cur - prof.login_time else 0;
}

fn livePlaytime(prof: *const Entity) i64 {
	return @as(i64, @intCast(prof.playtime)) + sessionSeconds(prof);
}

/// Whether the player currently stands inside a sky-island biome. Expensive, so
/// gated behind a height floor and a short per-player cooldown.
fn isInSkyIsland(user: *User) bool {
	const prof = user.player();
	// Cubyz uses index 2 as the vertical axis.
	if (prof.pos[2] < skyIslandMinY) return false;

	const now = monoSeconds();
	if (now - prof.last_sky_check < skyIslandCheckIntervalSeconds) return false;
	prof.last_sky_check = now;

	const world = main.server.world orelse return false;
	const bx = main.server.anticheat.toI32(prof.pos[0]) orelse return false;
	const bz = main.server.anticheat.toI32(prof.pos[1]) orelse return false;
	const bv = main.server.anticheat.toI32(prof.pos[2]) orelse return false;
	const biome = world.getBiome(bx, bz, bv);
	if (std.mem.indexOf(u8, biome.id, "sky_islands") != null) return true;
	if (main.Tag.get(skyIslandTagName)) |tag| {
		if (biome.hasTag(tag)) return true;
	}
	if (main.Tag.get("sky_island_fog_layer")) |tag| {
		if (biome.hasTag(tag)) return true;
	}
	return false;
}

fn isConditionMet(user: *User, title: Title) bool {
	const prof = user.player();
	return switch (title.trigger) {
		.messages => @as(f64, @floatFromInt(prof.messages_sent)) >= title.threshold,
		.afkTime => @as(f64, prof.afk_time) >= title.threshold,
		.daysPlayed => @as(f64, @floatFromInt(prof.days_played)) >= title.threshold,
		.playtime => @as(f64, @floatFromInt(livePlaytime(prof))) >= title.threshold,
		.distance => prof.distance_travelled >= title.threshold,
		.minY => if (prof.min_y) |y| @as(f64, y) <= title.threshold else false,
		.applesEaten => @as(f64, @floatFromInt(prof.apples_eaten)) >= title.threshold,
		.sessionTime => @as(f64, @floatFromInt(sessionSeconds(prof))) >= title.threshold,
		.skyIsland => isInSkyIsland(user),
		.mined => @as(f64, @floatFromInt(prof.blocksMined)) >= title.threshold,
		.placed => @as(f64, @floatFromInt(prof.blocksPlaced)) >= title.threshold,
		.explorer => @as(f64, @floatFromInt(countFamilies(prof))) >= title.threshold,
		.completionist => earnedCount(prof) == earnedTotal(),
		.trades => @as(f64, @floatFromInt(prof.shopTrades)) >= title.threshold,
		.claims => @as(f64, @floatFromInt(main.server.claims.countOwned(user.playerIndex))) >= title.threshold,
		.allianceMembers => @as(f64, @floatFromInt(main.server.alliances.ledMemberCount(user.playerIndex))) >= title.threshold,
		.voidRoots => if (prof.min_y) |y| @as(f64, y) <= title.threshold else false,
		.hermit => @as(f64, @floatFromInt(livePlaytime(prof))) >= title.threshold and prof.messages_sent == 0,
		.manual => false,
	};
}


/// Evaluates every locked title and unlocks any whose condition is now met.
/// Cheap enough to call often: all checks are simple except the sky-island one,
/// which is throttled internally.
pub fn check(user: *User) void {
	const prof = user.player();
	for (all, 0..) |title, i| {
		if (isUnlocked(prof, i)) continue;
		if (!isConditionMet(user, title)) continue;

		prof.titles |= @as(u64, 1) << @intCast(i);
		if (prof.active_title == null) {
			prof.active_title = @intCast(i);
			main.server.refreshPlayerNametag(user);
			user.sendMessage("#00ff00New title unlocked: #cfcfcf[{s}]#00ff00! It is now shown above your head.", .{title.display});
		} else {
			user.sendMessage("#00ff00New title unlocked: #cfcfcf[{s}]#00ff00! Use #cfcfcf/title#00ff00 to wear it.", .{title.display});
		}
	}
}

/// Writes the above-head nametag (active title on its own line above the
/// player's name) into `buf`. Returns null when no title is worn or the
/// buffer is too small, in which case callers fall back to the plain name.
/// Stack buffer on purpose: the result is only borrowed until serialization,
/// so this never allocates (and never leaks).
pub fn decoratedNameBuf(buf: []u8, user: *User) ?[]const u8 {
	const prof = user.player();
	const active = prof.active_title orelse return null;
	if (active >= all.len) return null;
	// Above-head nametags are reserved for gameplay titles; season badges
	// show in chat instead and can never be worn.
	if (isSeasonTitle(active)) return null;
	return std.fmt.bufPrint(buf, "[{s}]\n{s}", .{all[active].display, user.name}) catch null;
}

// --- ASHFRAME CUSTOM (nametag hardening) ---
/// Strips control bytes (<0x20) except the intentional `\n` title separator,
/// so a hostile title/display string can never smuggle layout-breaking bytes
/// into above-head nametags (vanilla crash class). Writes into `buf` (callers
/// size it >= input) and returns the used slice.
pub fn sanitizeNametag(buf: []u8, input: []const u8) []const u8 {
	var len: usize = 0;
	for (input) |c| {
		if (c < 0x20 and c != '\n') continue;
		if (len >= buf.len) break; // never overflow; input-sized bufs never hit this
		buf[len] = c;
		len += 1;
	}
	return buf[0..len];
}

test "nametag sanitize keeps newline, drops other controls" {
	var buf: [64]u8 = undefined;
	try std.testing.expectEqualStrings("[Trader]\nBob", sanitizeNametag(&buf, "[Trader]\nBob"));
	try std.testing.expectEqualStrings("[Trader]\nBob", sanitizeNametag(&buf, "[Trader]\nBob\x07\x1b"));
	try std.testing.expectEqualStrings("AB", sanitizeNametag(&buf, "A\x00B\r"));
	try std.testing.expectEqualStrings("", sanitizeNametag(&buf, "\x01\x02"));
}
// --- ASHFRAME CUSTOM (nametag hardening) ---

/// Appends the player's admin prefix (red, stands out) and/or lowest season
/// badge (quieter grey brackets) for use in the chat line. Gameplay titles
/// show above the head only, never in chat; season badges show here only.
pub fn appendChatTag(msg: *main.ListManaged(u8), user: *User) void {
	const prof = user.player();
	if (prof.prefix) |prefix| {
		msg.appendSlice("§#8a8a8a[§#e6312c");
		msg.appendSlice(prefix);
		msg.appendSlice("§#8a8a8a] ");
	}
	if (lowestSeason(prof)) |season| {
		msg.appendSlice("§#9a9a9a[§#e6e6e6S");
		msg.append(@as(u8, '0') + season);
		msg.appendSlice("§#9a9a9a] ");
	}
}
// --- ASHFRAME CUSTOM (Titles) ---
