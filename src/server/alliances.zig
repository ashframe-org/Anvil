const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Alliances / villages) ---
// One leader owns the claims; members pool their *unused* claim slots so the
// leader can place more, and get build/chest access to the leader's claims.
// Joining contributes `base - currently owned` slots to the leader; leaving or
// being kicked returns them and trims the leader's newest claims back down.

pub const baseMaxClaims: u16 = 10;
pub const maxAllianceMembers: usize = 5;
pub const maxNameLen: usize = 20;

pub const Result = enum { ok, badName, exists, notFound, alreadyIn, memberLimit, notLeader };

const Member = struct {
	index: usize = 0,
	key: []const u8 = "",
	name: []const u8 = "",
	contributed: u8 = 0,
	joinedAt: i64 = 0,
};

pub const Alliance = struct {
	name: []const u8,
	owner: usize,
	ownerKey: []const u8,
	isPublic: bool,
	/// true = only alliance members may open the alliance's chests.
	chestMembersOnly: bool = true,
	members: [maxAllianceMembers]Member = @splat(.{}),
	memberCount: u8 = 0,
};

const Request = struct {
	alliance: []const u8, // alliance name
	player: usize,
	key: []const u8,
	name: []const u8,
};

var alliances: main.ListManaged(Alliance) = undefined;
var requests: main.ListManaged(Request) = undefined;
var invites: main.ListManaged(Request) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

fn ensure() void {
	if (!ready) {
		alliances = main.ListManaged(Alliance).init(main.globalAllocator);
		requests = main.ListManaged(Request).init(main.globalAllocator);
		invites = main.ListManaged(Request).init(main.globalAllocator);
		ready = true;
	}
}

fn dupe(s: []const u8) []const u8 {
	return main.globalAllocator.dupe(u8, s);
}

fn keyOf(user: *User) []const u8 {
	return user.newKeyString orelse "";
}

pub fn validName(name: []const u8) bool {
	if (name.len == 0 or name.len > maxNameLen) return false;
	for (name) |c| {
		if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-') continue;
		return false;
	}
	return true;
}

pub fn list() []Alliance {
	ensure();
	return alliances.items;
}

pub fn findByName(name: []const u8) ?usize {
	ensure();
	for (alliances.items, 0..) |*a, i| {
		if (std.ascii.eqlIgnoreCase(a.name, name)) return i;
	}
	return null;
}

pub fn findLedBy(index: usize) ?usize {
	ensure();
	for (alliances.items, 0..) |*a, i| {
		if (a.owner == index) return i;
	}
	return null;
}

pub fn findMembership(index: usize) ?usize {
	ensure();
	for (alliances.items, 0..) |*a, i| {
		for (a.members[0..a.memberCount]) |m| {
			if (m.index == index) return i;
		}
	}
	return null;
}

pub fn allianceOf(index: usize) ?usize {
	if (findLedBy(index)) |i| return i;
	return findMembership(index);
}

/// Sum of the unused claim slots the members contributed.
pub fn pooledSlots(a: *const Alliance) u16 {
	var n: u16 = 0;
	for (a.members[0..a.memberCount]) |m| n += m.contributed;
	return n;
}

/// Pooled slots `index` provides as a leader (0 if not a leader). These count as
/// already-unlocked claims for them.
pub fn pooledSlotsFor(index: usize) u16 {
	ensure();
	const ai = findLedBy(index) orelse return 0;
	return pooledSlots(&alliances.items[ai]);
}

/// Member count of the alliance `index` leads (0 if they lead none).
pub fn ledMemberCount(index: usize) usize {
	ensure();
	const ai = findLedBy(index) orelse return 0;
	return alliances.items[ai].memberCount;
}

/// True if `index` is a *member* of an alliance (and not its leader).
pub fn isMember(index: usize) bool {
	ensure();
	if (findLedBy(index) != null) return false;
	return findMembership(index) != null;
}

pub fn maxClaimsFor(index: usize) u16 {
	if (findLedBy(index)) |i| return baseMaxClaims + pooledSlots(&alliances.items[i]);
	if (findMembership(index) != null) return main.server.claims.countOwned(index);
	return baseMaxClaims;
}

