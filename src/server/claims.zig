const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Land claims) ---
// Claim boxes are 16x16x32 (±8 x/z, ±16 y around the claim point). The first
// claim is free; further ones cost ruby ore. You can't claim within 8 blocks of
// someone else's claim unless they approve you.

pub const halfX: i32 = 8;
pub const halfZ: i32 = 8;
pub const halfY: i32 = 16;
pub const maxClaimsPerPlayer: u8 = 10;
pub const maxMembers: u8 = 16;
pub const barrierBlocks: i32 = 8;

// Cost of the next claim, by how many the player already owns. The first is
// free; each further claim costs double the previous in ruby ore, so claims get
// very expensive and eventually push players to pool them via alliances.
pub const ClaimCost = struct {
	item: []const u8,
	amount: u16 = 0,
};

pub fn extraClaimCost(owned: u8) ClaimCost {
	if (owned == 0) return .{.item = ""};
	const shift: u5 = @intCast(@min(owned - 1, 9));
	const amount: u16 = @intCast(@as(u32, 1) << shift);
	return .{.item = "cubyz:ruby_ore", .amount = amount};
}

pub const Claim = struct {
	minX: i32,
	minY: i32,
	minZ: i32,
	maxX: i32, // inclusive
	maxY: i32,
	maxZ: i32,
	owner: usize,
	ownerName: []const u8,
	/// Account key string of the owner (empty for local/legacy). Used to verify
	/// ownership so a name-adopted `playerIndex` can't inherit a claim.
	ownerKey: []const u8 = "",
	members: [16]usize = [_]usize{0} ** 16,
	/// Account key per trusted member (empty for local/legacy). A stored key must
	/// match, so a name-adopted `playerIndex` can't inherit trust.
	memberKeys: [16][]const u8 = [_][]const u8{""} ** 16,
	memberCount: u8 = 0,
};

// Approvals: owner `by` has approved requester `for_` to claim near them.
const Approval = struct {
	by: usize,
	for_: usize,
	expiry: i64,
};

// How many claims a player has *unlocked* (bought). Monotonic: removing a claim
// does not lower it, so the price you already paid stays paid.
const Unlocked = struct {
	player: usize,
	count: u8,
};

var claims: main.ListManaged(Claim) = undefined;
var approvals: main.ListManaged(Approval) = undefined;
var unlocked: main.ListManaged(Unlocked) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};
var lastDeny: std.AutoHashMap(usize, i64) = undefined;
var lastDenyReady: bool = false;

fn ensure() void {
	if (!ready) {
		claims = main.ListManaged(Claim).init(main.globalAllocator);
		approvals = main.ListManaged(Approval).init(main.globalAllocator);
		unlocked = main.ListManaged(Unlocked).init(main.globalAllocator);
		ready = true;
	}
	if (!lastDenyReady) {
		lastDeny = std.AutoHashMap(usize, i64).init(main.globalAllocator.allocator);
		lastDenyReady = true;
	}
}

fn nowSeconds() i64 {
	return @intCast(@divTrunc(main.timestamp().toNanoseconds(), 1000000000));
}

pub fn isAdmin(user: *User) bool {
	return main.entity.components.@"cubyz:permissions".server.hasPermission(user.id, "/ashframe/admin/claim");
}

pub fn isExempt(user: *User) bool {
	return user.isLocal or isAdmin(user);
}

fn boxesOverlapXZ(c: *const Claim, minX: i32, minZ: i32, maxX: i32, maxZ: i32) bool {
	return c.maxX >= minX and c.minX <= maxX and c.maxZ >= minZ and c.minZ <= maxZ;
}

/// Index of the claim containing (x, vertical, z), if any.
/// Axis order is (x, vertical, z) — the vertical is the second argument here.
pub fn at(x: i32, vert: i32, z: i32) ?usize {
	ensure();
	for (claims.items, 0..) |*c, i| {
		if (x >= c.minX and x <= c.maxX and vert >= c.minY and vert <= c.maxY and z >= c.minZ and z <= c.maxZ) return i;
	}
	return null;
}

/// Any claim covering this x/z column (for border drawing).
pub fn atColumn(x: i32, z: i32) ?usize {
	ensure();
	for (claims.items, 0..) |*c, i| {
		if (x >= c.minX and x <= c.maxX and z >= c.minZ and z <= c.maxZ) return i;
	}
	return null;
}

