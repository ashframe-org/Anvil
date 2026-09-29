const std = @import("std");

const main = @import("main");
const User = main.server.User;
const Vec3i = main.vec.Vec3i;
const BinaryWriter = main.utils.BinaryWriter;
const Inventory = main.items.Inventory;
const BaseItemIndex = main.items.BaseItemIndex;

// --- ASHFRAME CUSTOM (Sign shops) ---
// A chest with an adjacent sign. The shop is stored server-side in a registry
// keyed by the chest position and bound to the owner's account key, so the sign
// text can't be used to impersonate the owner. The sign is display-only.
//
// The owner opens the chest normally (stock it / collect earnings); anyone else
// right-clicking it trades: they pay the price into the chest and receive the
// goods (or vice versa for a "buy" shop). Buy and sell both supported.

/// Last few chest slots are meant to stay free so payouts always fit. Soft
/// reserve: the owner is warned, and a trade is refused if the chest is full.
pub const reservedSlots: usize = 2;

// --- ASHFRAME CUSTOM (Sign shops: confirmation menu) ---
// A customer clicking a shop chest does NOT see the chest. The server opens a
// shareable 20-slot "menu" inventory instead, holding only two markers: a green
// block the customer clicks to buy, and a red block to cancel. The customer's
// slot click arrives as a normal inventory command, which we intercept by
// inventory source + slot; nothing else in the menu is movable.
pub const menuSize: usize = 20;
/// Menu slots the customer clicks. Anything else is rejected.
pub const menuGreenSlot: usize = 0; // buy (0-indexed: first slot)
pub const menuRedSlot: usize = 9; // cancel (0-indexed: tenth slot)
// --- ASHFRAME CUSTOM (Sign shops) ---

const signType = main.block_entity.BlockEntityTypes.@"cubyz:sign";

pub const Mode = enum { sell, buy };

const Pair = struct { item: BaseItemIndex, amount: u16 };

const Shop = struct {
	chest: [3]i32, // (x, z, vertical)
	sign: [3]i32,
	owner: []const u8, // account key string (or name for local play)
	mode: Mode,
	goodsItem: u16,
	goodsAmount: u16,
	priceItem: u16,
	priceAmount: u16,
};

var shops: main.ListManaged(Shop) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

const Neighbor = struct { dx: i32, dz: i32, dv: i32 };
/// The five sides a shop sign may sit on (everything except below the chest).
const neighbors = [_]Neighbor{
	.{.dx = 0, .dz = 0, .dv = 1}, // above
	.{.dx = 1, .dz = 0, .dv = 0},
	.{.dx = -1, .dz = 0, .dv = 0},
	.{.dx = 0, .dz = 1, .dv = 0},
	.{.dx = 0, .dz = -1, .dv = 0},
};

fn ensure() void {
	if (!ready) {
		shops = main.ListManaged(Shop).init(main.globalAllocator);
		ready = true;
	}
}

fn eq(p: [3]i32, q: Vec3i) bool {
	return p[0] == q[0] and p[1] == q[1] and p[2] == q[2];
}

/// The stable identity used for shop ownership. Account key where available.
fn ownerId(user: *User) []const u8 {
	return user.newKeyString orelse user.name;
}

fn isOwner(user: *User, shop: *const Shop) bool {
	return std.mem.eql(u8, shop.owner, ownerId(user));
}

pub fn isSignBlock(block: main.blocks.Block) bool {
	const be = block.blockEntity() orelse return false;
	return std.mem.eql(u8, be.id, "cubyz:sign");
}

pub fn isChestBlock(block: main.blocks.Block) bool {
	const be = block.blockEntity() orelse return false;
	return std.mem.eql(u8, be.id, "cubyz:chest");
}

/// The id without its addon/mod namespace, e.g. "cubyz:amber_ore" -> "amber_ore".
pub fn shortId(item: BaseItemIndex) []const u8 {
	const id = item.id();
	if (std.mem.indexOfScalar(u8, id, ':')) |colon| return id[colon + 1 ..];
	return id;
}

/// Resolves an item by full id, by id without its namespace, or by display name.
/// All lookups except the exact full id are case-insensitive, so "amber_ore",
/// "Amber_ore", "cubyz:amber_ore" and "Amber Ore" all work.
pub fn resolveItem(str: []const u8) ?BaseItemIndex {
	if (BaseItemIndex.fromId(str)) |item| return item;
	// Match the part of the id after the namespace.
	var i: u16 = 0;
	while (i < main.items.itemListSize) : (i += 1) {
		const index: BaseItemIndex = @enumFromInt(i);
		if (std.ascii.eqlIgnoreCase(shortId(index), str)) return index;
	}
	// Fall back to the display name.
	i = 0;
	while (i < main.items.itemListSize) : (i += 1) {
		const index: BaseItemIndex = @enumFromInt(i);
		if (std.ascii.eqlIgnoreCase(index.name(), str)) return index;
	}
	return null;
}