/// True if `index` (account `key`) is a member of the alliance led by `leader`.
/// A stored key must match, so a name-adopted `playerIndex` can't inherit
/// membership; keyless (legacy) members fall back to the index.
pub fn isMemberOf(leader: usize, index: usize, key: []const u8) bool {
	ensure();
	const ai = findLedBy(leader) orelse return false;
	const a = &alliances.items[ai];
	for (a.members[0..a.memberCount]) |m| {
		if (m.index != index) continue;
		if (m.key.len == 0) return true;
		return key.len != 0 and std.mem.eql(u8, m.key, key);
	}
	return false;
}

fn freeAlliance(a: *Alliance) void {
	main.globalAllocator.free(a.name);
	if (a.ownerKey.len != 0) main.globalAllocator.free(a.ownerKey);
	for (a.members[0..a.memberCount]) |m| {
		if (m.key.len != 0) main.globalAllocator.free(m.key);
		if (m.name.len != 0) main.globalAllocator.free(m.name);
	}
}

pub fn create(user: *User, name: []const u8, isPublic: bool) Result {
	ensure();
	if (!validName(name)) return .badName;
	if (findByName(name) != null) return .exists;
	if (allianceOf(user.playerIndex) != null) return .alreadyIn;
	alliances.append(.{
		.name = dupe(name),
		.owner = user.playerIndex,
		.ownerKey = dupe(keyOf(user)),
		.isPublic = isPublic,
	});
	return .ok;
}

fn joinCore(leaderIndex: usize, index: usize, key: []const u8, name: []const u8) Result {
	ensure();
	const ai = findLedBy(leaderIndex) orelse return .notFound;
	const a = &alliances.items[ai];
	if (a.memberCount >= maxAllianceMembers) return .memberLimit;
	if (index == leaderIndex) return .alreadyIn;
	if (allianceOf(index) != null) return .alreadyIn;
	const owned = main.server.claims.countOwned(index);
	const contributed: u8 = @intCast(baseMaxClaims -| @as(u16, owned));
	a.members[a.memberCount] = .{
		.index = index,
		.key = dupe(key),
		.name = dupe(name),
		.contributed = contributed,
		.joinedAt = main.timestamp().toSeconds(),
	};
	a.memberCount += 1;
	clearInvite(index);
	clearRequest(index);
	return .ok;
}

/// Directly adds `member` to the alliance led by `leaderIndex`, pooling their
/// unused slots.
pub fn join(leaderIndex: usize, member: *User) Result {
	return joinCore(leaderIndex, member.playerIndex, keyOf(member), member.name);
}

/// Accepts a stored request by name, so an offline requester can be added.
pub fn acceptRequest(leader: *User, name: []const u8) Result {
	ensure();
	const ai = findLedBy(leader.playerIndex) orelse return .notLeader;
	const allianceName = alliances.items[ai].name;
	for (requests.items) |r| {
		if (!std.ascii.eqlIgnoreCase(r.name, name)) continue;
		if (!std.ascii.eqlIgnoreCase(r.alliance, allianceName)) continue;
		return joinCore(leader.playerIndex, r.player, r.key, r.name);
	}
	return .notFound;
}

fn removeMember(a: *Alliance, slot: usize) void {
	const m = a.members[slot];
	if (m.key.len != 0) main.globalAllocator.free(m.key);
	if (m.name.len != 0) main.globalAllocator.free(m.name);
	a.members[slot] = a.members[a.memberCount - 1];
	a.members[a.memberCount - 1] = .{};
	a.memberCount -= 1;
}

/// Called after any membership change: the leader may now own more claims than
/// their (reduced) slot pool allows, so trim the newest ones.
fn trimLeader(owner: usize) void {
	const max = maxClaimsFor(owner);
	main.server.claims.trimToMax(owner, max);
}

pub fn leave(user: *User) void {
	ensure();
	// If the leader leaves, the whole alliance disbands (everyone refunded).
	if (findLedBy(user.playerIndex) != null) {
		disband(user);
		return;
	}
	const ai = findMembership(user.playerIndex) orelse return;
	const a = &alliances.items[ai];
	for (a.members[0..a.memberCount], 0..) |m, slot| {
		if (m.index == user.playerIndex) {
			removeMember(a, slot);
			break;
		}
	}
	trimLeader(a.owner);
}