pub fn isMember(c: *const Claim, user: *User) bool {
	for (c.members[0..c.memberCount], 0..) |m, slot| {
		if (m != user.playerIndex) continue;
		const key = c.memberKeys[slot];
		if (key.len == 0) return true; // local/legacy: index only
		const uk = user.newKeyString orelse return false;
		return std.mem.eql(u8, key, uk);
	}
	// Alliance members can build/open on the leader's claims.
	return main.server.alliances.isMemberOf(c.owner, user.playerIndex, user.newKeyString orelse "");
}

/// Order: (x, vertical, z).
/// Secure ownership: a claim that stored an account key requires the matching
/// key, so a name-adopted `playerIndex` can't inherit it. Keyless (local/legacy)
/// claims fall back to the index.
pub fn ownsClaim(c: *const Claim, user: *User) bool {
	if (c.ownerKey.len != 0) {
		const k = user.newKeyString orelse return false;
		return std.mem.eql(u8, c.ownerKey, k);
	}
	return c.owner == user.playerIndex;
}

pub fn canBuild(user: *User, x: i32, vert: i32, z: i32) bool {
	if (isExempt(user)) return true;
	if (at(x, vert, z)) |i| {
		ensure();
		const c = &claims.items[i];
		return ownsClaim(c, user) or isMember(c, user);
	}
	return true;
}

pub fn deniedInBox(user: *User, minX: i32, minZ: i32, maxX: i32, maxZ: i32) bool {
	if (isExempt(user)) return false;
	ensure();
	for (claims.items) |*c| {
		if (!boxesOverlapXZ(c, minX, minZ, maxX, maxZ)) continue;
		if (!ownsClaim(c, user) and !isMember(c, user)) return true;
	}
	return false;
}

/// Logs why `canBuild` denied `user` at a position (index match, key
/// presence/match, membership). Never logs key material. Used to diagnose
/// "owner can't open own chest" reports that can't be reproduced locally.
pub fn logDenyDiagnosis(user: *User, x: i32, vert: i32, z: i32) void {
	ensure();
	const i = at(x, vert, z) orelse {
		std.log.warn("[claims] deny at {d},{d},{d} for {s}: no claim found (stale?)", .{ x, vert, z, user.name });
		return;
	};
	const c = &claims.items[i];
	const indexMatch = c.owner == user.playerIndex;
	const hasOwnerKey = c.ownerKey.len != 0;
	const hasUserKey = user.newKeyString != null;
	const keyMatch = hasOwnerKey and hasUserKey and std.mem.eql(u8, c.ownerKey, user.newKeyString.?);
	std.log.warn("[claims] deny at {d},{d},{d} for {s}: claim owned by {s} (idx {d}), indexMatch={}, hasOwnerKey={}, hasUserKey={}, keyMatch={}, trusted={}", .{ x, vert, z, user.name, c.ownerName, c.owner, indexMatch, hasOwnerKey, hasUserKey, keyMatch, isMember(c, user) });
}

pub fn notifyDenied(user: *User, x: i32, z: i32) void {
	ensure();
	const now = nowSeconds();
	if (lastDeny.get(user.playerIndex)) |last| {
		if (now - last < 3) return;
	}
	lastDeny.put(user.playerIndex, now) catch {};
	if (atColumn(x, z)) |i| {
		user.sendMessage("#e6312cYou can't build here — claimed by #cfcfcf{s}#e6312c.", .{claims.items[i].ownerName});
	} else {
		user.sendMessage("#e6312cYou can't build here.", .{});
	}
}

pub fn notifyDeniedBox(user: *User) void {
	user.sendMessage("#e6312cWorldEdit blocked here — the area overlaps land you can't build on.", .{});
}

pub fn allClaims() []Claim {
	ensure();
	return claims.items;
}

pub fn countOwned(owner: usize) u8 {
	ensure();
	var n: u8 = 0;
	for (claims.items) |*c| {
		if (c.owner == owner) n += 1;
	}
	return n;
}

/// Number of claims this player has unlocked (bought), never below what they
/// currently own. Monotonic so removing a claim doesn't give a discount.
fn unlockedCount(owner: usize) u8 {
	ensure();
	var n = countOwned(owner);
	for (unlocked.items) |e| {
		if (e.player == owner) {
			n = @max(n, e.count);
			break;
		}
	}
	return n;
}