/// True for sign woods pale enough that the standard yellow/white shop text
/// washes out (measured texture luminance; threshold ~130: baobab, birch,
/// palm). All other woods — and unknown/addon signs — use the light scheme.
/// Signs render text with no shadow/outline, so contrast with the wood is the
/// only thing keeping text readable.
pub fn schemeForId(id: []const u8) bool {
	return std.mem.endsWith(u8, id, "sign/baobab") or
		std.mem.endsWith(u8, id, "sign/birch") or
		std.mem.endsWith(u8, id, "sign/palm");
}

/// True if `block` is a pale sign needing the dark text scheme.
pub fn signIsLight(block: main.blocks.Block) bool {
	return schemeForId(block.id());
}

/// Max bytes of a player's (visible) name stored on a shop sign, so long names
/// don't overflow the sign.
pub const maxNameLen: usize = 16;

/// Strips Cubyz color codes (§#rrggbb) and truncates to `maxNameLen` bytes at a
/// valid UTF-8 boundary. Writes into `buf` and returns the used slice.
pub fn signName(name: []const u8, buf: *[maxNameLen]u8) []const u8 {
	var len: usize = 0;
	var i: usize = 0;
	while (i < name.len and len < maxNameLen) {
		if (std.mem.startsWith(u8, name[i..], "\u{00a7}")) {
			i += 1;
			if (i < name.len and name[i] == '#') i += 7;
			continue;
		}
		buf[len] = name[i];
		len += 1;
		i += 1;
	}
	while (len > 0 and !std.unicode.utf8ValidateSlice(buf[0..len])) len -= 1;
	return buf[0..len];
}

/// Formats the offer text written onto a shop sign. Line 1 gets its own color so
/// it stands out; the color code is stripped when rendered, so it costs no space.
/// Lines 2-3 are from the customer's point of view (`-` they give, `+` they get),
/// and list the price first, then the goods.
/// `lightSign` selects the text scheme: pale woods get black text (yellow and
/// white are unreadable on them), dark woods keep yellow-on-white.
pub fn formatSignText(mode: Mode, amount: u16, goodsName: []const u8, priceAmount: u16, priceName: []const u8, ownerName: []const u8, lightSign: bool, buf: []u8) ![]const u8 {
	const modeName = if (mode == .sell) "Sell" else "Buy";
	const priceSign = if (mode == .sell) "-" else "+";
	const goodsSign = if (mode == .sell) "+" else "-";
	if (lightSign) {
		return std.fmt.bufPrint(buf, "#000000[Shop] {s}#000000\n{s}{d}x {s}\n{s}{d}x {s}\n{s}", .{modeName, priceSign, priceAmount, priceName, goodsSign, amount, goodsName, ownerName});
	}
	return std.fmt.bufPrint(buf, "#ffcc00[Shop] {s}#ffffff\n{s}{d}x {s}\n{s}{d}x {s}\n{s}", .{modeName, priceSign, priceAmount, priceName, goodsSign, amount, goodsName, ownerName});
}

/// Formats and writes a shop sign, picking the text scheme with contrast
/// against the actual sign wood. Broadcasts the update. False when there is
/// no loaded sign at `pos`.
pub fn writeShopSign(sign: Vec3i, mode: Mode, amount: u16, goods: BaseItemIndex, priceAmount: u16, price: BaseItemIndex, ownerName: []const u8) bool {
	const world = main.server.world orelse return false;
	const block = world.getBlock(sign[0], sign[1], sign[2]) orelse return false;
	if (!isSignBlock(block)) return false;
	var buf: [256]u8 = undefined;
	const text = formatSignText(mode, amount, shortId(goods), priceAmount, shortId(price), ownerName, signIsLight(block), &buf) catch return false;
	if (!writeSign(sign, text)) return false;
	main.network.protocols.blockEntityUpdate.sendServerDataUpdateToClients(sign);
	return true;
}

/// Writes `text` into the sign at `pos` server-side. Returns false if there's
/// no sign there.
pub fn writeSign(pos: Vec3i, text: []const u8) bool {
	const world = main.server.world orelse return false;
	const simChunk = world.getSimulationChunkAndIncreaseRefCount(pos[0], pos[1], pos[2]) orelse return false;
	defer simChunk.decreaseRefCount();
	const ch = simChunk.chunk.load(.monotonic) orelse return false;
	ch.mutex.lock();
	defer ch.mutex.unlock();
	const block = ch.getBlock(pos[0] - ch.super.pos.wx, pos[1] - ch.super.pos.wy, pos[2] - ch.super.pos.wz);
	if (!isSignBlock(block)) return false;
	signType.setText(pos, &ch.super, text);
	// Mark the chunk dirty, otherwise the new sign text isn't written to disk.
	ch.setChanged();
	return true;
}