/// Removes a member by name so offline members can be kicked too. Returns false
/// if no such member exists.
pub fn kickByName(leader: *User, name: []const u8) bool {
	ensure();
	const ai = findLedBy(leader.playerIndex) orelse return false;
	const a = &alliances.items[ai];
	for (a.members[0..a.memberCount], 0..) |m, slot| {
		if (!std.ascii.eqlIgnoreCase(m.name, name)) continue;
		removeMember(a, slot);
		trimLeader(a.owner);
		return true;
	}
	return false;
}

pub fn disband(leader: *User) void {
	ensure();
	const ai = findLedBy(leader.playerIndex) orelse return;
	// Drop pending requests/invites for this alliance (name freed below).
	dropPendingFor(alliances.items[ai].name);
	trimLeader(leader.playerIndex);
	freeAlliance(&alliances.items[ai]);
	_ = alliances.orderedRemove(ai);
}

fn dropPendingList(pending: *main.ListManaged(Request), name: []const u8) void {
	var i: usize = 0;
	while (i < pending.items.len) {
		if (std.ascii.eqlIgnoreCase(pending.items[i].alliance, name)) {
			freeRequest(pending.items[i]);
			_ = pending.swapRemove(i);
			continue;
		}
		i += 1;
	}
}

fn dropPendingFor(name: []const u8) void {
	ensure();
	dropPendingList(&requests, name);
	dropPendingList(&invites, name);
}

// --- Private-alliance join requests ---

pub fn requestJoin(allianceName: []const u8, user: *User) Result {
	ensure();
	if (findByName(allianceName) == null) return .notFound;
	if (allianceOf(user.playerIndex) != null) return .alreadyIn;
	// Replace any previous request from this player.
	clearRequest(user.playerIndex);
	requests.append(.{ .alliance = dupe(allianceName), .player = user.playerIndex, .key = dupe(keyOf(user)), .name = dupe(user.name) });
	return .ok;
}

fn clearRequest(playerIndex: usize) void {
	ensure();
	clearInviteList(&requests, playerIndex);
}

pub fn hasRequest(allianceName: []const u8, playerIndex: usize) bool {
	ensure();
	for (requests.items) |r| {
		if (r.player == playerIndex and std.ascii.eqlIgnoreCase(r.alliance, allianceName)) return true;
	}
	return false;
}

/// Drops a pending request by requester name so offline requesters can be denied.
/// Returns false if no such request exists.
pub fn denyRequestByName(leader: *User, name: []const u8) bool {
	ensure();
	const ai = findLedBy(leader.playerIndex) orelse return false;
	var removed = false;
	var i: usize = 0;
	while (i < requests.items.len) {
		const r = requests.items[i];
		if (std.ascii.eqlIgnoreCase(r.name, name) and std.ascii.eqlIgnoreCase(r.alliance, alliances.items[ai].name)) {
			freeRequest(r);
			_ = requests.swapRemove(i);
			removed = true;
			continue;
		}
		i += 1;
	}
	return removed;
}

// --- Leader invitations ---

pub fn invite(leader: *User, target: *User) Result {
	ensure();
	const ai = findLedBy(leader.playerIndex) orelse return .notLeader;
	if (allianceOf(target.playerIndex) != null) return .alreadyIn;
	clearInvite(target.playerIndex);
	invites.append(.{ .alliance = dupe(alliances.items[ai].name), .player = target.playerIndex, .key = dupe(keyOf(target)), .name = dupe(target.name) });
	return .ok;
}

pub fn hasInvite(allianceName: []const u8, playerIndex: usize) bool {
	ensure();
	for (invites.items) |r| {
		if (r.player == playerIndex and std.ascii.eqlIgnoreCase(r.alliance, allianceName)) return true;
	}
	return false;
}

fn freeRequest(r: Request) void {
	main.globalAllocator.free(r.alliance);
	if (r.key.len != 0) main.globalAllocator.free(r.key);
	if (r.name.len != 0) main.globalAllocator.free(r.name);
}

fn clearInviteList(pending: *main.ListManaged(Request), playerIndex: usize) void {
	var i: usize = 0;
	while (i < pending.items.len) {
		if (pending.items[i].player == playerIndex) {
			freeRequest(pending.items[i]);
			_ = pending.swapRemove(i);
			continue;
		}
		i += 1;
	}
}

fn clearInvite(playerIndex: usize) void {
	ensure();
	clearInviteList(&invites, playerIndex);
}