/// Cost of this player's next claim (amount 0 = free). The first claim is free,
/// and re-filling a slot you have already unlocked (e.g. after abandoning a
/// claim) is free too — only claiming *beyond* what you've paid for costs.
pub fn nextCost(owner: usize) ClaimCost {
	const cur = countOwned(owner);
	if (cur == 0) return extraClaimCost(0);
	// Slots pooled from alliance members count as already unlocked for the leader.
	const unlockedTotal = @as(u16, unlockedCount(owner)) + main.server.alliances.pooledSlotsFor(owner);
	if (@as(u16, cur) < unlockedTotal) return .{.item = "", .amount = 0};
	return extraClaimCost(cur);
}

/// Records that `owner` has unlocked up to their current claim count.
pub fn bumpUnlocked(owner: usize) void {
	ensure();
	const n = countOwned(owner);
	for (unlocked.items) |*e| {
		if (e.player == owner) {
			e.count = @max(e.count, n);
			return;
		}
	}
	unlocked.append(.{ .player = owner, .count = n });
}

pub const CreateResult = union(enum) {
	ok: void,
	tooMany,
	blocked: usize, // index of the blocking claim's owner
	alreadyOwned,
	invalidPosition,
};

/// Drops expired approvals so the list can't grow without bound.
fn pruneApprovals() void {
	ensure();
	const now = nowSeconds();
	var i: usize = 0;
	while (i < approvals.items.len) {
		if (approvals.items[i].expiry <= now) {
			_ = approvals.swapRemove(i);
			continue;
		}
		i += 1;
	}
}

fn hasApproval(by: usize, for_: usize) bool {
	pruneApprovals();
	for (approvals.items) |*a| {
		if (a.by == by and a.for_ == for_) return true;
	}
	return false;
}

/// Owner revokes a previously granted approval (used by `/claim deny`).
pub fn revokeApproval(owner: *User, requester: *User) void {
	removeApproval(owner.playerIndex, requester.playerIndex);
	clearRequest(requester.playerIndex, owner.playerIndex);
}

fn addApproval(by: usize, for_: usize) void {
	ensure();
	removeApproval(by, for_);
	approvals.append(.{ .by = by, .for_ = for_, .expiry = nowSeconds() + 120 });
}

fn removeApproval(by: usize, for_: usize) void {
	ensure();
	var i: usize = 0;
	while (i < approvals.items.len) {
		const a = approvals.items[i];
		if (a.by == by and a.for_ == for_) {
			_ = approvals.swapRemove(i);
			continue;
		}
		i += 1;
	}
}

// Claim requests: requester asked owner to approve a nearby claim. One live
// request per requester→owner pair — repeated /claim attempts while blocked
// must not spam the owner with "wants to claim" messages.
const Request = struct {
	requester: usize,
	owner: usize,
	time: i64,
};
var requests: main.ListManaged(Request) = undefined;
var requestsReady: bool = false;

fn ensureRequests() void {
	ensure();
	if (!requestsReady) {
		requests = main.ListManaged(Request).init(main.globalAllocator);
		requestsReady = true;
	}
}

/// Records a claim request. Returns true if the owner should be notified
/// (no live request from this requester to this owner); false if one is
/// already pending. Requests live as long as approvals (2 minutes).
pub fn notifyRequestOnce(requester: usize, owner: usize) bool {
	ensureRequests();
	const now = nowSeconds();
	var i: usize = 0;
	while (i < requests.items.len) {
		const r = requests.items[i];
		if (now - r.time > 120) {
			_ = requests.swapRemove(i);
			continue;
		}
		if (r.requester == requester and r.owner == owner) return false;
		i += 1;
	}
	requests.append(.{ .requester = requester, .owner = owner, .time = now });
	return true;
}

/// Clears a pending request (on accept/deny), so a fresh attempt notifies again.
pub fn clearRequest(requester: usize, owner: usize) void {
	if (!requestsReady) return;
	var i: usize = 0;
	while (i < requests.items.len) {
		const r = requests.items[i];
		if (r.requester == requester and r.owner == owner) {
			_ = requests.swapRemove(i);
			continue;
		}
		i += 1;
	}
}

/// Called by a claim owner to approve a neighbor's pending claim.
pub fn approve(owner: *User, requester: *User) void {
	addApproval(owner.playerIndex, requester.playerIndex);
	clearRequest(requester.playerIndex, owner.playerIndex);
	owner.sendMessage("#00ff00Approved #cfcfcf{s}#00ff00 to claim nearby. #8a8a8a(They must run /claim again within 2 minutes.)", .{requester.name});
	requester.sendMessage("#00ff00{s} #cfcfcfapproved your claim request — run #e6312c/claim#cfcfcf again.", .{owner.name});
}