/// A shop sign must be mounted on a horizontal (side) face of the chest, not
/// merely adjacent. `cubyz:sign` stores its mounting direction in `block.data`
/// (see mods/cubyz/rotations/sign.zig): 0..7 = ceiling, 8..15 = floor,
/// 16..19 = side (dirNegX, dirNegY, dirPosX, dirPosY). World/shop coords here
/// are (x, horizontal, vertical), matching chunk.Neighbor (relZ is vertical).
/// Returns the block the sign is attached to, or null for floor/ceiling mounts
/// and malformed data.
fn signAttachmentPos(signPos: Vec3i, signBlock: main.blocks.Block) ?Vec3i {
	const data = signBlock.data;
	const off: Vec3i = switch (data) {
		16 => .{-1, 0, 0}, // dirNegX
		17 => .{0, -1, 0}, // dirNegY (horizontal)
		18 => .{1, 0, 0}, // dirPosX
		19 => .{0, 1, 0}, // dirPosY (horizontal)
		else => return null, // floor/ceiling mount or invalid: not a valid shop sign
	};
	return .{signPos[0] + off[0], signPos[1] + off[1], signPos[2] + off[2]};
}

/// True if the sign at `signPos` is side-mounted directly on the block at
/// `attachedPos`.
fn signMountedOn(signPos: Vec3i, signBlock: main.blocks.Block, attachedPos: Vec3i) bool {
	const attached = signAttachmentPos(signPos, signBlock) orelse return false;
	return eq(.{attached[0], attached[1], attached[2]}, attachedPos);
}

/// The chest a sign is mounted on, or null if the sign isn't side-mounted on a
/// chest. Only the sign's own mounting direction is consulted, so a sign on a
/// neighbouring block that merely faces the chest does NOT qualify.
pub fn mountedChestOfSign(signPos: Vec3i) ?Vec3i {
	const world = main.server.world orelse return null;
	const signBlock = world.getBlock(signPos[0], signPos[1], signPos[2]) orelse return null;
	if (!isSignBlock(signBlock)) return null;
	const attached = signAttachmentPos(signPos, signBlock) orelse return null;
	const attachedBlock = world.getBlock(attached[0], attached[1], attached[2]) orelse return null;
	if (!isChestBlock(attachedBlock)) return null;
	return attached;
}

/// The sign mounted directly on `chest` (side mount only), or null.
pub fn findNeighborSign(pos: Vec3i) ?Vec3i {
	const world = main.server.world orelse return null;
	for (neighbors) |n| {
		const p = Vec3i{pos[0] + n.dx, pos[1] + n.dz, pos[2] + n.dv};
		const block = world.getBlock(p[0], p[1], p[2]) orelse continue;
		if (!isSignBlock(block)) continue;
		if (signMountedOn(p, block, pos)) return p;
	}
	return null;
}

pub fn findNeighborChest(pos: Vec3i) ?Vec3i {
	// The sign must be mounted on the chest it returns (side mount only).
	return mountedChestOfSign(pos);
}

/// Simple ray-march from the player's eye along their look direction, returning
/// the first solid block within `maxDist`. World coords are (x, z, vertical).
pub fn lookAtBlock(user: *User, maxDist: f64) ?Vec3i {
	const world = main.server.world orelse return null;
	const prof = user.player();
	const dir = main.vec.rotateZ(main.vec.rotateX(main.vec.Vec3f{0, 1, 0}, -prof.rot[0]), -prof.rot[2]);
	const startX = prof.pos[0];
	const startZ = prof.pos[1];
	const startV = prof.pos[2] + 1.6;
	const dx: f64 = dir[0];
	const dz: f64 = dir[1];
	const dv: f64 = dir[2];
	var t: f64 = 0;
	while (t <= maxDist) : (t += 0.05) {
		const bx = main.server.anticheat.toI32(startX + dx*t) orelse return null;
		const bz = main.server.anticheat.toI32(startZ + dz*t) orelse return null;
		const bv = main.server.anticheat.toI32(startV + dv*t) orelse return null;
		const block = world.getBlock(bx, bz, bv) orelse continue;
		if (block.typ != main.blocks.Block.air.typ) return .{bx, bz, bv};
	}
	return null;
}

fn findAtChest(chest: Vec3i) ?usize {
	ensure();
	for (shops.items, 0..) |*s, i| {
		if (eq(s.chest, chest)) return i;
	}
	return null;
}

fn findAtSign(sign: Vec3i) ?usize {
	ensure();
	for (shops.items, 0..) |*s, i| {
		if (eq(s.sign, sign)) return i;
	}
	return null;
}

/// Creates or replaces the shop for `chest`, binding it to `user`.
/// Creates (or, for the owner, updates) a shop. Returns false if the chest is
/// already another player's shop: rebinding it would let a cheater take over and
/// then break/loot someone else's shop chest.
pub fn create(user: *User, chest: Vec3i, sign: Vec3i, mode: Mode, goods: BaseItemIndex, goodsAmount: u16, price: BaseItemIndex, priceAmount: u16) bool {
	ensure();
	const me = ownerId(user);
	const entry = Shop{
		.chest = .{chest[0], chest[1], chest[2]},
		.sign = .{sign[0], sign[1], sign[2]},
		.owner = undefined,
		.mode = mode,
		.goodsItem = @intFromEnum(goods),
		.goodsAmount = goodsAmount,
		.priceItem = @intFromEnum(price),
		.priceAmount = priceAmount,
	};
	if (findAtChest(chest)) |i| {
		if (!std.mem.eql(u8, shops.items[i].owner, me)) return false;
		main.globalAllocator.free(shops.items[i].owner);
		shops.items[i] = entry;
		shops.items[i].owner = main.globalAllocator.dupe(u8, me);
	} else {
		shops.append(entry);
		shops.items[shops.items.len - 1].owner = main.globalAllocator.dupe(u8, me);
	}
	saveCurrentWorld();
	return true;
}

