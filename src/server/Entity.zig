const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;
const vec = main.vec;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

// --- ASHFRAME CUSTOM (Teleport costs) ---
/// How long a `/tpa` request stays valid.
pub const teleportRequestTimeoutSeconds: i64 = 30;
// --- ASHFRAME CUSTOM (Teleport costs) ---

pos: Vec3d = .{0, 0, 0},
vel: Vec3d = .{0, 0, 0},
rot: Vec3f = .{0, 0, 0},

// --- ASHFRAME CUSTOM (Fields) ---
prefix: ?[]const u8 = null,
tpa_request_from: ?usize = null,
still_time: f32 = 0.0,
is_afk: bool = false,
home_pos: ?Vec3d = null,
homeUnlocked: bool = false,
back_pos: ?Vec3d = null,
waypointPending: ?Vec3d = null,
playtime: u64 = 0,
login_time: i64 = 0,

// --- ASHFRAME CUSTOM (Progress: skills) ---
blocksMined: u64 = 0,
blocksPlaced: u64 = 0,
loginStreak: u16 = 0,
streakMonth: u32 = 0,
lastRewardDay: i64 = -1,
veteranLimboNotified: bool = false,
strikes: u8 = 0,
// Set by the chat filter on the network thread; the server thread performs
// the actual message/disconnect/save so teardown never runs off-thread.
pendingBan: bool = false,
// Set by the anticheat on the network thread after sustained speed
// violations; the server thread kicks so teardown never runs off-thread.
pendingKick: bool = false,
// Session-only (not persisted): movement-violation count + window start
// for the repeat-speeder auto-kick, plus a consecutive-over-threshold
// streak so a single laggy sample never pages the operators.
moveViolations: u32 = 0,
moveViolationWindowStart: i64 = 0,
moveViolationStreak: u8 = 0,
// Session-only (not persisted): creative-op abuse count + window start
// for the auto-kick below (sustained instant-break, creative-only packets
// from a survival account). Same pattern as the movement counters.
creativeOpViolations: u32 = 0,
creativeOpWindowStart: i64 = 0,
seenBiomes: ?[]const u8 = null,
// Session-only (not persisted):
last_biome_check: i64 = 0,
// --- ASHFRAME CUSTOM (Progress) ---

// --- ASHFRAME CUSTOM (Titles) ---
titles: u64 = 0,
active_title: ?u8 = null,
messages_sent: u32 = 0,
afk_time: f32 = 0,
days_played: u16 = 0,
last_played_day: i64 = -1,
distance_travelled: f64 = 0,
min_y: ?f32 = null,
apples_eaten: u32 = 0,
shopTrades: u32 = 0,
// Session-only (not persisted):
last_sky_check: i64 = 0,
last_track_pos: ?Vec3d = null,
// --- ASHFRAME CUSTOM (Titles) ---

// --- ASHFRAME CUSTOM (Teleport costs) ---
// Session-only (not persisted):
tpa_request_time: i64 = 0,
showClaims: bool = false,
lastClaimDraw: i64 = 0,
waypointCooldownUntil: i64 = 0,
/// Monotonic second of the last "teleport ready in Ns" notice shown while
/// standing on a waypoint/sky anchor during its cooldown. Throttles the
/// notice (a jump looks like stepping off and back on, which re-fired the
/// old once-per-stand latch every hop). Session-only, never persisted.
anchorCooldownNotifiedAt: i64 = 0,
/// Stand-on tracking for the waypoint anti-troll delay: the anchor the
/// player has been continuously above, and when the stand started
/// (monotonic seconds). Reset whenever they leave it. Session-only.
anchorStandPos: ?[3]i32 = null,
anchorStandSince: i64 = 0,
/// Async destination preload: held simulation-chunk refs while waiting for
/// the far anchor's neighborhood to load, plus which destination they were
/// requested for and when the wait started (monotonic seconds, for the
/// load timeout). The landing search touches the anchor chunk and its
/// neighbors (up to 8 distinct 32-chunks: ±1 block horizontally, +0..+3
/// vertically); holding a ref per chunk keeps each load task alive (see
/// ChunkLoadTask culling). Released on arrival, stand break, destination
/// change, or deinit. Session-only.
anchorLoadChunks: [8]?*main.server.SimulationChunk = .{null} ** 8,
anchorLoadCount: usize = 0,
anchorLoadPos: [3]i32 = .{0, 0, 0},
anchorLoadSince: i64 = 0,
/// Re-fire suppression: the destination anchor just teleported to. While
/// the player stands on it, the waypoint won't fire again — they must step
/// off (clears this) and step back on. Session-only.
anchorSuppressPos: ?[3]i32 = null,
// --- ASHFRAME CUSTOM (Teleport costs) ---
// --- ASHFRAME CUSTOM (Fields) ---