pub fn create(user: *User) CreateResult {
	ensure();
	const prof = user.player();
	const px = main.server.anticheat.toI32(prof.pos[0]) orelse return .invalidPosition;
	const pz = main.server.anticheat.toI32(prof.pos[1]) orelse return .invalidPosition;
	const py = main.server.anticheat.toI32(prof.pos[2]) orelse return .invalidPosition;
	// Snap to a fixed 16x16 grid so claims always tile and line up with each
	// other. Vertically it's centred on the player: 16 up, 16 down.
	const cellX = halfX*2;
	const cellZ = halfZ*2;
	var minX = @divFloor(px, cellX)*cellX;
	var maxX = minX + cellX - 1;
	var minZ = @divFloor(pz, cellZ)*cellZ;
	var maxZ = minZ + cellZ - 1;
	const minY = py - halfY;
	const maxY = py + halfY - 1;

	if (@as(u16, countOwned(user.playerIndex)) >= main.server.alliances.maxClaimsFor(user.playerIndex)) return .tooMany;

	// Standing inside your own claim's column is not a new claim: without this
	// the abut-push below would silently slide the box onto the neighbouring
	// chunk and charge you for land you thought you already owned. Column
	// match (XZ only, like the exclusion rule) — the column is yours at any
	// height even though protection covers only your claim's Y range.
	for (claims.items) |*c| {
		if (c.owner != user.playerIndex) continue;
		if (px >= c.minX and px <= c.maxX and pz >= c.minZ and pz <= c.maxZ) return .alreadyOwned;
	}

	// Combine with your OWN claims: snap the new box to abut them, so adjacent
	// claims join without a gap or overlap (the barrier is only for others).
	for (0..6) |_| {
		var changed = false;
		for (claims.items) |*c| {
			if (c.owner != user.playerIndex) continue;
			if (!boxesOverlapXZ(c, minX, minZ, maxX, maxZ)) continue;
			const width = halfX*2;
			const depth = halfZ*2;
			const pushXPlus = (c.maxX + 1) - minX;
			const pushXMinus = maxX - (c.minX - 1);
			const pushZPlus = (c.maxZ + 1) - minZ;
			const pushZMinus = maxZ - (c.minZ - 1);
			const best = @min(@min(pushXPlus, pushXMinus), @min(pushZPlus, pushZMinus));
			if (best == pushXPlus) {
				minX = c.maxX + 1;
				maxX = minX + width - 1;
			} else if (best == pushXMinus) {
				maxX = c.minX - 1;
				minX = maxX - width + 1;
			} else if (best == pushZPlus) {
				minZ = c.maxZ + 1;
				maxZ = minZ + depth - 1;
			} else {
				maxZ = c.minZ - 1;
				minZ = maxZ - depth + 1;
			}
			changed = true;
			break;
		}
		if (!changed) break;
	}

	// A real overlap with any claim is always rejected — approval only waives the
	// barrier *distance*, never lets you claim on top of someone.
	// NOTE (column rule, intentional): overlap and barrier are XZ-only; Y is
	// ignored. One claim reserves its whole vertical column at any height, so
	// nobody can claim above or below anyone. Protection itself stays 3D
	// (see at()/canBuild: ±16 around the claim height).
	for (claims.items, 0..) |*c, i| {
		if (boxesOverlapXZ(c, minX, minZ, maxX, maxZ)) return .{.blocked = i};
		if (c.owner == user.playerIndex) continue;
		const expandedMinX = minX - barrierBlocks;
		const expandedMaxX = maxX + barrierBlocks;
		const expandedMinZ = minZ - barrierBlocks;
		const expandedMaxZ = maxZ + barrierBlocks;
		if (!boxesOverlapXZ(c, expandedMinX, expandedMinZ, expandedMaxX, expandedMaxZ)) continue;
		if (hasApproval(c.owner, user.playerIndex)) continue;
		return .{.blocked = i};
	}

	claims.append(.{
		.minX = minX,
		.minY = minY,
		.minZ = minZ,
		.maxX = maxX,
		.maxY = maxY,
		.maxZ = maxZ,
		.owner = user.playerIndex,
		.ownerName = main.globalAllocator.dupe(u8, user.name),
		.ownerKey = if (user.newKeyString) |k| main.globalAllocator.dupe(u8, k) else "",
	});
	return .ok;
}