/// True if `chest` already holds a shop belonging to someone else.
pub fn chestOwnedByOther(user: *User, chest: Vec3i) bool {
	ensure();
	const i = findAtChest(chest) orelse return false;
	return !isOwner(user, &shops.items[i]);
}

/// Removes any shop whose chest or sign is the block at `pos`.
pub fn onBroken(pos: Vec3i, oldBlock: main.blocks.Block) void {
	if (!isChestBlock(oldBlock) and !isSignBlock(oldBlock)) return;
	ensure();
	var i: usize = 0;
	while (i < shops.items.len) {
		if (eq(shops.items[i].chest, pos) or eq(shops.items[i].sign, pos)) {
			// Drop any confirmation menus opened for this shop.
			closeMenusAt(shops.items[i].chest);
			main.globalAllocator.free(shops.items[i].owner);
			_ = shops.swapRemove(i);
			continue;
		}
		i += 1;
	}
	saveCurrentWorld();
}

/// Destroys any open confirmation menu for the given shop chest. Safe if none.
fn closeMenusAt(chest: [3]i32) void {
	ensureMenus();
	var i: usize = 0;
	while (i < menus.items.len) {
		if (menus.items[i].chest[0] == chest[0] and menus.items[i].chest[1] == chest[1] and menus.items[i].chest[2] == chest[2]) {
			Inventory.server.destroyExternallyManagedInventory(menus.items[i].invId);
			_ = menus.swapRemove(i);
			continue;
		}
		i += 1;
	}
}

/// True if the sign at `pos` is a shop sign owned by someone other than `user`,
/// in which case a text edit from `user` must be rejected.
pub fn rejectEdit(user: *User, pos: Vec3i) bool {
	const i = findAtSign(pos) orelse return false;
	return !isOwner(user, &shops.items[i]);
}

/// True if `user` may break the block at `pos`. Shop chests and their signs are
/// locked to their owner.
pub fn canBreak(user: *User, pos: Vec3i, oldBlock: main.blocks.Block) bool {
	const i = if (isChestBlock(oldBlock)) findAtChest(pos) else if (isSignBlock(oldBlock)) findAtSign(pos) else return true;
	const idx = i orelse return true;
	return isOwner(user, &shops.items[idx]);
}

fn countItem(inv: Inventory, item: BaseItemIndex) u32 {
	var total: u32 = 0;
	for (inv._items) |stack| {
		if (stack.item == .baseItem and stack.item.baseItem == item) total += stack.amount;
	}
	return total;
}

fn removeItem(inv: Inventory, item: BaseItemIndex, amount: u16) void {
	var remaining = amount;
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (!(stack.item == .baseItem and stack.item.baseItem == item)) continue;
		const take = @min(remaining, stack.amount);
		if (stack.amount > take) {
			main.sync.server.executeCommand(.{.fillFromCreative = .{
				.dest = .{.inv = inv, .slot = @intCast(i)},
				.item = stack.item,
				.amount = stack.amount - take,
			}}, null);
		} else {
			main.sync.server.executeCommand(.{.fillFromCreative = .{
				.dest = .{.inv = inv, .slot = @intCast(i)},
				.item = .null,
			}}, null);
		}
		remaining -= take;
	}
}

fn canAdd(inv: Inventory, item: BaseItemIndex, amount: u16) bool {
	var room: u32 = 0;
	for (inv._items) |stack| {
		if (stack.item == .baseItem and stack.item.baseItem == item) {
			if (stack.amount > item.stackSize()) return true; // corrupt stack; don't underflow
			room += item.stackSize() - stack.amount;
		} else if (stack.item == .null) {
			room += item.stackSize();
		}
	}
	return room >= amount;
}

fn addItem(inv: Inventory, item: BaseItemIndex, amount: u16) void {
	var remaining = amount;
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (!(stack.item == .baseItem and stack.item.baseItem == item)) continue;
		if (stack.amount >= item.stackSize()) continue;
		const space = item.stackSize() - stack.amount;
		const add = @min(remaining, space);
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(i)},
			.item = stack.item,
			.amount = stack.amount + add,
		}}, null);
		remaining -= add;
	}
	for (inv._items, 0..) |stack, i| {
		if (remaining == 0) break;
		if (stack.item != .null) continue;
		const add = @min(remaining, item.stackSize());
		main.sync.server.executeCommand(.{.fillFromCreative = .{
			.dest = .{.inv = inv, .slot = @intCast(i)},
			.item = .{.baseItem = item},
			.amount = add,
		}}, null);
		remaining -= add;
	}
}