pub fn setChestMembersOnly(leader: *User, membersOnly: bool) bool {
	ensure();
	const ai = findLedBy(leader.playerIndex) orelse return false;
	alliances.items[ai].chestMembersOnly = membersOnly;
	return true;
}

// --- Persistence ---

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_alliances.zig.zon", .{worldPath});
}

pub fn load(worldPath: []const u8) void {
	ensure();
	for (alliances.items) |*a| freeAlliance(a);
	alliances.clearRetainingCapacity();
	for (requests.items) |r| freeRequest(r);
	requests.clearRetainingCapacity();
	for (invites.items) |r| freeRequest(r);
	invites.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("alliances").toSlice()) |e| {
		const name = e.get([]const u8, "name") orelse continue;
		var a = Alliance{
			.name = dupe(name),
			.owner = e.get(usize, "owner") orelse 0,
			.ownerKey = if (e.get([]const u8, "ownerKey")) |k| dupe(k) else "",
			.isPublic = e.get(bool, "public") orelse false,
			.chestMembersOnly = e.get(bool, "chestMembersOnly") orelse true,
		};
		for (e.getChild("members").toSlice()) |m| {
			if (a.memberCount >= maxAllianceMembers) break;
			a.members[a.memberCount] = .{
				.index = m.get(usize, "index") orelse continue,
				.key = if (m.get([]const u8, "key")) |k| dupe(k) else "",
				.name = if (m.get([]const u8, "name")) |nm| dupe(nm) else "",
				.contributed = m.get(u8, "contributed") orelse 0,
				.joinedAt = m.get(i64, "joinedAt") orelse 0,
			};
			a.memberCount += 1;
		}
		alliances.append(a);
	}
	for (zon.getChild("requests").toSlice()) |e| {
		const alliance = e.get([]const u8, "alliance") orelse continue;
		requests.append(.{
			.alliance = dupe(alliance),
			.player = e.get(usize, "player") orelse continue,
			.key = if (e.get([]const u8, "key")) |k| dupe(k) else "",
			.name = if (e.get([]const u8, "name")) |nm| dupe(nm) else "",
		});
	}
	for (zon.getChild("invites").toSlice()) |e| {
		const alliance = e.get([]const u8, "alliance") orelse continue;
		invites.append(.{
			.alliance = dupe(alliance),
			.player = e.get(usize, "player") orelse continue,
			.key = if (e.get([]const u8, "key")) |k| dupe(k) else "",
			.name = if (e.get([]const u8, "name")) |nm| dupe(nm) else "",
		});
	}
}

pub fn save(worldPath: []const u8) void {
	ensure();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var arr = main.ZonElement.initArray(main.stackAllocator);
	for (alliances.items) |*a| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("name", a.name);
		e.put("owner", a.owner);
		if (a.ownerKey.len != 0) e.put("ownerKey", a.ownerKey);
		e.put("public", a.isPublic);
		e.put("chestMembersOnly", a.chestMembersOnly);
		var memArr = main.ZonElement.initArray(main.stackAllocator);
		for (a.members[0..a.memberCount]) |m| {
			var me = main.ZonElement.initObject(main.stackAllocator);
			me.put("index", m.index);
			if (m.key.len != 0) me.put("key", m.key);
			if (m.name.len != 0) me.put("name", m.name);
			me.put("contributed", m.contributed);
			me.put("joinedAt", m.joinedAt);
			memArr.array.append(me);
		}
		e.put("members", memArr);
		arr.array.append(e);
	}
	zon.put("alliances", arr);
	var reqArr = main.ZonElement.initArray(main.stackAllocator);
	for (requests.items) |r| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("alliance", r.alliance);
		e.put("player", r.player);
		if (r.key.len != 0) e.put("key", r.key);
		if (r.name.len != 0) e.put("name", r.name);
		reqArr.array.append(e);
	}
	zon.put("requests", reqArr);
	var invArr = main.ZonElement.initArray(main.stackAllocator);
	for (invites.items) |r| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("alliance", r.alliance);
		e.put("player", r.player);
		if (r.key.len != 0) e.put("key", r.key);
		if (r.name.len != 0) e.put("name", r.name);
		invArr.array.append(e);
	}
	zon.put("invites", invArr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe alliances data: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}
// --- ASHFRAME CUSTOM (Alliances) ---