health: f32 = 8,
maxHealth: f32 = 8,
energy: f32 = 8,
maxEnergy: f32 = 8,
// --- ASHFRAME CUSTOM (Hunger): fractional drain accumulator + health-regen
// timer. In-memory only (not saved): both are small and re-accumulate within
// seconds of rejoining, and persisting them adds save-format churn. ---
hungerDebt: f32 = 0,
hungerRegenTimer: f32 = 0,
hungerStarveTimer: f32 = 0,
hungerWarnTimer: f32 = 0,
/// Edge-trigger so the "you are starving" notice is sent once per episode.
hungerStarveNotified: bool = false,
// --- ASHFRAME CUSTOM (Hunger) ---
name: ?[]const u8 = null,
id: main.entity.Entity = .noValue,

pub fn loadFrom(self: *@This(), id: main.entity.Entity, zon: ZonElement, comptime side: main.sync.Side, defaultPos: Vec3d) !void {
	self.id = id;
	self.pos = zon.get(Vec3d, "position") orelse defaultPos;
	self.vel = zon.get(Vec3d, "velocity") orelse .{0, 0, 0};
	self.rot = zon.get(Vec3f, "rotation") orelse .{0, 0, 0};
	self.health = zon.get(f32, "health") orelse self.maxHealth;
	self.energy = zon.get(f32, "energy") orelse self.maxEnergy;

	// --- ASHFRAME CUSTOM (loadFrom) ---
	self.playtime = zon.get(u64, "playtime") orelse 0;
	self.login_time = @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));

	self.titles = zon.get(u64, "titles") orelse 0;
	self.active_title = zon.get(u8, "active_title");
	self.messages_sent = zon.get(u32, "messages_sent") orelse 0;
	self.afk_time = zon.get(f32, "afk_time") orelse 0;
	self.days_played = zon.get(u16, "days_played") orelse 0;
	self.last_played_day = zon.get(i64, "last_played_day") orelse -1;
	self.distance_travelled = zon.get(f64, "distance_travelled") orelse 0;
	self.min_y = zon.get(f32, "min_y");
	self.apples_eaten = zon.get(u32, "apples_eaten") orelse 0;
	self.shopTrades = zon.get(u32, "shop_trades") orelse 0;

	self.blocksMined = zon.get(u64, "blocks_mined") orelse 0;
	self.blocksPlaced = zon.get(u64, "blocks_placed") orelse 0;
	self.loginStreak = zon.get(u16, "login_streak") orelse 0;
	self.streakMonth = zon.get(u32, "streak_month") orelse 0;
	self.lastRewardDay = zon.get(i64, "last_reward_day") orelse -1;
	self.veteranLimboNotified = zon.get(bool, "veteran_limbo_notified") orelse false;
	self.strikes = zon.get(u8, "strikes") orelse 0;
	if (zon.get([]const u8, "seen_biomes")) |s| {
		if (self.seenBiomes) |old| main.globalAllocator.free(old);
		self.seenBiomes = main.globalAllocator.dupe(u8, s);
	}
	// --- ASHFRAME CUSTOM (loadFrom) ---

	if (zon.getChildOrNull("components")) |components| {
		try main.entity.loadComponentsFromBase64(components.as([]const u8) orelse "", self.id, side);
	}

	if (zon.getChildOrNull("name")) |name| {
		if (self.name) |oldname| {
			main.globalAllocator.free(oldname);
		}
		self.name = main.globalAllocator.dupe(u8, name.as([]const u8) orelse "invalid name");
	}

	// --- ASHFRAME CUSTOM (loadFrom) ---
	self.back_pos = zon.get(Vec3d, "back_pos");
	self.homeUnlocked = zon.get(bool, "home_unlocked") orelse false;
	self.waypointPending = zon.get(Vec3d, "waypoint_pending");

	// Multi-slot saves fold into slot 1; then single-home, then legacy.
	if (zon.get(Vec3d, "home_slot_1")) |hp| {
		self.home_pos = hp;
	} else if (zon.get(Vec3d, "home_slot_2")) |hp| {
		self.home_pos = hp;
	} else if (zon.get(Vec3d, "home_slot_3")) |hp| {
		self.home_pos = hp;
	} else if (zon.get(Vec3d, "home_pos")) |hp| {
		self.home_pos = hp;
	} else {
		// Backward compatibility with the old 3-slot format: prefer whichever slot
		// was marked as the respawn point, otherwise fall back to the first filled slot.
		const legacySlots = [3]?Vec3d{
			zon.get(Vec3d, "ash_hp_0"),
			zon.get(Vec3d, "ash_hp_1"),
			zon.get(Vec3d, "ash_hp_2"),
		};
		const spawnIndex = zon.get(usize, "ash_spawn_index") orelse 0;
		if (spawnIndex < legacySlots.len and legacySlots[spawnIndex] != null) {
			self.home_pos = legacySlots[spawnIndex];
		} else {
			for (legacySlots) |slot| {
				if (self.home_pos == null) self.home_pos = slot;
			}
		}
	}

	if (zon.getChildOrNull("prefix")) |prefix_node| {
		if (self.prefix) |old| main.globalAllocator.free(old);
		self.prefix = main.globalAllocator.dupe(u8, prefix_node.as([]const u8) orelse "");
	}
	// --- ASHFRAME CUSTOM (loadFrom) ---
}
pub fn clone(self: *@This(), copy: *@This()) void {
	const originalID = copy.id;
	std.debug.assert(copy.name == null);
	copy.* = self.*;
	copy.name = if (self.name) |name| main.globalAllocator.dupe(u8, name) else null;

	// --- ASHFRAME CUSTOM (clone) ---
	copy.prefix = if (self.prefix) |p| main.globalAllocator.dupe(u8, p) else null;
	copy.seenBiomes = if (self.seenBiomes) |s| main.globalAllocator.dupe(u8, s) else null;
	// --- ASHFRAME CUSTOM (clone) ---

	copy.id = originalID;
}