/// Called when a chest inventory is closed. If it is a shop chest whose payout
/// slots are occupied, warn the owner (so they know before a trade fails).
pub fn onChestClosed(source: main.items.Inventory.Source) void {
	const chest = source.blockInventory;
	const i = findAtChest(chest) orelse return;
	const shop = &shops.items[i];
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |user| {
		if (std.mem.eql(u8, ownerId(user), shop.owner)) {
			warnOwner(user, chest);
			return;
		}
	}
}

fn warnOwner(user: *User, chest: Vec3i) void {
	const inv = Inventory.server.getInventoryFromSource(.{.blockInventory = chest}) orelse return;
	const size = inv.size();
	if (size <= reservedSlots) return;
	var occupied: usize = 0;
	for (size - reservedSlots..size) |i| {
		if (inv._items[i].item != .null) occupied += 1;
	}
	if (occupied > 0) {
		user.sendMessage("#e6312cHeads up: #cfcfcfkeep the last {d} slots of this shop chest free for payouts, or it can't sell.", .{reservedSlots});
	}
}

/// Executes a trade from the customer's side. Returns true on success (so the
/// menu can close with a positive outcome), false if it was refused for any
/// reason (the customer already got an explanatory message).
fn doTrade(user: *User, shop: *const Shop) bool {
	// Bisect toggle: economy frozen while off.
	if (!main.settings.launchConfig.serverAuthoritativeCharges) {
		user.sendMessage("#e6312cShops are temporarily disabled.", .{});
		return false;
	}
	const goods: BaseItemIndex = @enumFromInt(shop.goodsItem);
	const price: BaseItemIndex = @enumFromInt(shop.priceItem);

	const playerInv = Inventory.server.getInventoryFromSource(.{.playerInventory = user.id}) orelse {
		user.sendMessage("#e6312cCould not find your inventory.", .{});
		return false;
	};
	const chestInv = Inventory.server.getInventoryFromSource(.{.blockInventory = .{shop.chest[0], shop.chest[1], shop.chest[2]}}) orelse {
		user.sendMessage("#e6312cThis shop is unavailable.", .{});
		return false;
	};

	// From the customer's point of view: what they hand over and what they get.
	const customerPays: Pair = if (shop.mode == .sell) .{.item = price, .amount = shop.priceAmount} else .{.item = goods, .amount = shop.goodsAmount};
	const customerGets: Pair = if (shop.mode == .sell) .{.item = goods, .amount = shop.goodsAmount} else .{.item = price, .amount = shop.priceAmount};

	if (countItem(chestInv, customerGets.item) < customerGets.amount) {
		if (shop.mode == .sell) {
			user.sendMessage("#e6312cThis shop is out of stock.", .{});
		} else {
			user.sendMessage("#e6312cThis shop can't pay out right now.", .{});
		}
		return false;
	}
	if (countItem(playerInv, customerPays.item) < customerPays.amount) {
		user.sendMessage("#e6312cYou need #e6312c{d} {s}#cfcfcf for this.", .{customerPays.amount, customerPays.item.name()});
		return false;
	}
	if (!canAdd(chestInv, customerPays.item, customerPays.amount)) {
		user.sendMessage("#e6312cThis shop is full and can't accept the trade right now.", .{});
		return false;
	}
	if (!canAdd(playerInv, customerGets.item, customerGets.amount)) {
		user.sendMessage("#e6312cYour inventory is too full to receive the items.", .{});
		return false;
	}

	removeItem(playerInv, customerPays.item, customerPays.amount);
	addItem(chestInv, customerPays.item, customerPays.amount);
	removeItem(chestInv, customerGets.item, customerGets.amount);
	addItem(playerInv, customerGets.item, customerGets.amount);

	user.player().shopTrades +|= 1;
	// Always from the customer's point of view: "Bought <received> for <paid>".
	// `customerGets` is what they receive, `customerPays` what they hand over.
	var buf: [256]u8 = undefined;
	const summary = tradeSummaryParts(
		user.name,
		customerGets.amount,
		customerGets.item.name(),
		customerPays.amount,
		customerPays.item.name(),
		&buf,
	) catch "trade";
	user.sendMessage("#00ff00{s}#00ff00.", .{summary});
	notifyOwner(shop, summary);
	return true;
}

/// Formats a completed trade from the buyer's point of view:
/// "<buyer> bought <receivedCount> <receivedItem> for <paidCount> <paidItem>".
/// Using the customer's actual give/take avoids the old bug where buy-shops
/// (owner buys) reported the goods/price the wrong way around.
fn tradeSummaryParts(buyerName: []const u8, receivedCount: u16, receivedName: []const u8, paidCount: u16, paidName: []const u8, buf: []u8) ![]const u8 {
	return std.fmt.bufPrint(buf, "{s} bought {d} {s} for {d} {s}", .{ buyerName, receivedCount, receivedName, paidCount, paidName });
}

/// Tells the shop owner a sale happened. The online owner (matched by account
/// key) gets a chat message; otherwise it is only logged (nothing to deliver to
/// an offline player without mail). `summary` is the buyer-facing sentence so
/// both sides agree on the direction.
fn notifyOwner(shop: *const Shop, summary: []const u8) void {
	std.log.info("[ashframe] shop sale: {s}", .{summary});
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	for (userList) |u| {
		if (std.mem.eql(u8, ownerId(u), shop.owner)) {
			u.sendMessage("#00ff00Sale! #cfcfcf{s}#00ff00.", .{summary});
			return;
		}
	}
}

