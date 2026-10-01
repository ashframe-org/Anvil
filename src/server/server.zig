const std = @import("std");
const Atomic = std.atomic.Value;

const main = @import("main");
const chunk = main.chunk;
const network = main.network;
const Connection = network.Connection;
const ConnectionManager = network.ConnectionManager;
const InventoryId = main.items.Inventory.InventoryId;
const utils = main.utils;
const vec = main.vec;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;
const BinaryReader = main.utils.BinaryReader;
const BinaryWriter = main.utils.BinaryWriter;
const Blueprint = main.blueprint.Blueprint;
const Mask = main.blueprint.Mask;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const CircularBufferQueue = main.utils.CircularBufferQueue;
const sync = main.sync;

pub const BlockUpdateSystem = @import("BlockUpdateSystem.zig");
pub const world_zig = @import("world.zig");
pub const ServerWorld = world_zig.ServerWorld;
pub const terrain = @import("terrain/terrain.zig");
pub const Entity = @import("Entity.zig");
pub const SimulationChunk = @import("SimulationChunk.zig");
pub const stdin_handler = @import("stdin_handler.zig");
pub const storage = @import("storage.zig");
pub const permission = @import("permission.zig");
pub const players = @import("players.zig");
pub const BlockDrop = @import("BlockDrop.zig");
pub const emojis = @import("emojis.zig");
pub const titles = @import("titles.zig");
pub const progress = @import("progress.zig");
pub const claims = @import("claims.zig");
pub const veterans = @import("veterans.zig");
pub const waypoints = @import("waypoints.zig");
pub const chatfilter = @import("chatfilter.zig");
pub const shrines = @import("shrines.zig");
pub const shops = @import("shops.zig");
pub const anticheat = @import("anticheat.zig");
pub const report = @import("report.zig");
pub const metrics = @import("metrics.zig");
pub const alliances = @import("alliances.zig");

pub const command = @import("command.zig");

pub const WorldEditData = struct {
	const maxWorldEditHistoryCapacity: u32 = 1024;

	selectionPosition1: ?Vec3i = null,
	selectionPosition2: ?Vec3i = null,
	clipboard: ?Blueprint = null,
	undoHistory: History,
	redoHistory: History,
	mask: ?Mask = null,

	const History = struct {
		changes: CircularBufferQueue(Value),

		const Value = struct {
			blueprint: Blueprint,
			position: Vec3i,
			message: []const u8,

			pub fn init(blueprint: Blueprint, position: Vec3i, message: []const u8) Value {
				return .{.blueprint = blueprint, .position = position, .message = main.globalAllocator.dupe(u8, message)};
			}
			pub fn deinit(self: Value) void {
				main.globalAllocator.free(self.message);
				self.blueprint.deinit(main.globalAllocator);
			}
			pub fn selection(self: Value) Blueprint.Selection {
				return .initFromExtent(self.position, self.blueprint.extent());
			}
		};
		pub fn init() History {
			return .{.changes = .init(main.globalAllocator, maxWorldEditHistoryCapacity)};
		}
		pub fn deinit(self: *History) void {
			self.clear();
			self.changes.deinit();
		}
		pub fn clear(self: *History) void {
			while (self.changes.popFront()) |item| item.deinit();
		}
		pub fn push(self: *History, value: Value) void {
			if (self.changes.reachedCapacity()) {
				if (self.changes.popFront()) |oldValue| oldValue.deinit();
			}

			self.changes.pushBack(value);
		}
		pub fn pop(self: *History) ?Value {
			return self.changes.popBack();
		}
	};
	pub fn init() WorldEditData {
		return .{.undoHistory = History.init(), .redoHistory = History.init()};
	}
	pub fn deinit(self: *WorldEditData) void {
		if (self.clipboard != null) {
			self.clipboard.?.deinit(main.globalAllocator);
		}
		self.undoHistory.deinit();
		self.redoHistory.deinit();
		if (self.mask) |mask| {
			mask.deinit(main.globalAllocator);
		}
	}
};

pub const PlayerIndex = usize;

/// Maps a player's observed speed to an effective render distance (in chunks):
/// the full client value at/below `dynamicRdFullSpeed`, shrinking linearly to
/// `dynamicRdMinChunks` at `dynamicRdMinSpeed`. Local players and staff keep the
/// full distance. This is what keeps fast movers (falls, hyperspeed) from
/// saturating chunk generation/streaming.
fn dynamicRenderDistanceFor(user: *User) u16 {
	const clientRD = user.renderDistance;
	if (!main.settings.launchConfig.dynamicRenderDistance) return clientRD;
	// Applies to everyone, including the singleplayer host and staff: both still
	// pay for chunk generation (in singleplayer it shares the CPU with the
	// client), and exempting them meant the feature never engaged while testing.
	const now = anticheat.nowMilliseconds();
	var rd: u16 = clientRD;

	// 1. Velocity: how fast the player is actually covering ground.
	if (clientRD > User.dynamicRdMinChunks) {
		const speed = user.observedSpeed;
		if (speed > User.dynamicRdFullSpeed) {
			const t = @min(1.0, (speed - User.dynamicRdFullSpeed)/(User.dynamicRdMinSpeed - User.dynamicRdFullSpeed));
			const minRD: f64 = @floatFromInt(User.dynamicRdMinChunks);
			const fullRD: f64 = @floatFromInt(clientRD);
			rd = @min(rd, @as(u16, @intFromFloat(@max(minRD, fullRD - t*(fullRD - minRD)))));
		}
	}

	// 2. Teleport ramp: a short low-distance window after any teleport.
	rd = @min(rd, user.teleportRampRD(now));

	// 3. Server load: one global cap derived from real server pressure, so a
	//    teleport burst or many fast players can't overload it (velocity alone
	//    can't see that, e.g. a stationary player after a teleport).
	const loadCap = main.server.metrics.loadRenderDistance.load(.monotonic);
	if (loadCap != 0) rd = @min(rd, loadCap);

	// Absolute floor: always keep the immediate area.
	return @min(clientRD, @max(rd, User.dynamicRdAbsFloor));
}

// --- ASHFRAME CUSTOM (default command permissions) ---
// Upstream's "default" group grants /command/avatar and /command/help, so only
// our custom commands need explicit grants here. Runs on every join (see
// initPlayer): permissions persist per player, so first-join-only grants would
// never reach existing players when the list changes.
fn ensureDefaultCommandPermissions(id: main.entity.Entity) void {
	const perms = main.entity.components.@"cubyz:permissions".server;
	const defaults = [_][]const u8{
		"/command/home", "/command/sethome", "/command/delhome", "/command/homes",
		"/command/waypoint", "/command/tpa", "/command/tpaccept", "/command/back",
		"/command/players", "/command/playtime", "/command/stats", "/command/afk", "/command/tpdeny",
		"/command/msg", "/command/alliance", "/command/claim", "/command/eat",
		"/command/titles", "/command/title", "/command/shop",
		// Note: "/command/veteran" is granted so admins can invoke it, but the
		// command additionally gates on "/ashframe/admin/veteran" (NOT granted
		// by default), same pattern as /prefix and /spawn.
		"/command/veteran",
		// Note: "/command/spawn" is granted so players can teleport to spawn,
		// but spawn.zig gates setting spawn points / moving world spawn behind
		// "/ashframe/admin/spawn", which is NOT granted by default.
		"/command/spawn",
	};
	for (defaults) |path| perms.addPermission(id, .white, path);
	// "/command/prefix" is NOT a default: prefix.zig gates everything behind
	// "/ashframe/admin/prefix", so the command grant alone only exposes it in
	// /help and then denies inside. Strip it unless the player was explicitly
	// given prefix powers (in which case /perm put it there deliberately).
	if (!perms.hasPermission(id, "/ashframe/admin/prefix")) {
		_ = perms.removePermission(id, .white, "/command/prefix");
	}
}
// --- ASHFRAME CUSTOM (default command permissions) ---