pub fn save(self: *const @This(), allocator: NeverFailingAllocator, audience: main.entity.AudienceInfo) ZonElement {
	const zon = ZonElement.initObject(allocator);
	zon.put("position", self.pos);
	zon.put("velocity", self.vel);
	zon.put("rotation", self.rot);
	zon.put("health", self.health);
	zon.put("energy", self.energy);
	zon.put("id", @intFromEnum(self.id));

	// --- ASHFRAME CUSTOM (save) ---
	const current_time: i64 = @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
	const session_seconds = if (current_time > self.login_time) current_time - self.login_time else 0;
	zon.put("playtime", self.playtime + @as(u64, @intCast(session_seconds)));

	zon.put("titles", self.titles);
	if (self.active_title) |active| zon.put("active_title", active);
	zon.put("messages_sent", self.messages_sent);
	zon.put("afk_time", self.afk_time);
	zon.put("days_played", self.days_played);
	zon.put("last_played_day", self.last_played_day);
	zon.put("distance_travelled", self.distance_travelled);
	if (self.min_y) |y| zon.put("min_y", y);
	zon.put("apples_eaten", self.apples_eaten);
	zon.put("shop_trades", self.shopTrades);

	zon.put("blocks_mined", self.blocksMined);
	zon.put("blocks_placed", self.blocksPlaced);
	zon.put("login_streak", self.loginStreak);
	zon.put("streak_month", self.streakMonth);
	zon.put("last_reward_day", self.lastRewardDay);
	if (self.veteranLimboNotified) zon.put("veteran_limbo_notified", self.veteranLimboNotified);
	if (self.strikes != 0) zon.put("strikes", self.strikes);
	if (self.seenBiomes) |s| zon.put("seen_biomes", s);
	// --- ASHFRAME CUSTOM (save) ---

	var base64 = main.entity.server.componentsToBase64(allocator, self.id, audience);
	defer base64.deinit(allocator);
	zon.putOwnedString("components", base64.getEncodedMessage());

	// --- ASHFRAME CUSTOM (save) ---
	if (self.back_pos) |bp| {
		zon.put("back_pos", bp);
	}
	if (self.homeUnlocked) zon.put("home_unlocked", self.homeUnlocked);
	if (self.waypointPending) |wp| zon.put("waypoint_pending", wp);
	if (self.home_pos) |hp| {
		zon.put("home_pos", hp);
	}
	if (self.prefix) |p| {
		zon.put("prefix", p);
	}
	// --- ASHFRAME CUSTOM (save) ---

	if (self.name) |name| {
		zon.put("name", name);
	}
	return zon;
}
pub fn deinit(self: *@This(), comptime side: main.sync.Side) void {
	// --- ASHFRAME CUSTOM (deinit) ---
	if (self.prefix) |p| {
		main.globalAllocator.free(p);
		self.prefix = null;
	}
	if (self.seenBiomes) |s| {
		main.globalAllocator.free(s);
		self.seenBiomes = null;
	}
	// --- ASHFRAME CUSTOM (deinit) ---

	if (self.name) |name| {
		main.globalAllocator.free(name);
		self.name = null;
	}
	if (side == .server) {
		for (self.anchorLoadChunks[0..self.anchorLoadCount]) |slot| {
			if (slot) |held| held.decreaseRefCount();
		}
		self.anchorLoadChunks = .{null} ** 8;
		self.anchorLoadCount = 0;
		main.entity.server.removeAllComponents(self.id);
	} else {
		main.entity.client.removeAllComponents(self.id);
	}
}