/// Called when a player opens a shop chest.
/// Returns:
///  - null  -> not a shop (open the chest normally)
///  - menu  -> the customer should be shown the confirmation menu instead
/// Owner opens the real chest (to restock); a customer gets the menu.
pub const ChestOpen = union(enum) { menu: Vec3i };

pub fn handleChestOpen(user: *User, chest: Vec3i) ?ChestOpen {
	const i = findAtChest(chest) orelse return null;
	if (isOwner(user, &shops.items[i])) {
		warnOwner(user, chest);
		return null;
	}
	return .{.menu = chest};
}

// --- ASHFRAME CUSTOM (Sign shops: confirmation menu) ---

/// Menu inventories, keyed by shop chest position. Created on first open,
/// shared by every customer currently deciding, destroyed when the last one
/// closes.
const Menu = struct {
	chest: [3]i32,
	invId: Inventory.InventoryId,
};
var menus: main.ListManaged(Menu) = undefined;
var menusReady: bool = false;

fn ensureMenus() void {
	if (!menusReady) {
		menus = main.ListManaged(Menu).init(main.globalAllocator);
		menusReady = true;
	}
}

fn findMenu(chest: Vec3i) ?usize {
	ensureMenus();
	for (menus.items, 0..) |m, i| {
		if (m.chest[0] == chest[0] and m.chest[1] == chest[1] and m.chest[2] == chest[2]) return i;
	}
	return null;
}

/// Green "yes" marker and red "no" marker item ids. Falls back gracefully if an
/// asset is missing (menu would be empty, so we refuse to show it).
fn greenMarker() ?BaseItemIndex {
	return BaseItemIndex.fromId("cubyz:chalk/green");
}
fn redMarker() ?BaseItemIndex {
	return BaseItemIndex.fromId("cubyz:chalk/red");
}

fn menuLastClose(source: Inventory.Source) void {
	// All customers have closed; tear the menu down. `source` is the menu pos.
	if (source != .shopMenu) return;
	const chest = source.shopMenu;
	const i = findMenu(chest) orelse return;
	const invId = menus.items[i].invId;
	_ = menus.swapRemove(i);
	Inventory.server.destroyExternallyManagedInventory(invId);
}

/// Returns the menu inventory id for `chest`, creating and populating it on
/// first use. Null if the marker items are unavailable.
pub fn openMenu(chest: Vec3i) ?Inventory.InventoryId {
	ensureMenus();
	if (findMenu(chest)) |i| return menus.items[i].invId;

	const green = greenMarker() orelse return null;
	const red = redMarker() orelse return null;

	const callbacks = Inventory.Callbacks{.onLastCloseCallback = &menuLastClose};
	var empty = main.utils.BinaryReader.init(&.{});
	const invId = Inventory.server.createExternallyManagedInventory(menuSize, .{.shopMenu = chest}, &empty, callbacks);
	const inv = Inventory.server.getInventoryFromId(invId);
	setMenuSlot(inv, menuGreenSlot, green);
	setMenuSlot(inv, menuRedSlot, red);

	menus.append(.{.chest = .{chest[0], chest[1], chest[2]}, .invId = invId});
	return invId;
}

fn setMenuSlot(inv: Inventory, slot: usize, item: BaseItemIndex) void {
	main.sync.server.executeCommand(.{.fillFromCreative = .{
		.dest = .{.inv = inv, .slot = @intCast(slot)},
		.item = .{.baseItem = item},
		.amount = 1,
	}}, null);
}

/// Called from the inventory-command interception when a customer clicks a slot
/// of a shop menu. `slot` is the clicked menu slot. Returns true if the click was
/// consumed (the caller must not perform the physical swap).
pub fn handleMenuClick(user: *User, menuPos: [3]i32, slot: usize) bool {
	const chest: Vec3i = .{menuPos[0], menuPos[1], menuPos[2]};
	if (slot == menuGreenSlot) {
		if (findAtChest(chest)) |i| {
			_ = doTrade(user, &shops.items[i]);
		} else {
			user.sendMessage("#e6312cThis shop no longer exists.", .{});
		}
		return true;
	}
	if (slot == menuRedSlot) {
		user.sendMessage("#cfcfcfPurchase cancelled.", .{});
		return true;
	}
	// Any other slot holds nothing meaningful: reject silently but consume it.
	return true;
}

// --- ASHFRAME CUSTOM (Sign shops) ---

// --- Persistence ---

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_shops.zig.zon", .{worldPath});
}

fn saveCurrentWorld() void {
	const world = main.server.world orelse return;
	save(world.path);
}

fn readTriple(entry: main.ZonElement, key: []const u8) ?[3]i32 {
	const a = entry.getChild(key).toSlice();
	if (a.len != 3) return null;
	return .{ a[0].as(i32) orelse return null, a[1].as(i32) orelse return null, a[2].as(i32) orelse return null };
}