pub const User = struct { // MARK: User
	const maxSimulationDistance = 8;
	const simulationSize = 2*maxSimulationDistance;
	const simulationMask = simulationSize - 1;
	conn: *Connection = undefined,
	innerPlayer: Entity = .{},
	timeDifference: utils.TimeDifference = .{},
	interpolation: utils.GenericInterpolation(3) = undefined,
	lastTime: i16 = undefined,
	lastSaveTime: std.Io.Timestamp = .fromNanoseconds(0),
	name: []const u8 = "",
	// Default matches the client default; replaced by the client's real value on
	// the first chunk request. A defined default matters now that the dynamic
	// render distance reads this from `checkMovement` before any request.
	renderDistance: u16 = 12,
	clientUpdatePos: Vec3i = .{0, 0, 0},
	receivedFirstEntityData: bool = false,
	isLocal: bool = false,
	id: main.entity.Entity = .noValue,
	// TODO: ipPort: []const u8,
	loadedChunks: [simulationSize][simulationSize][simulationSize]*SimulationChunk = undefined,
	lastRenderDistance: u16 = 0,
	lastPos: Vec3i = @splat(0),
	gamemode: std.atomic.Value(main.game.Gamemode) = .init(.creative),
	spawnPos: ?Vec3d = null,
	worldEditData: WorldEditData = undefined,

	playerIndex: PlayerIndex = undefined,

	jobQueue: main.utils.ConcurrentMaxHeap(main.utils.ThreadPool.Task) = undefined,
	jobQueueScheduled: bool = false,
	jobQueueLastUpdate: struct { position: Vec3i, time: std.Io.Timestamp, alreadyInUpdate: bool = false } = .{.position = @splat(0), .time = .{.nanoseconds = 0}},

	lastSentBiomeId: u32 = 0xffffffff,

	newKeyString: ?[]const u8 = null,
	key: network.authentication.PublicKey = undefined,
	legacyKey: ?network.authentication.PublicKey = null,
	// --- ASHFRAME CUSTOM (UX-6: asset pack skip) ---
	/// Pack hash announced by custom clients that already cache our assets.
	/// Null = vanilla/uncached: always send the full pack.
	ashframePackHash: ?u64 = null,
	// --- ASHFRAME CUSTOM (UX-6) ---
	// --- ASHFRAME CUSTOM (capability handshake) ---
	/// Argon capability version announced in userData (`ashframeClientVersion`).
	/// Null = vanilla (or pre-versioning Argon): stock payloads only.
	/// Bump `minArgonVersion` when depending on newer client features.
	ashframeClientVersion: ?u16 = null,
	// --- ASHFRAME CUSTOM (capability handshake) ---
	// --- ASHFRAME CUSTOM (drop interest gating) ---
	/// Drops this player has received an add for. Removes go only to players
	/// with the bit set (they are the only ones that can hold the drop);
	/// adds go only to in-range players without the bit; a 2 s sweep covers
	/// players who walk into range. 8 KB inline, no alloc/deinit needed.
	seenDrops: std.bit_set.ArrayBitSet(usize, main.itemdrop.ItemDropManager.maxCapacity) = .empty,
	// --- ASHFRAME CUSTOM (drop interest gating) ---

	inventoryClientToServerIdMap: std.AutoHashMap(InventoryId, InventoryId) = undefined,
	inventory: ?InventoryId = null,
	handInventory: ?InventoryId = null,

	connected: Atomic(bool) = .init(true),
	/// `pause()` destroys inventories and deinits the id map, so it MUST only run
	/// once. It can be reached from `deferredPauseAndDeinit` and again from
	/// `connectionManager.pause() -> Connection.pause() -> User.pause()`, which
	/// double-freed everything on shutdown.
	paused: bool = false,
	state: State = .awaitingKeyVerification,

	mutex: main.utils.Mutex = .{},

	inventoryCommands: main.List([]const u8) = .empty,

	// --- ASHFRAME CUSTOM (Anticheat) ---
	anticheatLastPos: ?[3]f64 = null,
	anticheatLastTime: i64 = 0,
	teleportGraceUntil: i64 = 0,
	// --- ASHFRAME CUSTOM (Anticheat: flight pattern) ---
	// Consecutive position updates looking like sustained flight (fast
	// horizontal, not falling) for a server-side survival player. Log-only.
	flyStreak: u16 = 0,
	// --- ASHFRAME CUSTOM (Anticheat) ---
	// Cached on the server thread (permissions can't be read off-thread).
	anticheatStaff: bool = false,
	rateChat: anticheat.TokenBucket = .{.capacity = 12, .refillPerSec = 6},
	rateCommand: anticheat.TokenBucket = .{.capacity = 20, .refillPerSec = 10},
	/// Retired: inventory/crafting traffic bypasses rate limiting entirely
	/// (dropping it left the client's optimistic change hanging with no
	/// reply). Kept so the shape of the struct — and any future re-use —
	/// stays obvious.
	rateInventory: anticheat.TokenBucket = .{.capacity = 600, .refillPerSec = 240},
	/// Block place/break shares the inventory protocol but gets its own
	/// generous bucket so fast builders are never flagged as inventory floods.
	rateBlock: anticheat.TokenBucket = .{.capacity = 900, .refillPerSec = 450},
	/// Retired: damage reports bypass rate limiting entirely (see
	/// protocols.zig). Kept for introspection only.
	rateDamage: anticheat.TokenBucket = .{.capacity = 600, .refillPerSec = 240},
	/// Per-category mute timestamps for high-frequency anticheat logging, so a
	/// fast player can't generate 20 notes/second (each a log + allocations +
	/// O(n) report bookkeeping) and stall the tick.
	noteMuteUntilMs: [std.meta.fields(anticheat.Category).len]i64 = @splat(0),
	// --- ASHFRAME CUSTOM (Anticheat) ---

	// --- ASHFRAME CUSTOM (Dynamic render distance) ---
	/// Latest observed speed (blocks/s), measured on the network thread in
	/// `checkMovement`. Drives the dynamic render distance.
	observedSpeed: f64 = 0,
	/// Teleport view ramp window (set by `beginTeleportViewRamp`).
	teleportRampStartMs: i64 = 0,
	teleportRampUntil: i64 = 0,
	/// Effective render distance currently allowed for this player, in chunks.
	/// Read from worker threads (`ChunkLoadTask.isStillNeeded`), hence atomic.
	/// 0 means "not computed yet" (treat as the client's full render distance).
	dynamicRenderDistance: std.atomic.Value(u16) = .init(0),
	/// Chunk requests held back because they were outside `dynamicRenderDistance`
	/// while the player was moving fast. Re-queued when they slow down again, so
	/// this never permanently withholds a chunk the client is still waiting for.
	deferredChunks: main.List(main.chunk.ChunkPosition) = .empty,
	/// Ticks counter used to run the (potentially O(n)) held-chunk pass less often.
	deferredTick: u8 = 0,
	/// Whether this player should get chat feedback when the dynamic render
	/// distance changes (cached on the server thread; operators get it).
	perfDebug: bool = false,
	lastSentEffectiveRD: u16 = 0,
	lastViewDebugMs: i64 = 0,
	// --- ASHFRAME CUSTOM (Dynamic render distance) ---

	pub const State = enum { awaitingKeyVerification, connectedVerified, awaitingReloadVerified };

	// --- ASHFRAME CUSTOM (Dynamic render distance tunables) ---
	/// Never shrink the effective render distance below this many chunks.
	pub const dynamicRdMinChunks: u16 = 10;
	/// No shrinking at or below this speed (blocks/s). Above creative fly (32),
	/// so walking/sprinting/creative flight are never affected.
	pub const dynamicRdFullSpeed: f64 = 40;
	/// Speed at which the minimum render distance is reached. Covers terminal
	/// falls (~90) and hyperspeed/ghost (~128).
	pub const dynamicRdMinSpeed: f64 = 128;
	/// Per-player cap on held-back requests. Kept high so it is never the thing
	/// that silently drops a leading-edge request the client is waiting for.
	pub const maxDeferredChunks: usize = 32768;
	/// Held-back requests promoted into the queue per tick. Rate-limiting the
	/// drain means a big backlog comes back smoothly instead of spiking the queue
	/// (which used to trick the load cap into collapsing again).
	pub const maxPromotionsPerTick: usize = 64;
	/// Absolute floor: the immediate area is always served, even under load or
	/// right after a teleport (the velocity term has its own, higher, floor).
	pub const dynamicRdAbsFloor: u16 = 4;
	/// Teleport view ramp: start low and expand to the client's own distance,
	/// giving the server time to generate the destination before it expands.
	pub const teleportRampFromRD: u16 = 5;
	pub const teleportRampDurationMs: i64 = 3000;
	// --- ASHFRAME CUSTOM (Dynamic render distance tunables) ---

	pub fn player(self: *User) *Entity {
		return &self.innerPlayer;
	}

	// --- ASHFRAME CUSTOM (capability handshake) ---
	/// Minimum Argon client version we gate features on. Bump when
	/// depending on newer client capabilities.
	pub const minArgonVersion: u16 = 1;

	/// True for Argon clients at/above the supported version. Vanilla (and
	/// pre-versioning Argon) get stock payloads only.
	pub fn isArgon(self: *const User) bool {
		const v = self.ashframeClientVersion orelse return false;
		return v >= minArgonVersion;
	}
	// --- ASHFRAME CUSTOM (capability handshake) ---

	/// Starts the teleport view ramp. Called from the single teleport choke point
	/// (`genericUpdate.sendTPCoordinates`), so every teleport - command or block -
	/// is covered without the client having to say anything.
	pub fn beginTeleportViewRamp(self: *User) void {
		const now = anticheat.nowMilliseconds();
		self.teleportRampStartMs = now;
		self.teleportRampUntil = now + teleportRampDurationMs;
	}

	/// The player's current server-side block position. Used for every
	/// "is this chunk still wanted?" decision instead of `clientUpdatePos`, which
	/// stops updating whenever the client stops sending chunk requests (e.g. while
	/// it is stalled) and would then point at the wrong place entirely.
	pub fn livePosBlock(self: *User) Vec3i {
		const pos = self.player().pos;
		return .{
			anticheat.toI32(pos[0]) orelse 0,
			anticheat.toI32(pos[1]) orelse 0,
			anticheat.toI32(pos[2]) orelse 0,
		};
	}

	/// Extra chunks of slack added to every keep/drop radius, sized so a
	/// high-latency client's (legitimately) further-ahead view is honoured and a
	/// low-latency client is unaffected.
	pub fn latencyKeepMarginChunks(self: *User) f64 {
		const base: f64 = 2.0;
		const conn = self.conn;
		if (!conn.hasRttEstimate) return base;
		const rttMs = (@as(f64, conn.rttEstimate) + @as(f64, conn.rttUncertainty))/1000.0;
		const speed = @max(self.observedSpeed, 4.0);
		const blocksAhead = (rttMs/1000.0)*speed;
		const chunks = blocksAhead/@as(f64, @floatFromInt(main.chunk.chunkSize));
		return base + @min(chunks, 2.0);
	}

	/// How far (in blocks) a chunk of `voxelSize` may be from the player and still
	/// be considered as still wanted. Never depends on the throttled effective
	/// distance, so throttling can only delay delivery, never drop a request.
	pub fn keepRadiusBlocks(self: *User, voxelSize: u31) f64 {
		const margin = self.latencyKeepMarginChunks();
		return (@as(f64, @floatFromInt(self.renderDistance)) + margin) *
			@as(f64, @floatFromInt(main.chunk.chunkSize)) *
			@as(f64, @floatFromInt(voxelSize));
	}

	// --- ASHFRAME CUSTOM (interest gating) ---
	/// Interest gate for block/item/entity broadcasts: true if the block is
	/// inside this player's keep radius (they have, or are loading, the chunk)
	/// and their connection is live. Far-away clients dropped these packets
	/// anyway (no mesh -> ignored; unknown entity/drop -> skipped), so not
	/// sending them only saves N× traffic on reliable channels. The radius is
	/// deliberately larger than the client's render distance, so no VISIBLE
	/// update is ever gated.
	pub fn canSeeBlock(self: *User, wx: i32, wy: i32, wz: i32) bool {
		if (self.conn.connectionState.load(.monotonic) != .connected) return false;
		const p = self.livePosBlock();
		const r = self.keepRadiusBlocks(1);
		const dx: f64 = @floatFromInt(@as(i64, wx) - @as(i64, p[0]));
		const dy: f64 = @floatFromInt(@as(i64, wy) - @as(i64, p[1]));
		const dz: f64 = @floatFromInt(@as(i64, wz) - @as(i64, p[2]));
		return dx*dx + dy*dy + dz*dz <= r*r;
	}
	// --- ASHFRAME CUSTOM (interest gating) ---

	/// Effective distance forced by an active teleport ramp: starts at
	/// `teleportRampFromRD` and expands linearly to the client's distance.
	fn teleportRampRD(self: *User, now: i64) u16 {
		if (now >= self.teleportRampUntil) return self.renderDistance;
		const span = @as(f64, @floatFromInt(self.teleportRampUntil - self.teleportRampStartMs));
		const elapsed = @as(f64, @floatFromInt(now - self.teleportRampStartMs));
		const t = if (span > 0) @min(1.0, @max(0.0, elapsed/span)) else 1.0;
		const from = @as(f64, @floatFromInt(teleportRampFromRD));
		const to = @as(f64, @floatFromInt(self.renderDistance));
		return @intFromFloat(@max(0.0, from + t*(to - from)));
	}

	/// Recomputes and stores this player's effective render distance from their
	/// speed. Network thread only (`user.renderDistance`/`observedSpeed` live there).
	pub fn refreshDynamicRenderDistance(self: *User) void {
		self.dynamicRenderDistance.store(dynamicRenderDistanceFor(self), .monotonic);
	}

	/// Holds back a chunk request that is outside the current effective render
	/// distance. Bounded, so a flood can't grow it without limit.
	pub fn deferChunk(self: *User, pos: main.chunk.ChunkPosition) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		if (self.deferredChunks.items.len >= maxDeferredChunks) return;
		self.deferredChunks.append(main.globalAllocator, pos);
	}

	/// Server thread: re-queue held-back requests that are now within range, and
	/// drop ones the client has since moved past. Never runs while holding
	/// `self.mutex` (queueing locks it). Promotes only, so it can never stall
	/// streaming the way a dropping cap did.
	pub fn processDeferredChunks(self: *User) void {
		self.mutex.lock();
		if (self.deferredChunks.items.len == 0) {
			self.mutex.unlock();
			return;
		}
		const pending = self.deferredChunks;
		self.deferredChunks = .empty;
		self.mutex.unlock();
		defer pending.deinit(main.globalAllocator);

		const effRaw = self.dynamicRenderDistance.load(.monotonic);
		const eff = if (effRaw == 0) self.renderDistance else effRaw;
		// Fresh position, NOT `clientUpdatePos` (which freezes when the client is
		// stalled, causing exactly the chunks around the player to be discarded).
		const pos = self.livePosBlock();
		const chunkSizeF = @as(f64, @floatFromInt(main.chunk.chunkSize));
		var budget: usize = maxPromotionsPerTick;
		var keep: main.List(main.chunk.ChunkPosition) = .empty;
		defer keep.deinit(main.globalAllocator);
		for (pending.items) |req| {
			const minDist = @as(f64, @floatFromInt(req.getMinDistanceSquared(pos)));
			const voxelSize = @as(f64, @floatFromInt(req.voxelSize));
			// Promote when inside the throttled distance (+1 chunk slack).
			const effRadius = (@as(f64, @floatFromInt(eff)) + 1.0)*chunkSizeF*voxelSize;
			if (minDist <= effRadius*effRadius) {
				if (budget > 0) {
					budget -= 1;
					if (main.server.world) |serverWorld| serverWorld.queueChunk(req, self);
					continue; // queued -> no longer held
				}
				// Over this tick's budget: keep for the next tick.
			}
			// Keep anything the client could still want (its own distance +
			// latency margin). Only genuinely passed chunks are discarded.
			const keepRadius = self.keepRadiusBlocks(req.voxelSize);
			if (minDist <= keepRadius*keepRadius) {
				keep.append(main.globalAllocator, req);
			} else {
				metrics.noteHeldDiscarded();
			}
		}
		self.requeueDeferred(keep.items);
	}

	/// Server thread: if this player is an operator and their effective render
	/// distance changed, tell them (chat + log), throttled. `lastSentEffectiveRD
	/// == 0` is the "not yet reported" sentinel, so the first value is silent.
	fn maybeSendViewDebugMessage(self: *User) void {
		if (!self.perfDebug) return;
		const eff = self.dynamicRenderDistance.load(.monotonic);
		if (eff == 0) return;
		if (self.lastSentEffectiveRD == 0) {
			self.lastSentEffectiveRD = eff;
			return;
		}
		const capped = eff < self.renderDistance;
		const changed = eff != self.lastSentEffectiveRD;
		const now = anticheat.nowMilliseconds();
		const speed = self.observedSpeed;
		if (changed) {
			if (now - self.lastViewDebugMs < 500) return;
		} else {
			// Heartbeat every 10 s while capped, so a steady cap is still visible.
			if (!capped or now - self.lastViewDebugMs < 10000) return;
		}
		self.lastViewDebugMs = now;
		const prev = self.lastSentEffectiveRD;
		self.lastSentEffectiveRD = eff;
		if (!changed) {
			self.sendMessage("#8a8a8a[perf] view #cfcfcf{d}/{d} chunks #8a8a8a· speed #cfcfcf{d:.0} b/s", .{ eff, self.renderDistance, speed });
		} else if (capped) {
			self.sendMessage("#8a8a8a[perf] view #cfcfcf{d} #8a8a8a→ #e6312c{d} chunks #cfcfcf(speed {d:.0} b/s; full ≤{d:.0}, min {d})", .{
				self.renderDistance, eff, speed, dynamicRdFullSpeed, dynamicRdMinChunks,
			});
		} else {
			self.sendMessage("#8a8a8a[perf] view #e6312c{d} #8a8a8a→ #00ff00{d} chunks #cfcfcf(speed {d:.0} b/s)", .{
				prev, eff, speed,
			});
		}
		std.log.info("[perf] {s} view {d} (client {d}), speed {d:.0} b/s", .{ self.name, eff, self.renderDistance, speed });
	}

	fn requeueDeferred(self: *User, chunks: []const main.chunk.ChunkPosition) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		for (chunks) |req| {
			if (self.deferredChunks.items.len >= maxDeferredChunks) break;
			self.deferredChunks.append(main.globalAllocator, req);
		}
	}


	pub fn init(manager: *ConnectionManager, ipPort: []const u8) !*User {
		const self = main.globalAllocator.create(User);
		errdefer main.globalAllocator.destroy(self);
		self.* = .{};
		self.conn = try Connection.init(manager, ipPort, self);
		self.@"continue"();
		network.protocols.handShake.serverSide(self.conn);
		return self;
	}
	pub fn @"continue"(self: *User) void {
		// reset
		self.* = .{
			.conn = self.conn,
			.name = self.name,
			.newKeyString = self.newKeyString,
			.playerIndex = self.playerIndex,
			.state = self.state,

			.inventoryClientToServerIdMap = .init(main.globalAllocator.allocator),
			.worldEditData = .init(),
			.jobQueue = .init(main.globalAllocator),
		};
	}
	fn privateDeinit(self: *User) void {
		// Make sure this user can never be sent to after its connection is freed.
		forceRemoveFromUserList(self);
		self.conn.deinit();
		main.globalAllocator.free(self.name);
		if (self.newKeyString) |str| main.globalAllocator.free(str);
		main.globalAllocator.destroy(self);
	}
	pub fn deferredPauseAndDeinit(self: *User) void {
		self.conn.disconnect();
		// Tear down synchronously while the server thread and world are alive.
		// Deferring `pause` through the GC ran it after the world was destroyed
		// (and after this user's memory was freed), which crashed teardown with
		// an inventory assert. `pause` saves the player, so no separate save here.
		self.pause();
		main.heap.GarbageCollection.deferredFree(.{.ptr = self, .freeFunction = main.meta.castFunctionSelfToAnyopaque(privateDeinit)});
	}
	pub fn pause(self: *User) void {
		// Idempotent: teardown frees inventories/maps, so a second call (e.g. via
		// `Connection.pause` during server shutdown) must be a no-op.
		if (self.paused) return;
		self.paused = true;
		self.state = switch (self.state) {
			.awaitingKeyVerification => .awaitingKeyVerification,
			.connectedVerified => .awaitingReloadVerified,
			.awaitingReloadVerified => .awaitingReloadVerified,
		};

		self.clearJobQueue();

		main.items.Inventory.server.disconnectUser(self);
		if (self.inventoryClientToServerIdMap.count() != 0) {
			std.log.err("Inventory map leak on disconnect: {d} entries.", .{self.inventoryClientToServerIdMap.count()});
		}
		self.inventoryClientToServerIdMap.deinit();

		if (self.inventory != null) {
			world.?.savePlayer(self) catch |err| {
				std.log.err("Failed to save player: {s}", .{@errorName(err)});
				return;
			};

			main.items.Inventory.server.destroyExternallyManagedInventory(self.inventory.?);
			main.items.Inventory.server.destroyExternallyManagedInventory(self.handInventory.?);
		}

		self.worldEditData.deinit();

		if (self.player().id != .noValue) {
			self.player().deinit(.server);
		}

		self.unloadOldChunk(.{0, 0, 0}, 0);
		for (self.inventoryCommands.items) |commandData| {
			main.globalAllocator.free(commandData);
		}
		self.inventoryCommands.deinit(main.globalAllocator);
		self.deferredChunks.deinit(main.globalAllocator);

		self.jobQueue.deinit();
	}

	pub fn identifyFromKeysAndName(self: *User, name: []const u8, keys: main.ZonElement, whitelistEnabled: bool) !void {
		std.debug.assert(self.name.len == 0);
		self.name = main.globalAllocator.dupe(u8, name);
		var allowedToJoin = !whitelistEnabled;
		{
			const keyBase64 = keys.get([]const u8, @tagName(main.settings.launchConfig.preferredAuthenticationAlgorithm)) orelse return error.PublicKeyNotPresent;
			self.key = try .initFromBase64(keyBase64, main.settings.launchConfig.preferredAuthenticationAlgorithm);
			self.newKeyString = main.globalAllocator.print("{s}:{s}", .{@tagName(main.settings.launchConfig.preferredAuthenticationAlgorithm), keyBase64});
		}
		var foundKey: bool = false;
		for (std.meta.fieldNames(main.network.authentication.KeyTypeEnum)) |keyTypeName| {
			const keyBase64 = keys.get([]const u8, keyTypeName) orelse continue;
			const keyWithType = main.stackAllocator.print("{s}:{s}", .{keyTypeName, keyBase64});
			defer main.stackAllocator.free(keyWithType);
			const lookup = main.server.players.lookupIndex(keyWithType) orelse continue;
			self.playerIndex = lookup.playerIndex;
			allowedToJoin = !lookup.blocked;
			foundKey = true;
			const keyType = std.meta.stringToEnum(main.network.authentication.KeyTypeEnum, keyTypeName).?;
			if (keyType == self.key) break;
			self.legacyKey = try .initFromBase64(keyBase64, keyType);
			break;
		}
		if (!foundKey) {
			if (main.server.players.isEmpty()) { // Claim the local player
				std.log.info("Here", .{});
				self.playerIndex = main.server.players.getLocalPlayerIndex();
				allowedToJoin = true;
			} else {
				const nameEntry = main.stackAllocator.print("name:{s}", .{name});
				defer main.stackAllocator.free(nameEntry);
				if (main.server.players.lookupIndex(nameEntry)) |lookup| {
					// Legacy name-only record: logged so operators can see if it's abused.
					main.server.anticheat.note(self, .protocol, "adopted a name-only (legacy) player record");
					self.playerIndex = lookup.playerIndex;
					allowedToJoin = !lookup.blocked;
				} else {
					self.playerIndex = main.server.players.allocateNewIndex();
				}
			}
		}
		if (!allowedToJoin) {
			std.log.info("Rejected connection from '{s}' ({s})", .{name, self.newKeyString.?});
			return error.NotWhitelisted;
		}
	}

	pub fn identifyAsLocal(self: *User, name: []const u8) !void {
		std.debug.assert(self.name.len == 0);
		self.name = main.globalAllocator.dupe(u8, name);
		self.playerIndex = main.server.players.getLocalPlayerIndex();
	}

	pub fn verifySignatures(self: *User, reader: *BinaryReader) !void {
		try self.key.verifySignature(reader, self.conn.secureChannel.verificationDataForClientSignature.items);
		if (self.legacyKey) |key| {
			try key.verifySignature(reader, self.conn.secureChannel.verificationDataForClientSignature.items);
		}
	}

	var freeId: u32 = 0; // TODO: Use id provided by the ECS.
	pub fn initPlayer(self: *User) void {
		self.id = @enumFromInt(freeId);
		freeId += 1;

		world.?.loadPlayer(self) catch {
			std.log.err("Error while loading player data of {s}. Discarding data.", .{self.name});
		};
		if (main.entity.components.@"cubyz:model".server.get(self.id) == null) {
			if (main.entityModel.playerEntityModels.items.len != 0) {
				const defaultModel = main.entityModel.playerEntityModels.items[main.random.nextIntBounded(u32, &main.seed, @intCast(main.entityModel.playerEntityModels.items.len))];
				main.entity.components.@"cubyz:model".server.put(self.id, .{.entityModel = defaultModel});
			}
		}
		if (main.entity.components.@"cubyz:bag".server.get(self.id) == null) {
			main.entity.components.@"cubyz:bag".server.loadEmpty(self.id);
		}
		if (main.entity.components.@"cubyz:permissions".server.get(self.id) == null) {
			main.entity.components.@"cubyz:permissions".server.loadEmpty(self.id);
		}
		// --- ASHFRAME CUSTOM (default command permissions) ---
		// Runs on EVERY join, not just the first: permissions persist per
		// player, so a grant added later (e.g. /command/alliance) would
		// otherwise never reach existing players. addPermission is a map put
		// (idempotent); groups, the operator wildcard and /ashframe/admin/*
		// paths are never touched here.
		ensureDefaultCommandPermissions(self.id);
		// --- ASHFRAME CUSTOM (default command permissions) ---
		main.entity.components.@"cubyz:permissions".server.addToGroup(self.id, permission.Group.default);

		// --- ASHFRAME CUSTOM (Server owner bootstrap) ---
		// The account key in launchConfig `serverOwnerKey` gets full
		// permissions ("/", i.e. console-equivalent) on every join. This is
		// the only way to bootstrap an admin on a dedicated server: group
		// membership otherwise needs an existing admin to grant it.
		// addPermission is a map put (idempotent). Key-based, so name/color
		// changes don't break it.
		if (main.settings.launchConfig.serverOwnerKey.len != 0) {
			if (self.newKeyString) |key| {
				if (std.mem.eql(u8, key, main.settings.launchConfig.serverOwnerKey)) {
					main.entity.components.@"cubyz:permissions".server.addPermission(self.id, .white, "/");
				}
			}
		}
		// --- ASHFRAME CUSTOM (Server owner bootstrap) ---

		if (self.isLocal) {
			main.entity.components.@"cubyz:permissions".server.addToGroup(self.id, permission.Group.moderator);
			if (world.?.settings.allowCheats) {
				main.entity.components.@"cubyz:permissions".server.addPermission(self.id, .white, "/");
			}
		}

		self.interpolation.init(@ptrCast(&self.player().pos), @ptrCast(&self.player().vel));
		self.loadUnloadChunks();

		main.entity.components.@"cubyz:player".server.load(self.id, @truncate(self.playerIndex));
	}

	fn simArrIndex(x: i32) usize {
		return @intCast(x >> chunk.chunkShift & simulationMask);
	}

	fn unloadOldChunk(self: *User, newPos: Vec3i, newRenderDistance: u16) void {
		const lastBoxStart = (self.lastPos -% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const lastBoxEnd = (self.lastPos +% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxStart = (newPos -% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxEnd = (newPos +% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		// Clear all chunks not inside the new box:
		var x: i32 = lastBoxStart[0];
		while (x != lastBoxEnd[0]) : (x +%= chunk.chunkSize) {
			const inXDistance = x -% newBoxStart[0] >= 0 and x -% newBoxEnd[0] < 0;
			var y: i32 = lastBoxStart[1];
			while (y != lastBoxEnd[1]) : (y +%= chunk.chunkSize) {
				const inYDistance = y -% newBoxStart[1] >= 0 and y -% newBoxEnd[1] < 0;
				var z: i32 = lastBoxStart[2];
				while (z != lastBoxEnd[2]) : (z +%= chunk.chunkSize) {
					const inZDistance = z -% newBoxStart[2] >= 0 and z -% newBoxEnd[2] < 0;
					if (!inXDistance or !inYDistance or !inZDistance) {
						self.loadedChunks[simArrIndex(x)][simArrIndex(y)][simArrIndex(z)].decreaseRefCount();
						self.loadedChunks[simArrIndex(x)][simArrIndex(y)][simArrIndex(z)] = undefined;
					}
				}
			}
		}
	}

	fn loadNewChunk(self: *User, newPos: Vec3i, newRenderDistance: u16) void {
		const lastBoxStart = (self.lastPos -% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const lastBoxEnd = (self.lastPos +% @as(Vec3i, @splat(self.lastRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxStart = (newPos -% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newBoxEnd = (newPos +% @as(Vec3i, @splat(newRenderDistance*chunk.chunkSize))) +% @as(Vec3i, @splat(chunk.chunkSize - 1)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		// Clear all chunks not inside the new box:
		var x: i32 = newBoxStart[0];
		while (x != newBoxEnd[0]) : (x +%= chunk.chunkSize) {
			const inXDistance = x -% lastBoxStart[0] >= 0 and x -% lastBoxEnd[0] < 0;
			var y: i32 = newBoxStart[1];
			while (y != newBoxEnd[1]) : (y +%= chunk.chunkSize) {
				const inYDistance = y -% lastBoxStart[1] >= 0 and y -% lastBoxEnd[1] < 0;
				var z: i32 = newBoxStart[2];
				while (z != newBoxEnd[2]) : (z +%= chunk.chunkSize) {
					const inZDistance = z -% lastBoxStart[2] >= 0 and z -% lastBoxEnd[2] < 0;
					if (!inXDistance or !inYDistance or !inZDistance) {
						self.loadedChunks[simArrIndex(x)][simArrIndex(y)][simArrIndex(z)] = world_zig.ChunkManager.getOrGenerateSimulationChunkAndIncreaseRefCount(.{.wx = x, .wy = y, .wz = z, .voxelSize = 1});
					}
				}
			}
		}
	}

	fn loadUnloadChunks(self: *User) void {
		const newPos: Vec3i = @as(Vec3i, @trunc(self.player().pos)) +% @as(Vec3i, @splat(chunk.chunkSize/2)) & ~@as(Vec3i, @splat(chunk.chunkMask));
		const newRenderDistance = main.settings.simulationDistance;
		if (@reduce(.Or, newPos != self.lastPos) or newRenderDistance != self.lastRenderDistance) {
			self.unloadOldChunk(newPos, newRenderDistance);
			self.loadNewChunk(newPos, newRenderDistance);
			self.lastRenderDistance = newRenderDistance;
			self.lastPos = newPos;
		}
	}

	pub fn getTaskFromJobQueue(self: *User) ?struct { main.utils.ThreadPool.Task, enum { hasMoreTasks, empty } } {
		self.mutex.lock();
		defer self.mutex.unlock();
		if (vec.lengthSquare(@as(@Vector(3, i64), self.jobQueueLastUpdate.position -% self.lastPos)) > 32*32) {
			const startTime = main.timestamp();
			if (self.jobQueueLastUpdate.time.durationTo(startTime).toMilliseconds() > 100 and !self.jobQueueLastUpdate.alreadyInUpdate) {
				const ResortTaskTask = struct { // MARK: ResortTaskTask
					const vtable = utils.ThreadPool.VTable{
						.getPriority = &getPriority,
						.isStillNeeded = &isStillNeeded,
						.run = main.meta.castFunctionSelfToAnyopaque(run),
						.clean = main.meta.castFunctionSelfToAnyopaque(clean),
						.taskType = .taskPriorityUpdate,
					};

					pub fn getPriority(_: *anyopaque) f32 {
						unreachable;
					}

					pub fn isStillNeeded(_: *anyopaque) bool {
						return true;
					}

					pub fn run(user: *User) void {
						var newTasks: main.List(main.utils.ThreadPool.Task) = .initCapacity(main.stackAllocator, user.jobQueue.size);
						defer newTasks.deinit(main.stackAllocator);
						while (user.jobQueue.extractAny()) |_task| {
							var task = _task;
							if (!task.vtable.isStillNeeded(task.self)) {
								if (task.vtable.taskType == .chunkgen) metrics.noteChunkTaskDropped();
								task.vtable.clean(task.self);
								continue;
							}
							task.cachedPriority = task.vtable.getPriority(task.self);
							newTasks.append(main.stackAllocator, task);
						}
						user.jobQueue.addMany(newTasks.items);
						user.mutex.lock();
						defer user.mutex.unlock();
						user.jobQueueLastUpdate = .{
							.position = user.lastPos,
							.time = main.timestamp(),
						};
					}

					pub fn clean(_: *anyopaque) void {
						unreachable;
					}
				};
				// Create a task to resort tasks:
				self.jobQueueLastUpdate.alreadyInUpdate = true;
				return .{
					.{
						.cachedPriority = undefined,
						.vtable = &ResortTaskTask.vtable,
						.self = self,
					},
					.hasMoreTasks,
				};
			}
		}
		if (self.isNetworkQueueFull()) {
			self.jobQueueScheduled = false;
			return null;
		}
		const task = self.jobQueue.extractMax() orelse {
			self.jobQueueScheduled = false;
			return null;
		};
		if (self.jobQueue.size == 0) {
			self.jobQueueScheduled = false;
			return .{task, .empty};
		} else {
			return .{task, .hasMoreTasks};
		}
	}

	pub fn addTask(self: *User, task: *anyopaque, vtable: *const main.utils.ThreadPool.VTable) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		self.jobQueue.add(.{
			.cachedPriority = vtable.getPriority(task),
			.vtable = vtable,
			.self = task,
		});
	}

	pub fn clearJobQueue(self: *User) void {
		while (self.jobQueue.extractAny()) |task| {
			task.vtable.clean(task.self);
		}
	}

	fn isNetworkQueueFull(self: *User) bool {
		// --- ASHFRAME CUSTOM (UX-1b: backpressure follows the chunks) ---
		// Chunks ride `.slow` since UX-1, so checking only `.secure` let the
		// slow backlog grow unbounded (kept sending long after a render-
		// distance cut). Pause dispatch while either channel is too full;
		// tasks wait in the queue (never dropped — the client won't retry).
		if (self.conn.secureChannel.super.sendBuffer.buffer.len > 900000) return true;
		return self.conn.slowChannel.sendBuffer.buffer.len > 900000;
		// --- ASHFRAME CUSTOM (UX-1b) ---
	}

	fn scheduleJobQueue(self: *User) void {
		self.mutex.assertLocked();
		if (self.jobQueueScheduled) return;
		if (self.jobQueue.size == 0) return;
		if (self.isNetworkQueueFull()) return;
		self.jobQueueScheduled = true;
		main.threadPool.addPlayer(self);
	}

	pub fn update(self: *User) void {
		self.mutex.lock();
		self.scheduleJobQueue();
		const commands = self.inventoryCommands;
		defer commands.deinit(main.globalAllocator);
		self.inventoryCommands = .empty;
		self.mutex.unlock();

		// --- ASHFRAME CUSTOM (Dynamic render distance): re-queue held-back requests ---
		// The held list is empty in normal play; only run the (O(n)) pass every
		// other tick so it can't dominate the tick during throttling.
		self.deferredTick +%= 1;
		if (self.deferredTick % 2 == 0) self.processDeferredChunks();
		self.maybeSendViewDebugMessage();
		// --- ASHFRAME CUSTOM (Dynamic render distance) ---

		for (commands.items) |commandData| {
			defer main.globalAllocator.free(commandData);
			var reader: BinaryReader = .init(commandData);
			main.sync.server.executeUserCommand(self, &reader) catch |err| {
				if (err == error.InventoryNotFound) {
					main.network.protocols.inventory.sendFailure(self.conn);
				} else {
					std.log.err("Got error while executing user command: {s}. Disconnecting.", .{@errorName(err)});
					std.log.debug("Command data: {any}", .{commandData});
					self.conn.disconnect();
				}
			};
		}

		self.mutex.lock();
		defer self.mutex.unlock();
		var time = @as(i16, @truncate(main.timestamp().toMilliseconds())) -% main.settings.entityLookback;
		time -%= self.timeDifference.difference.load(.monotonic);
		self.interpolation.update(time, self.lastTime);
		self.lastTime = time;

		const saveTime = main.timestamp();
		if (self.lastSaveTime.durationTo(saveTime).toSeconds() > 5) {
			world.?.savePlayer(self) catch |err| {
				std.log.err("Failed to save player {s}: {s}", .{self.name, @errorName(err)});
			};
			self.lastSaveTime = saveTime;
		}

		self.loadUnloadChunks();
	}

	pub fn receiveCommand(self: *User, commandData: []const u8) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		// Cap the queue so a flood can't grow it without bound before the tick.
		if (self.inventoryCommands.items.len >= 256) return;
		self.inventoryCommands.append(main.globalAllocator, main.globalAllocator.dupe(u8, commandData));
	}

	pub fn receiveData(self: *User, reader: *BinaryReader) !void {
		self.mutex.lock();
		defer self.mutex.unlock();
		const position: [3]f64 = try reader.readVec(Vec3d);
		const velocity: [3]f64 = try reader.readVec(Vec3d);
		const rotation: [3]f32 = try reader.readVec(Vec3f);
		// A legitimate client never sends NaN/Inf or absurd coordinates; reject
		// (which disconnects) rather than letting them reach gameplay logic.
		if (!main.server.anticheat.validPosition(position) or !main.server.anticheat.validVelocity(velocity) or !main.server.anticheat.validRotation(rotation)) {
			main.server.report.recordKick(self.name, "malformed position");
			return error.Invalid;
		}
		// Wave 1 logs implausible speed; wave 2 drops the update (keeping the
		// last valid position) rather than disconnecting.
		if (!main.server.anticheat.checkMovement(self, position, velocity)) return;
		self.player().rot = rotation;
		const time = try reader.readInt(i16);
		self.timeDifference.addDataPoint(time);
		self.interpolation.updatePosition(&position, &velocity, time);
	}

	pub fn sendMessage(self: *User, comptime fmt: []const u8, args: anytype) void {
		const msg = main.stackAllocator.print(fmt, args);
		defer main.stackAllocator.free(msg);
		self.sendRawMessage(msg);
	}
	pub fn sendRawMessage(self: *User, msg: []const u8) void {
		main.network.protocols.chat.send(self.conn, msg);
	}

	pub fn getSpawnPos(user: *User) Vec3d {
		return user.spawnPos orelse @floatFromInt(main.server.world.?.spawn);
	}

	pub fn format(user: User, writer: *std.Io.Writer) std.Io.Writer.Error!void {
		try writer.print("{s}@{d}", .{user.name, user.playerIndex});
	}
};

pub const updatesPerSec: u32 = 20;
const updateTime: std.Io.Duration = .fromNanoseconds(1000000000/20);

pub var world: ?*ServerWorld = null;
var userMutex: main.utils.Mutex = .{};
var users: main.ListManaged(*User) = undefined;
var userDeinitList: main.utils.ConcurrentQueue(*User) = undefined;
var userConnectList: main.utils.ConcurrentQueue(*User) = undefined;

pub var connectionManager: *ConnectionManager = undefined;

pub var running: std.atomic.Value(bool) = .init(false);
var restart: bool = true;

var lastTime: std.Io.Timestamp = undefined;

// Tick-work overrun detection: single slow ticks are harmless, so only warn when
// the tick is persistently over budget, and at most once per 10 s.
const tickBudgetMs: f32 = 50.0;
var lagWindow: [10]bool = @splat(false);
var lagWindowIndex: usize = 0;
var lagWarnLastMs: i64 = 0;

fn reportTickWork(workMs: f32) void {
	main.server.metrics.noteTickWork(workMs);
	const overBudget = workMs >= tickBudgetMs;
	lagWindow[lagWindowIndex] = overBudget;
	lagWindowIndex = (lagWindowIndex + 1)%lagWindow.len;
	if (!overBudget) return;
	var overCount: usize = 0;
	for (lagWindow) |b| {
		if (b) overCount += 1;
	}
	// Only when it's persistent, not a one-off hiccup.
	if (overCount < 3) return;
	const now = main.server.anticheat.nowMilliseconds();
	if (now - lagWarnLastMs < 10_000) return;
	lagWarnLastMs = now;
	std.log.warn("Server tick over budget: this tick {d:.1} ms, {d}/{d} recent ticks over {d:.0} ms", .{ workMs, overCount, lagWindow.len, tickBudgetMs });
}

var thread: ?std.Thread = null;

fn init(name: []const u8, singlePlayerPort: ?u16, mode: ServerWorld.Mode) void { // MARK: init()
	main.heap.allocators.createWorldArena();
	std.debug.assert(world == null); // There can only be one world.
	command.init();
	users = .init(main.globalAllocator);
	lastTime = main.timestamp();

	main.systems.server.init();
	main.entity.server.init();
	main.items.Inventory.server.init();
	main.sync.server.init();

	world = ServerWorld.init(name, mode) catch |err| {
		std.log.err("Failed to create world: {s}", .{@errorName(err)});
		@panic("Can't create world.");
	};

	world.?.generate() catch |err| {
		std.log.err("Failed to generate world: {s}", .{@errorName(err)});
		@panic("Can't generate world.");
	};



	connectionManager.@"continue"() catch |err| {
		std.log.err("Couldn't create thread: {s}", .{@errorName(err)});
		@panic("Could not open Server.");
	};
	if (singlePlayerPort) |port| blk: {
		const ipString = main.stackAllocator.print("127.0.0.1:{}", .{port});
		defer main.stackAllocator.free(ipString);
		const user = User.init(connectionManager, ipString) catch |err| {
			std.log.err("Cannot create singleplayer user {s}", .{@errorName(err)});
			break :blk;
		};
		user.isLocal = true;
	}
}


fn deinit() void {
	main.threadPool.pause();
	defer main.threadPool.@"continue"();

	connectionManager.pause();

	main.threadPool.unschedulePlayers();

	users.clearAndFree();

	while (userDeinitList.popFront()) |user| {
		user.pause();
		user.privateDeinit();
	}

	if (world) |_world| {
		_world.deinit();
	}
	world = null;

	main.sync.server.deinit();
	main.items.Inventory.server.deinit();
	main.entity.server.deinit();
	main.systems.server.deinit();

	command.deinit();

	main.heap.allocators.destroyWorldArena();
}

pub fn getUserList(allocator: main.heap.NeverFailingAllocator) []*User {
	userMutex.lock();
	defer userMutex.unlock();
	return allocator.dupe(*User, users.items);
}

fn getInitialEntityList(allocator: main.heap.NeverFailingAllocator) []const u8 {
	// Send the entity updates:
	var initialList: []const u8 = undefined;
	const list = main.ZonElement.initArray(main.stackAllocator);
	defer list.deinit(main.stackAllocator);
	list.array.append(.null);
	const itemDropList = world.?.itemDropManager.getInitialList(main.stackAllocator);
	list.array.appendSlice(itemDropList.array.items);
	itemDropList.array.items.len = 0;
	itemDropList.deinit(main.stackAllocator);
	initialList = list.toStringEfficient(allocator, &.{});
	return initialList;
}

fn update() void { // MARK: update()
	world.?.update();
	// Deliver any notifications queued from the network thread (needs the
	// server thread for permission checks).
	report.flushNotifications();
	main.systems.server.update();
	stdin_handler.update();

	while (userConnectList.popFront()) |user| {
		connectInternal(user);
	}

	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		user.update();
	}


	// --- ASHFRAME CUSTOM (Deferred chat-filter bans) ---
	// Applied here so the message/save/disconnect happen on the server thread.
	for (userList) |user| {
		if (!user.player().pendingBan) continue;
		user.player().pendingBan = false;
		user.sendMessage("#e6312cYou have been banned (3 strikes).", .{});
		chatfilter.saveCurrentWorld();
		user.conn.disconnect();
	}
	// --- ASHFRAME CUSTOM (Deferred chat-filter bans) ---

	// --- ASHFRAME CUSTOM (Deferred anticheat kicks) ---
	// Repeat speeders are flagged on the network thread; the kick itself
	// (message + disconnect) happens here on the server thread.
	for (userList) |user| {
		if (!user.player().pendingKick) continue;
		user.player().pendingKick = false;
		user.sendMessage("#e6312cKicked for repeated impossible movement.", .{});
		report.recordKick(user.name, "repeat speeder");
		user.conn.disconnect();
	}
	// --- ASHFRAME CUSTOM (Deferred anticheat kicks) ---

	// Send the entity data:
	const itemData = world.?.itemDropManager.getPositionAndVelocityData(main.stackAllocator);
	defer main.stackAllocator.free(itemData);

	var entityData: main.ListManaged(main.entity.EntityNetworkData) = .init(main.stackAllocator);
	defer entityData.deinit();

	for (userList) |user| {
		const id = user.id; // TODO
		entityData.append(.{
			.id = id,
			.pos = user.player().pos,
			.vel = user.player().vel,
			.rot = user.player().rot,
		});
	}
	for (userList) |user| {
		// --- ASHFRAME CUSTOM (interest gating): per-tick drop positions go
		// only to players in range of each drop. Player entities stay ungated
		// (few, cheap, always rendered). Positions are ephemeral state, so no
		// seen-tracking is needed — unlike adds/removes. ---
		var nearItems: main.ListManaged(main.itemdrop.ItemDropNetworkData) = .init(main.stackAllocator);
		defer nearItems.deinit();
		for (itemData) |drop| {
			if (!user.canSeeBlock(@intFromFloat(@trunc(drop.pos[0])), @intFromFloat(@trunc(drop.pos[1])), @intFromFloat(@trunc(drop.pos[2])))) continue;
			nearItems.append(drop);
		}
		main.network.protocols.entityPosition.send(user.conn, user.player().pos, entityData.items, nearItems.items);
	}

	for (userList) |user| {
		const pos = @as(Vec3i, @trunc(user.player().pos));
		const biomeId = world.?.getBiome(pos[0], pos[1], pos[2]).paletteId;
		if (biomeId != user.lastSentBiomeId) {
			user.lastSentBiomeId = biomeId;
			main.network.protocols.genericUpdate.sendBiome(user.conn, biomeId);
		}
	}

	while (userDeinitList.popFront()) |user| {
		user.deferredPauseAndDeinit();
	}
}

pub fn startAndCreateThread(name: []const u8, port: u16, mode: ServerWorld.Mode) void {
	thread = std.Thread.spawn(.{}, main.server.startFromNewThread, .{name, port, mode}) catch |err| {
		std.log.err("Encountered error while starting server thread: {s}", .{@errorName(err)});
		return;
	};
	thread.?.setName(main.io, "Server") catch |err| {
		std.log.err("Failed to rename Server thread: {s}", .{@errorName(err)});
	};
}

fn startFromNewThread(name: []const u8, port: u16, mode: ServerWorld.Mode) void {
	main.initThreadLocals();
	defer main.deinitThreadLocals();
	startFromExistingThread(name, port, mode);
}

pub fn startFromExistingThread(name: []const u8, port: ?u16, mode: ServerWorld.Mode) void {
	std.debug.assert(!running.load(.monotonic)); // There can only be one server.

	const worldName: []const u8 = main.globalAllocator.dupe(u8, name);
	defer main.globalAllocator.free(worldName);

	connectionManager = ConnectionManager.init(main.settings.defaultPort, .{.allowNewConnections = mode == .multiplayer}) catch |err| {
		std.log.err("Couldn't create socket: {s}", .{@errorName(err)});
		@panic("Could not open Server.");
	}; // TODO Configure the second argument in the server settings.
	userDeinitList = .init(main.globalAllocator, 16);
	userConnectList = .init(main.globalAllocator, 16);

	defer {
		connectionManager.deinit();
		connectionManager = undefined;

		while (userDeinitList.popFront()) |user| {
			user.privateDeinit();
		}

		userDeinitList.deinit();
		userConnectList.deinit();
	}

	restart = true;
	while (restart) {
		restart = false;

		init(worldName, port, mode);
		defer deinit();

		running.store(true, .release);
		while (running.load(.monotonic)) {
			main.heap.GarbageCollection.syncPoint();
			const newTime = main.timestamp();
			if (lastTime.durationTo(newTime).nanoseconds < updateTime.nanoseconds) {
				main.io.sleep(newTime.durationTo(lastTime.addDuration(updateTime)), .awake) catch {};
				lastTime = lastTime.addDuration(updateTime);
			} else {
				// Fell behind schedule. Usually just OS sleep overshoot, so this is
				// not warned about here; `reportTickWork` tracks real over-budget
				// ticks (the tick work, not the schedule delta).
				lastTime = newTime;
			}
			const workStart = main.timestamp();
			update();
			reportTickWork(@as(f32, @floatFromInt(workStart.durationTo(main.timestamp()).toNanoseconds()))/1_000_000.0);
		}
	}
}

pub const StopType = enum { stop, stopAndWait, restart };
pub fn stop(typ: StopType) void {
	if (typ == .restart) {
		restart = true;
	}
	running.store(false, .release);
	if (typ == .stopAndWait) {
		if (thread) |t| t.join();
	}
}

pub fn disconnect(user: *User) void { // MARK: disconnect()
	if (!user.connected.load(.monotonic)) return;
	removePlayer(user);
	userDeinitList.pushBack(user);
	user.connected.store(false, .monotonic);
}

pub fn removePlayer(user: *User) void { // MARK: removePlayer()
	if (!user.connected.load(.monotonic)) return;

	const foundUser = blk: {
		userMutex.lock();
		defer userMutex.unlock();
		for (users.items, 0..) |other, i| {
			if (other == user) {
				_ = users.swapRemove(i);
				break :blk true;
			}
		}
		break :blk false;
	};
	if (!foundUser) return;

	sendMessage("{s}§#8a8a8a left", .{user.name});
	// Let the other clients know about that this new one left.
	const zonArray = main.ZonElement.initArray(main.stackAllocator);
	defer zonArray.deinit(main.stackAllocator);
	zonArray.array.append(.{.int = @intFromEnum(user.id)});
	const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
	defer main.stackAllocator.free(data);
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |other| {
		main.network.protocols.entity.send(other.conn, data);
	}
}

/// Removes `user` from the live user list regardless of its `connected` flag.
/// Called during teardown so a freed connection can't be referenced by a later
/// broadcast (which crashed with a stale `Connection`).
fn forceRemoveFromUserList(user: *User) void {
	userMutex.lock();
	defer userMutex.unlock();
	for (users.items, 0..) |other, i| {
		if (other == user) {
			_ = users.swapRemove(i);
			std.log.warn("[ashframe] privateDeinit: force-removed a still-listed user from the users list", .{});
			break;
		}
	}
}

pub fn connect(user: *User) void {
	userConnectList.pushBack(user);
}

pub fn connectInternal(user: *User) void {
	// --- ASHFRAME CUSTOM (Ban check) ---
	// NB: do NOT send chat here. The handshake is not complete yet, and sending a
	// chat message pre-handshake crashed `Connection.send`. The client just sees
	// the generic disconnect (custom reasons would need a fork client).
	if (chatfilter.isBanned(user.name, user.newKeyString)) {
		std.log.info("[ashframe] banned player {s} tried to join; disconnected", .{user.name});
		user.conn.disconnect();
		return;
	}
	if (chatfilter.findBad(user.name) != null) {
		std.log.info("[ashframe] player with a disallowed name tried to join; disconnected", .{});
		user.conn.disconnect();
		return;
	}
	// --- ASHFRAME CUSTOM (Ban check) ---

	user.initPlayer();
	// Cache staff status on the server thread: the movement check runs on the
	// network thread, where `hasPermission` may not be called.
	user.anticheatStaff = main.entity.components.@"cubyz:permissions".server.hasPermission(user.id, report.permissionPath);
	// Operators also get chat feedback when their dynamic render distance changes.
	user.perfDebug = user.anticheatStaff;
	main.network.protocols.handShake.sendServerPlayerData(user.conn);
	user.conn.handShakeState.store(.complete, .monotonic);
	// --- ASHFRAME CUSTOM (join-time sync): push the clock immediately so
	// joining clients don't render noon until the 2 s tick. MUST be after
	// .complete or Connection.send drops it (protocol 9). Stock packet. ---
	main.network.protocols.genericUpdate.sendTime(user.conn, world.?);
	// --- ASHFRAME CUSTOM (join-time sync) ---

	// TODO: addEntity(player);
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	// Check if a user with that account is already present
	if (!world.?.settings.testingMode) {
		for (userList) |other| {
			if (other.playerIndex == user.playerIndex) {
				user.conn.disconnect();
				return;
			}
		}
	}
	// Let the other clients know about this new one.
	{
		const zonArray = main.ZonElement.initArray(main.stackAllocator);
		defer zonArray.deinit(main.stackAllocator);

		const entityZon = user.player().save(main.stackAllocator, .playerNearby);
		putEntityName(entityZon, user);
		zonArray.array.append(entityZon);
		const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
		defer main.stackAllocator.free(data);
		for (userList) |other| {
			main.network.protocols.entity.send(other.conn, data);
		}
	}
	{ // Let this client know about the others:
		const zonArray = main.ZonElement.initArray(main.stackAllocator);
		defer zonArray.deinit(main.stackAllocator);
		for (userList) |other| {
			const entityZon = other.player().save(main.stackAllocator, .playerNearby);
			putEntityName(entityZon, other);
			zonArray.array.append(entityZon);
		}
		const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
		defer main.stackAllocator.free(data);
		if (user.connected.load(.monotonic)) main.network.protocols.entity.send(user.conn, data);
	}
	const initialList = getInitialEntityList(main.stackAllocator);
	main.network.protocols.entity.send(user.conn, initialList);
	main.stackAllocator.free(initialList);
	// --- ASHFRAME CUSTOM (drop interest gating): the join snapshot holds
	// every live drop — mark them seen so the catch-up sweep never re-sends
	// them as duplicate adds (unguarded clients crash on duplicates). ---
	world.?.itemDropManager.markAllSeenBy(user);
	sendMessage("{s}§#8a8a8a joined", .{user.name});
	// --- ASHFRAME CUSTOM (Shop status report) ---
	main.server.shops.reportOnJoin(user);
	// --- ASHFRAME CUSTOM (Shop status report) ---
	// --- ASHFRAME CUSTOM (Server report) ---
	report.recordJoin(user.name);
	report.maybeShowReport(user);
	// --- ASHFRAME CUSTOM (Server report) ---

	userMutex.lock();
	users.append(user);
	userMutex.unlock();

	// --- ASHFRAME CUSTOM (Titles: distinct-days tracking) ---
	{
		const prof = user.player();
		const today = titles.currentDay();
		if (prof.last_played_day != today) {
			prof.days_played +|= 1;
			prof.last_played_day = today;
		}
		titles.check(user);
		veterans.grant(user);
	}
	// --- ASHFRAME CUSTOM (Titles: distinct-days tracking) ---
}

/// Diagnostic (upstream request): validates every entity display name sent to
/// clients and logs the raw bytes on failure. All inputs (handshake-validated
/// player names, fixed ASCII titles) are expected valid, so a hit here would
/// prove bad bytes originate server-side; silence proves they don't.
fn putEntityName(entityZon: main.ZonElement, user: *User) void {
	// Bisect toggle: plain validated usernames when decorated nametags are off.
	if (!main.settings.launchConfig.titlesInNametag) return;
	var nameBuf: [256]u8 = undefined;
	const decorated = titles.decoratedNameBuf(&nameBuf, user) orelse return;
	if (!std.unicode.utf8ValidateSlice(decorated)) {
		std.log.err("[ashframe] invalid UTF-8 in entity name for {s}: {any}", .{ user.name, decorated });
	}
	entityZon.put("name", decorated);
}

/// Re-sends this player's entity to everyone else so a changed title is reflected
/// in the above-head nametag. The decorated name is used only on the network copy,
/// never on disk or in chat, so the player's real name stays intact.
pub fn refreshPlayerNametag(user: *User) void {
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);

	const zonArray = main.ZonElement.initArray(main.stackAllocator);
	defer zonArray.deinit(main.stackAllocator);
	zonArray.array.append(.{.int = @intFromEnum(user.id)}); // remove the stale entity
	const entityZon = user.player().save(main.stackAllocator, .playerNearby);
	putEntityName(entityZon, user);
	zonArray.array.append(entityZon); // re-add it with the updated nametag

	const data = zonArray.toStringEfficient(main.stackAllocator, &.{});
	defer main.stackAllocator.free(data);
	for (userList) |other| {
		if (other == user) continue;
		main.network.protocols.entity.send(other.conn, data);
	}
}

pub fn messageFrom(msg: []const u8, source: *User) void { // MARK: message
	var emoji_buf: [1024]u8 = undefined;
	const clean_msg = emojis.parseEmojis(msg, &emoji_buf);

	// --- ASHFRAME CUSTOM (Chat filter) ---
	if (chatfilter.findBad(clean_msg) != null) {
		// The ban (message + save + disconnect) is completed on the server thread.
		_ = chatfilter.strike(source);
		return;
	}
	// --- ASHFRAME CUSTOM (Chat filter) ---

	// --- ASHFRAME CUSTOM (Title tracking) ---
	source.player().messages_sent +|= 1;
	titles.check(source);

	var tag: main.ListManaged(u8) = .init(main.stackAllocator);
	defer tag.deinit();
	titles.appendChatTag(&tag, source);
	// --- ASHFRAME CUSTOM (@mention ping): the mentioned online user gets a
	// version with the @name highlighted gold, and is EXCLUDED from the
	// normal broadcast so they don't see the line twice. ---
	const mentioned = findMentionedUser(source, clean_msg);
	const line = main.stackAllocator.print("{s}§#ffffff{s}§#8a8a8a > §#ffffff{s}", .{ tag.items, source.name, clean_msg });
	defer main.stackAllocator.free(line);
	sendRawMessageExcept(line, mentioned);
	if (mentioned) |m| {
		var tok: usize = 0;
		while (std.mem.indexOfScalarPos(u8, clean_msg, tok, '@')) |pos| {
			tok = pos + 1;
			var e = tok;
			while (e < clean_msg.len and !std.ascii.isWhitespace(clean_msg[e])) e += 1;
			var plainBuf: [128]u8 = undefined;
			if (eqlIgnoreCasePlain(m.name, clean_msg[tok..e], &plainBuf)) {
				sendMentionCopy(source, tag.items, clean_msg, m, clean_msg[tok..e]);
				break;
			}
		}
	}
	// --- ASHFRAME CUSTOM (@mention ping) ---
	// --- ASHFRAME CUSTOM (Title tracking) ---
}

// --- ASHFRAME CUSTOM (@mention ping) ---
/// True if `rawToken` equals `name` with all colour codes stripped.
fn eqlIgnoreCasePlain(name: []const u8, rawToken: []const u8, buf: []u8) bool {
	return std.ascii.eqlIgnoreCase(plainName(name, buf), rawToken);
}

// --- ASHFRAME CUSTOM (@mention ping) ---
/// Plain (no colour codes) form of a display name. Handles BOTH `§#rrggbb`
/// and a bare `#rrggbb` prefix (Ashframe names use the bare form).
fn plainName(name: []const u8, buf: []u8) []const u8 {
	var n: usize = 0;
	var i: usize = 0;
	while (i < name.len and n < buf.len) {
		if (std.mem.startsWith(u8, name[i..], "§")) {
			i += "§".len;
			if (i < name.len and name[i] == '#') i += 7 else if (i < name.len) i += 1;
			continue;
		}
		if (name[i] == '#' and i + 7 <= name.len and isHex6(name[i + 1 .. i + 7])) {
			i += 7;
			continue;
		}
		buf[n] = name[i];
		n += 1;
		i += 1;
	}
	return buf[0..n];
}

fn isHex6(s: []const u8) bool {
	if (s.len != 6) return false;
	for (s) |ch| {
		if (!std.ascii.isHex(ch)) return false;
	}
	return true;
}

/// The online user named by an `@token` in `msg`, or null. Only the FIRST
/// mention is resolved (avoid duplicate pings).
fn findMentionedUser(source: *User, msg: []const u8) ?*User {
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	var at: usize = 0;
	while (std.mem.indexOfScalarPos(u8, msg, at, '@')) |pos| {
		at = pos + 1;
		var end = at;
		while (end < msg.len and !std.ascii.isWhitespace(msg[end])) end += 1;
		const token = msg[at..end];
		if (token.len == 0) continue;
		for (userList) |u| {
			if (u == source) continue;
			var plainBuf: [128]u8 = undefined;
			const plain = plainName(u.name, &plainBuf);
			if (std.ascii.eqlIgnoreCase(plain, token)) return u;
		}
	}
	return null;
}

/// Send `target` the chat line with `token` highlighted gold. Built once;
/// never broadcast, so no duplicate reaches the mentioned user.
fn sendMentionCopy(source: *User, tag: []const u8, msg: []const u8, target: *User, token: []const u8) void {
	var out: main.ListManaged(u8) = .init(main.stackAllocator);
	defer out.deinit();
	out.appendSlice(tag);
	out.appendSlice("§#ffffff");
	out.appendSlice(source.name);
	out.appendSlice("§#8a8a8a > §#ffffff");
	var j: usize = 0;
	var it: usize = 0;
	while (std.mem.indexOfScalarPos(u8, msg, it, '@')) |p| {
		if (p > j) out.appendSlice(msg[j..p]);
		var e = p + 1;
		while (e < msg.len and !std.ascii.isWhitespace(msg[e])) e += 1;
		if (std.ascii.eqlIgnoreCase(msg[p + 1 .. e], token)) {
			out.appendSlice("§#ffcc00@");
			out.appendSlice(token);
			out.appendSlice("§#ffffff");
		} else {
			out.appendSlice(msg[p..e]);
		}
		j = e;
		it = e;
	}
	if (j < msg.len) out.appendSlice(msg[j..]);
	target.sendRawMessage(out.items);
}
// --- ASHFRAME CUSTOM (@mention ping) ---

fn sendRawMessage(msg: []const u8) void {
	sendRawMessageExcept(msg, null);
}

/// Broadcast `msg` to everyone except `except` (used by the mention ping so
/// the mentioned user receives only their gold copy, not a duplicate).
fn sendRawMessageExcept(msg: []const u8, except: ?*User) void {
	chatMutex.lock();
	defer chatMutex.unlock();
	main.log.chat("{s}", .{msg});
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		if (except != null and user == except.?) continue;
		const state = user.conn.connectionState.load(.monotonic);
		if (state != .connected) {
			std.log.warn("[ashframe] sendRawMessage: skipping {s} user={x} conn={x} (state {s})", .{ user.name, @intFromPtr(user), @intFromPtr(user.conn), @tagName(state) });
			continue;
		}
		user.sendRawMessage(msg);
	}
}

var chatMutex: main.utils.Mutex = .{};
pub fn sendMessage(comptime fmt: []const u8, args: anytype) void {
	const msg = main.stackAllocator.print(fmt, args);
	defer main.stackAllocator.free(msg);
	sendRawMessage(msg);
}

pub fn getUserByIndex(index: PlayerIndex) ?*User {
	const userList = getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		if (user.playerIndex == index) {
			return user;
		}
	}
	return null;
}