pub fn removeAt(index: usize) void {
	ensure();
	if (index >= claims.items.len) return;
	freeClaim(&claims.items[index]);
	_ = claims.orderedRemove(index);
}

fn freeClaim(c: *Claim) void {
	main.globalAllocator.free(c.ownerName);
	if (c.ownerKey.len != 0) main.globalAllocator.free(c.ownerKey);
	for (c.memberKeys[0..c.memberCount]) |k| {
		if (k.len != 0) main.globalAllocator.free(k);
	}
}

/// True if the claim covering (x, vertical, z) belongs to an alliance that has
/// opened its chests to everyone (`/alliance allow chest anyone`).
pub fn allianceChestPublic(x: i32, vert: i32, z: i32) bool {
	ensure();
	const i = at(x, vert, z) orelse return true; // unclaimed -> public
	const c = &claims.items[i];
	const ai = main.server.alliances.findLedBy(c.owner) orelse return false;
	return !main.server.alliances.list()[ai].chestMembersOnly;
}

/// Removes `owner`'s newest claims until they own at most `max`. Used when an
/// alliance loses a member, so the leader's pool-funded claims are returned.
pub fn trimToMax(owner: usize, max: u16) void {
	ensure();
	while (@as(u16, countOwned(owner)) > max) {
		var idx: ?usize = null;
		var i: usize = claims.items.len;
		while (i > 0) {
			i -= 1;
			if (claims.items[i].owner == owner) {
				idx = i;
				break;
			}
		}
		const j = idx orelse break;
		removeAt(j);
	}
}

pub fn trust(index: usize, target: *User) bool {
	ensure();
	if (index >= claims.items.len) return false;
	const c = &claims.items[index];
	if (c.owner == target.playerIndex or isMember(c, target)) return false;
	if (c.memberCount >= maxMembers) return false;
	c.members[c.memberCount] = target.playerIndex;
	c.memberKeys[c.memberCount] = if (target.newKeyString) |k| main.globalAllocator.dupe(u8, k) else "";
	c.memberCount += 1;
	return true;
}

pub fn untrust(index: usize, target: *User) bool {
	ensure();
	if (index >= claims.items.len) return false;
	const c = &claims.items[index];
	for (c.members[0..c.memberCount], 0..) |m, i| {
		if (m != target.playerIndex) continue;
		const key = c.memberKeys[i];
		if (key.len != 0) {
			const uk = target.newKeyString orelse return false;
			if (!std.mem.eql(u8, key, uk)) return false;
		}
		if (c.memberKeys[i].len != 0) main.globalAllocator.free(c.memberKeys[i]);
		c.members[i] = c.members[c.memberCount - 1];
		c.memberKeys[i] = c.memberKeys[c.memberCount - 1];
		c.memberKeys[c.memberCount - 1] = "";
		c.memberCount -= 1;
		return true;
	}
	return false;
}

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_claims.zig.zon", .{worldPath});
}

fn freeAll() void {
	ensure();
	for (claims.items) |*c| {
		freeClaim(c);
	}
	claims.clearRetainingCapacity();
}

pub fn load(worldPath: []const u8) void {
	ensure();
	freeAll();
	unlocked.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	const list = zon.getChild("claims");
	if (list == .null) return;
	for (list.toSlice()) |entry| {
		const min = entry.getChild("min").toSlice();
		const max = entry.getChild("max").toSlice();
		if (min.len != 3 or max.len != 3) continue;
		const name = entry.get([]const u8, "ownerName") orelse continue;
		var c = Claim{
			.minX = min[0].as(i32) orelse continue,
			.minY = min[1].as(i32) orelse continue,
			.minZ = min[2].as(i32) orelse continue,
			.maxX = max[0].as(i32) orelse continue,
			.maxY = max[1].as(i32) orelse continue,
			.maxZ = max[2].as(i32) orelse continue,
			.owner = entry.get(usize, "owner") orelse continue,
			.ownerName = main.globalAllocator.dupe(u8, name),
			.ownerKey = if (entry.get([]const u8, "ownerKey")) |k| main.globalAllocator.dupe(u8, k) else "",
		};
		const members = entry.getChild("members");
		if (members != .null) {
			for (members.toSlice()) |m| {
				if (c.memberCount >= maxMembers) break;
				if (m == .int) {
					c.members[c.memberCount] = m.as(usize) orelse continue;
				} else {
					c.members[c.memberCount] = m.get(usize, "index") orelse continue;
					c.memberKeys[c.memberCount] = if (m.get([]const u8, "key")) |k| main.globalAllocator.dupe(u8, k) else "";
				}
				c.memberCount += 1;
			}
		}
		claims.append(c);
	}
	for (zon.getChild("unlocked").toSlice()) |e| {
		const player = e.get(usize, "player") orelse continue;
		const count = e.get(u8, "count") orelse continue;
		unlocked.append(.{ .player = player, .count = count });
	}
	// Grandfather already-owned claims as unlocked, so abandoning one doesn't
	// discount the next claim (saves predating the unlocked counter).
	for (claims.items) |*c| {
		const n = countOwned(c.owner);
		var found = false;
		for (unlocked.items) |*e| {
			if (e.player == c.owner) {
				e.count = @max(e.count, n);
				found = true;
				break;
			}
		}
		if (!found) unlocked.append(.{ .player = c.owner, .count = n });
	}
}