pub fn load(worldPath: []const u8) void {
	ensure();
	for (shops.items) |s| main.globalAllocator.free(s.owner);
	shops.clearRetainingCapacity();
	// Any menus from a previous world are gone too.
	ensureMenus();
	while (menus.items.len != 0) {
		Inventory.server.destroyExternallyManagedInventory(menus.pop().invId);
	}
	// Re-render every sign with the current (sign-aware) colors once chunks
	// are available; see refreshTick.
	refreshDone = false;
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("shops").toSlice()) |entry| {
		const chest = readTriple(entry, "chest") orelse continue;
		const sign = readTriple(entry, "sign") orelse continue;
		const owner = entry.get([]const u8, "owner") orelse continue;
		const modeStr = entry.get([]const u8, "mode") orelse "sell";
		const mode: Mode = if (std.mem.eql(u8, modeStr, "buy")) .buy else .sell;
		const goodsItem = entry.get(u16, "goodsItem") orelse continue;
		const goodsAmount = entry.get(u16, "goodsAmount") orelse continue;
		const priceItem = entry.get(u16, "priceItem") orelse continue;
		const priceAmount = entry.get(u16, "priceAmount") orelse continue;
		// Skip entries whose items no longer exist (e.g. an addon was removed).
		if (goodsItem >= main.items.itemListSize or priceItem >= main.items.itemListSize) continue;
		shops.append(.{
			.chest = chest,
			.sign = sign,
			.owner = main.globalAllocator.dupe(u8, owner),
			.mode = mode,
			.goodsItem = goodsItem,
			.goodsAmount = goodsAmount,
			.priceItem = priceItem,
			.priceAmount = priceAmount,
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
	for (shops.items) |*s| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		var ca = main.ZonElement.initArray(main.stackAllocator);
		for (s.chest) |v| ca.array.append(.{.int = v});
		e.put("chest", ca);
		var sa = main.ZonElement.initArray(main.stackAllocator);
		for (s.sign) |v| sa.array.append(.{.int = v});
		e.put("sign", sa);
		e.put("owner", s.owner);
		e.put("mode", if (s.mode == .buy) "buy" else "sell");
		e.put("goodsItem", s.goodsItem);
		e.put("goodsAmount", s.goodsAmount);
		e.put("priceItem", s.priceItem);
		e.put("priceAmount", s.priceAmount);
		arr.array.append(e);
	}
	zon.put("shops", arr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe shops: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}

var refreshDone: bool = true;
var lastRefresh: std.Io.Timestamp = .{.nanoseconds = 0};

/// Throttled driver for refreshSigns, called from the world tick. Attempts at
/// most once a minute and stops once every sign is rewritten.
pub fn refreshTick() void {
	if (refreshDone) return;
	const now = main.timestamp();
	if (lastRefresh.durationTo(now).toSeconds() < 60) return;
	lastRefresh = now;
	_ = refreshSigns();
}

/// Rewrites every registered shop sign with the current (sign-aware) colors.
/// Signs in unloaded chunks are skipped and retried on a later tick; returns
/// the number still pending.
pub fn refreshSigns() usize {
	ensure();
	var pending: usize = 0;
	for (shops.items) |*s| {
		if (!refreshOne(s)) pending += 1;
	}
	if (pending == 0 and !refreshDone) {
		refreshDone = true;
		std.log.info("[ashframe] shop sign colors refreshed.", .{});
	}
	return pending;
}

fn isHex6(s: []const u8) bool {
	if (s.len < 6) return false;
	for (s[0..6]) |c| {
		if (!std.ascii.isHex(c)) return false;
	}
	return true;
}

/// Owner display name from existing sign text: the last line, minus `#rrggbb`
/// color codes. Shop signs have always stored the (code-stripped) owner name
/// there, so migration can re-render without the owner online. Null when
/// there is no usable name (empty, or longer than `buf` — in which case the
/// sign is left alone rather than truncated).
fn lastTextLine(text: []const u8, buf: []u8) ?[]const u8 {
	var len: usize = 0;
	var i: usize = 0;
	while (i < text.len) {
		if (text[i] == '#' and isHex6(text[i + 1 ..])) {
			i += 7;
			continue;
		}
		if (len >= buf.len) return null;
		buf[len] = text[i];
		len += 1;
		i += 1;
	}
	const stripped = buf[0..len];
	const line = if (std.mem.lastIndexOfScalar(u8, stripped, '\n')) |nl| stripped[nl + 1 ..] else stripped;
	const name = std.mem.trim(u8, line, " \r\t");
	if (name.len == 0) return null;
	return name;
}

/// Rewrites one shop sign with the sign-aware colors. True = done (or
/// nothing to do); false = retry later.
fn refreshOne(s: *Shop) bool {
	const world = main.server.world orelse return false;
	const signPos: Vec3i = .{s.sign[0], s.sign[1], s.sign[2]};
	const block = world.getBlock(signPos[0], signPos[1], signPos[2]) orelse return false;
	// Sign gone (broken/moved): onBroken prunes the entry; don't retry forever.
	if (!isSignBlock(block)) return true;
	const simChunk = world.getSimulationChunkAndIncreaseRefCount(signPos[0], signPos[1], signPos[2]) orelse return false;
	defer simChunk.decreaseRefCount();
	const ch = simChunk.chunk.load(.monotonic) orelse return false;
	const current = signType.getText(signPos, &ch.super) orelse return false;
	// Owner-customized text is left alone; only generated signs are recolored.
	if (!std.mem.startsWith(u8, current, "#ffcc00[Shop]") and !std.mem.startsWith(u8, current, "#000000[Shop]")) return true;
	var nameBuf: [64]u8 = undefined;
	const ownerName = lastTextLine(current, &nameBuf) orelse return true;
	const goods: BaseItemIndex = @enumFromInt(s.goodsItem);
	const price: BaseItemIndex = @enumFromInt(s.priceItem);
	var buf: [256]u8 = undefined;
	const newText = formatSignText(s.mode, s.goodsAmount, shortId(goods), s.priceAmount, shortId(price), ownerName, signIsLight(block), &buf) catch return true;
	if (std.mem.eql(u8, newText, current)) return true;
	if (!writeSign(signPos, newText)) return false;
	main.network.protocols.blockEntityUpdate.sendServerDataUpdateToClients(signPos);
	return true;
}

test "shop sign schemes" {
	var buf: [256]u8 = undefined;
	const dark = try formatSignText(.sell, 2, "amber", 5, "ruby", "Bob", false, &buf);
	try std.testing.expect(std.mem.startsWith(u8, dark, "#ffcc00[Shop] Sell#ffffff"));
	try std.testing.expect(std.mem.indexOf(u8, dark, "\n-5x ruby\n+2x amber\nBob") != null);
	var buf2: [256]u8 = undefined;
	const light = try formatSignText(.buy, 2, "amber", 5, "ruby", "Bob", true, &buf2);
	try std.testing.expect(std.mem.startsWith(u8, light, "#000000[Shop] Buy#000000"));
	try std.testing.expect(std.mem.indexOf(u8, light, "\n+5x ruby\n-2x amber\nBob") != null);
	try std.testing.expect(schemeForId("cubyz:sign/birch"));
	try std.testing.expect(schemeForId("cubyz:sign/baobab"));
	try std.testing.expect(schemeForId("cubyz:sign/palm"));
	try std.testing.expect(!schemeForId("cubyz:sign/oak"));
	try std.testing.expect(!schemeForId("cubyz:sign/mahogany"));
	try std.testing.expect(!schemeForId("cubyz:sign/cirrus"));
	try std.testing.expect(!schemeForId("ashframe:sign/custom"));
	var nb: [64]u8 = undefined;
	const owner = lastTextLine("#ffcc00[Shop] Sell#ffffff\n-5x ruby\n+2x amber\nBob", &nb);
	try std.testing.expect(owner != null and std.mem.eql(u8, owner.?, "Bob"));
	const empty = lastTextLine("#ffcc00[Shop] Sell#ffffff\n", &nb);
	try std.testing.expect(empty == null);
}

test "shop sign attachment is side-mount only" {
	const signPos: Vec3i = .{100, 200, 300}; // (x, horizontal, vertical)
	// Side mounts resolve to the block the sign faces.
	try std.testing.expectEqual(Vec3i{99, 200, 300}, signAttachmentPos(signPos, .{.typ = 0, .data = 16}).?);
	try std.testing.expectEqual(Vec3i{100, 199, 300}, signAttachmentPos(signPos, .{.typ = 0, .data = 17}).?);
	try std.testing.expectEqual(Vec3i{101, 200, 300}, signAttachmentPos(signPos, .{.typ = 0, .data = 18}).?);
	try std.testing.expectEqual(Vec3i{100, 201, 300}, signAttachmentPos(signPos, .{.typ = 0, .data = 19}).?);
	// Floor/ceiling mounts and garbage are rejected.
	try std.testing.expect(signAttachmentPos(signPos, .{.typ = 0, .data = 0}) == null);
	try std.testing.expect(signAttachmentPos(signPos, .{.typ = 0, .data = 8}) == null);
	try std.testing.expect(signAttachmentPos(signPos, .{.typ = 0, .data = 20}) == null);
	// signMountedOn: attached exactly on `attachedPos`, not a neighbour beyond it.
	try std.testing.expect(signMountedOn(signPos, .{.typ = 0, .data = 16}, .{99, 200, 300}));
	try std.testing.expect(!signMountedOn(signPos, .{.typ = 0, .data = 16}, .{100, 200, 300}));
	try std.testing.expect(!signMountedOn(signPos, .{.typ = 0, .data = 16}, .{98, 200, 300}));
}

test "shop trade summary direction" {
	// Sentence always reads "bought <received> for <paid>", independent of mode.
	// Guards the bug where buy-shops reported goods/price inverted.
	var buf: [256]u8 = undefined;
	const got = try tradeSummaryParts("fabrovio", 40, "limestone", 2, "copper_ingot", &buf);
	try std.testing.expectEqualStrings("fabrovio bought 40 limestone for 2 copper_ingot", got);
}

// --- ASHFRAME CUSTOM (Sign shops) ---
