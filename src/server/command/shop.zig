const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const User = main.server.User;
const shops = main.server.shops;

pub const description = "Turn a chest + sign into a shop.";
pub const usage =
	\\/shop sell <amount> <item> for <amount> <item>
	\\/shop buy <amount> <item> for <amount> <item>
;

pub const Args = union(enum) {
	@"/shop <action> <amount> <item> for <priceAmount> <priceItem>": struct {
		action: enum { sell, buy },
		amount: u16,
		item: []const u8,
		@"for": ?enum { @"for" },
		priceAmount: u16,
		priceItem: []const u8,
	},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	switch (args) {
		.@"/shop <action> <amount> <item> for <priceAmount> <priceItem>" => |p| {
			const mode: shops.Mode = if (p.action == .sell) .sell else .buy;
			setup(source.user, source, mode, p.amount, p.item, p.priceAmount, p.priceItem);
		},
	}
}

/// Diagnostic for /shop refusals: logs chest/sign/mount facts so stacked
/// reports are actionable without reproducing in-game.
fn logRefusal(user: *User, target: main.vec.Vec3i, kind: shops.RefusalKind) void {
	std.log.warn("[shops] /shop refused for {s}: kind={s} target={d},{d},{d}", .{ user.name, @tagName(kind), target[0], target[1], target[2] });
}

/// Aim resolution with a vertical fallback: when aiming from below/above,
/// the ray can land one level off the intended pair (chest instead of its
/// sign, or vice versa). A failed direct resolution retries the cells one
/// above/below — accepted only when exactly one alternate resolves, so we
/// never guess between two stacked shops.
fn resolveAiming(target: main.vec.Vec3i, targetBlock: main.blocks.Block) shops.ResolveResult {
	switch (shops.resolveShopPair(target, targetBlock)) {
		.ok => |p| return .{ .ok = p },
		.refuse => {},
	}
	const world = main.server.world orelse return shops.resolveShopPair(target, targetBlock);
	var found: ?shops.ShopPair = null;
	var hits: u32 = 0;
	for ([_]i32{ 1, -1 }) |dv| {
		const alt = main.vec.Vec3i{ target[0], target[1], target[2] + dv };
		const block = world.getBlock(alt[0], alt[1], alt[2]) orelse continue;
		switch (shops.resolveShopPair(alt, block)) {
			.ok => |p| {
				found = p;
				hits += 1;
			},
			.refuse => {},
		}
	}
	if (hits == 1) return .{ .ok = found.? };
	return shops.resolveShopPair(target, targetBlock);
}

fn setup(user: *User, source: Source, mode: shops.Mode, amount: u16, goodsStr: []const u8, priceAmount: u16, priceStr: []const u8) void {
	const goods = shops.resolveItem(goodsStr) orelse {
		source.sendMessage("#e6312cUnknown item \"{s}\".", .{goodsStr});
		return;
	};
	const price = shops.resolveItem(priceStr) orelse {
		source.sendMessage("#e6312cUnknown item \"{s}\".", .{priceStr});
		return;
	};

	const target = shops.lookAtBlock(user, 6.0) orelse {
		source.sendMessage("#e6312cLook at a chest (or its sign) to set up a shop.", .{});
		return;
	};
	const world = main.server.world orelse return;
	const targetBlock = world.getBlock(target[0], target[1], target[2]) orelse return;

	// Resolve the (chest, sign) pair robustly (stacked chests included,
	// including aiming from below/above); refusals say exactly what's
	// wrong, with positions.
	const pair = switch (resolveAiming(target, targetBlock)) {
		.ok => |p| p,
		.refuse => |kind| {
			switch (kind) {
				.notChestOrSign => source.sendMessage("#e6312cLook at a chest (or its sign) to set up a shop.", .{}),
				.chestWithoutSign => {
					const diag = shops.diagnoseChest(target);
					if (diag.signPos) |sp| {
						if (diag.mountData) |md| {
							if (diag.mountedPos) |mp| {
								if (diag.mountedIsChest) {
									source.sendMessage("#e6312cThat sign belongs to the chest at {d},{d},{d} — look at that chest instead.", .{ mp[0], mp[1], mp[2] });
								} else {
									source.sendMessage("#e6312cThat sign is mounted on another block at {d},{d},{d}, not this chest.", .{ mp[0], mp[1], mp[2] });
								}
							} else {
								_ = md;
								source.sendMessage("#e6312cThat sign (at {d},{d},{d}) is floor/ceiling-mounted — shop signs must sit on the chest's side.", .{ sp[0], sp[1], sp[2] });
							}
						} else {
							source.sendMessage("#e6312cPlace a sign directly on the side of the chest first.", .{});
						}
					} else {
						source.sendMessage("#e6312cPlace a sign directly on the side of the chest first.", .{});
					}
				},
				.signNotSideMounted => source.sendMessage("#e6312cShop signs must be mounted on the side of a chest (not floor/ceiling).", .{}),
				.signMountedElsewhere => source.sendMessage("#e6312cThat sign is mounted on another block — look at the chest it faces, or re-mount it on this one.", .{}),
			}
			logRefusal(user, target, kind);
			return;
		},
	};
	const chest = pair.chest;
	const sign = pair.sign;

	if (!main.server.claims.canBuild(user, sign[0], sign[2], sign[1])) {
		source.sendMessage("#e6312cYou can't set up a shop here.", .{});
		return;
	}

	// --- ASHFRAME CUSTOM (Anticheat: shop ownership) ---
	// Refuse to take over a chest that already holds someone else's shop.
	if (shops.chestOwnedByOther(user, chest)) {
		main.server.anticheat.note(user, .protocol, "tried to rebind an existing shop chest");
		source.sendMessage("#e6312cThat chest already belongs to someone else's shop.", .{});
		return;
	}
	// --- ASHFRAME CUSTOM (Anticheat) ---

	var nameBuf: [shops.maxNameLen]u8 = undefined;
	const ownerName = shops.signName(user.name, &nameBuf);
	if (!shops.writeShopSign(sign, mode, amount, goods, priceAmount, price, ownerName)) {
		source.sendMessage("#e6312cCould not write the sign.", .{});
		return;
	}
	_ = shops.create(user, chest, sign, mode, goods, amount, price, priceAmount);
	const verb = if (mode == .sell) "selling" else "buying";
	source.sendMessage("#00ff00Shop created: #cfcfcf{s} #e6312c{d} {s}#cfcfcf for #e6312c{d} {s}#cfcfcf.", .{verb, amount, goods.name(), priceAmount, price.name()});
}