pub fn save(worldPath: []const u8) void {
	ensure();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var arr = main.ZonElement.initArray(main.stackAllocator);
	for (claims.items) |*c| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		var minArr = main.ZonElement.initArray(main.stackAllocator);
		minArr.array.append(.{.int = c.minX});
		minArr.array.append(.{.int = c.minY});
		minArr.array.append(.{.int = c.minZ});
		e.put("min", minArr);
		var maxArr = main.ZonElement.initArray(main.stackAllocator);
		maxArr.array.append(.{.int = c.maxX});
		maxArr.array.append(.{.int = c.maxY});
		maxArr.array.append(.{.int = c.maxZ});
		e.put("max", maxArr);
		e.put("owner", c.owner);
		e.put("ownerName", c.ownerName);
		if (c.ownerKey.len != 0) e.put("ownerKey", c.ownerKey);
		var memArr = main.ZonElement.initArray(main.stackAllocator);
		for (c.members[0..c.memberCount], 0..) |m, slot| {
			if (c.memberKeys[slot].len == 0) {
				memArr.array.append(.{.int = m});
				continue;
			}
			var me = main.ZonElement.initObject(main.stackAllocator);
			me.put("index", m);
			me.put("key", c.memberKeys[slot]);
			memArr.array.append(me);
		}
		e.put("members", memArr);
		arr.array.append(e);
	}
	zon.put("claims", arr);
	var unlockedArr = main.ZonElement.initArray(main.stackAllocator);
	for (unlocked.items) |u| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("player", u.player);
		e.put("count", u.count);
		unlockedArr.array.append(e);
	}
	zon.put("unlocked", unlockedArr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe claims data: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}

// Border markers. `poof` for land you own (or are viewing), and `flame` (red)
// when a claim is blocked, so you can see *where* the problem is. The spawn ZON
// overrides the particle's lifetime so the markers linger instead of vanishing
// almost immediately.
const borderParticle = "cubyz:poof";
const borderSpawnZon = ".{.speed = 0.25, .lifeTime = .{2.0, 3.0}}";
// Red, stationary marker (custom asset shipped in the world pack) so the
// blocking claim is visible for long enough to understand its shape.
const blockedParticle = "ashframe:claim_blocked";
const blockedSpawnZon = ".{.speed = 0, .lifeTime = .{6.0, 9.0}}";
// Green marker for claims you can build on but don't own (trusted or alliance).
const friendParticle = "ashframe:claim_friend";
const markerCount: u32 = 2;
const edgeStep: i32 = 2;

fn burst(user: *User, particle: []const u8, zon: []const u8, x: i32, z: i32, y: i32) void {
	main.network.protocols.genericUpdate.sendParticles(
		user.conn,
		particle,
		.{ @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(z)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5 },
		true,
		markerCount,
		zon,
	);
}

fn edgePoint(user: *User, world: *main.server.ServerWorld, particle: []const u8, zon: []const u8, x: i32, z: i32, feet: i32) void {
	if (world.getBlock(x, z, feet + 2) == null) {
		burst(user, particle, zon, x, z, feet + 1);
		return;
	}
	var y = feet + 2;
	while (y >= feet - 14) : (y -= 1) {
		const b = world.getBlock(x, z, y) orelse continue;
		if (b.collide()) {
			burst(user, particle, zon, x, z, y + 1);
			return;
		}
	}
	burst(user, particle, zon, x, z, feet + 1);
}

/// True if the block at (ox, oz) belongs to the same player as `c` — i.e. this
/// edge is shared with an adjacent own claim and shouldn't be marked.
fn ownedBySame(c: *const Claim, ox: i32, oz: i32) bool {
	const i = atColumn(ox, oz) orelse return false;
	return claims.items[i].owner == c.owner;
}

fn drawOutline(user: *User, index: usize, particle: []const u8, zon: []const u8, skipShared: bool) void {
	ensure();
	if (index >= claims.items.len) return;
	const world = main.server.world orelse return;
	const c = &claims.items[index];
	const feet: i32 = @as(i32, @intFromFloat(user.player().pos[2]));

	var x = c.minX;
	while (true) {
		if (!(skipShared and ownedBySame(c, x, c.minZ - 1))) edgePoint(user, world, particle, zon, x, c.minZ, feet);
		if (!(skipShared and ownedBySame(c, x, c.maxZ + 1))) edgePoint(user, world, particle, zon, x, c.maxZ, feet);
		if (x >= c.maxX) break;
		x += edgeStep;
		if (x > c.maxX) x = c.maxX;
	}
	var z = c.minZ + edgeStep;
	while (z < c.maxZ) : (z += edgeStep) {
		if (!(skipShared and ownedBySame(c, c.minX - 1, z))) edgePoint(user, world, particle, zon, c.minX, z, feet);
		if (!(skipShared and ownedBySame(c, c.maxX + 1, z))) edgePoint(user, world, particle, zon, c.maxX, z, feet);
	}
}

/// Green/white outline for the claim you're viewing. Shared walls between your
/// own adjoining claims are left empty, so only the outer boundary shows.
pub fn drawBorder(user: *User, index: usize) void {
	drawOutline(user, index, borderParticle, borderSpawnZon, true);
}

/// Red outline marking a claim that blocks you, so you can see where it is.
pub fn drawBlocked(user: *User, index: usize) void {
	drawOutline(user, index, blockedParticle, blockedSpawnZon, false);
}

const NearbyClaim = struct { dist: i64, index: usize };
// Each claim costs one particle packet per edge point, so a dense area is
// capped to the nearest few rather than flooding the client.
const maxNearbyClaims: usize = 12;

/// Draws the claims whose XZ box is within `radius` blocks of the player (nearest
/// first, capped), so `/claim show` reveals nearby claims instead of only the one
/// you are standing in. Colored by relationship: white for your own, green for
/// claims you can build on (trusted/alliance), red for everyone else's.
pub fn drawNearby(user: *User, radius: i32) void {
	ensure();
	if (main.server.world == null) return;
	const px = main.server.anticheat.toI32(user.player().pos[0]) orelse return;
	const pz = main.server.anticheat.toI32(user.player().pos[1]) orelse return;
	var chosen: [maxNearbyClaims]NearbyClaim = undefined;
	var chosenCount: usize = 0;
	for (claims.items, 0..) |*c, i| {
		const dx = if (px < c.minX) c.minX - px else if (px > c.maxX) px - c.maxX else 0;
		const dz = if (pz < c.minZ) c.minZ - pz else if (pz > c.maxZ) pz - c.maxZ else 0;
		const dist = @as(i64, dx)*dx + @as(i64, dz)*dz;
		if (dist > @as(i64, radius)*radius) continue;
		if (chosenCount < maxNearbyClaims) {
			chosen[chosenCount] = .{.dist = dist, .index = i};
			chosenCount += 1;
			continue;
		}
		var worst: usize = 0;
		for (chosen, 0..) |cc, j| {
			if (cc.dist > chosen[worst].dist) worst = j;
		}
		if (dist < chosen[worst].dist) chosen[worst] = .{.dist = dist, .index = i};
	}
	for (chosen[0..chosenCount]) |e| {
		const c = &claims.items[e.index];
		if (ownsClaim(c, user)) {
			drawOutline(user, e.index, borderParticle, borderSpawnZon, true);
		} else if (isMember(c, user)) {
			drawOutline(user, e.index, friendParticle, borderSpawnZon, true);
		} else {
			drawOutline(user, e.index, blockedParticle, blockedSpawnZon, true);
		}
	}
}
// --- ASHFRAME CUSTOM (Land claims) ---
