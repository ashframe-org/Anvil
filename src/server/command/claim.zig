const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const claims = main.server.claims;
const ashutil = @import("ashutil.zig");

pub const description = "Claim land around you to protect your builds.";
pub const usage =
	\\/claim
	\\/claim list
	\\/claim info
	\\/claim members
	\\/claim trust <player>
	\\/claim untrust <player>
	\\/claim accept <player>
	\\/claim deny <player>
	\\/claim abandon
	\\/claim remove
	\\/claim show
;

pub const Args = union(enum) {
	@"/claim <action>": struct { action: enum { list, info, members, abandon, remove, show } },
	@"/claim <action> <target>": struct { action: enum { trust, untrust, accept, deny }, target: []const u8 },
	@"/claim": struct {},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	switch (args) {
		.@"/claim" => {
			// Alliance members keep full personal claim rights (their unused
			// slots pool to the leader dynamically); joining no longer freezes
			// them out of claiming.
			// Charge BEFORE creating, and refund on any failure. This avoids
			// appending a claim and then freeing it again on a failed payment
			// (a fragile path that could double-free).
			const cost = claims.nextCost(user.playerIndex);
			if (cost.amount > 0 and !ashutil.chargeItem(user, source, cost.item, ashutil.itemDisplayName(cost.item), cost.amount)) return;
			const maxClaims = main.server.alliances.maxClaimsFor(user.playerIndex);

			switch (claims.create(user)) {
				.ok => {
					claims.bumpUnlocked(user.playerIndex);
					const owned = claims.countOwned(user.playerIndex);
					if (cost.amount > 0) {
						source.sendMessage("#00ff00Land claimed (16x16x32) #cfcfcf(-{d} {s})#00ff00. #8a8a8aYou now have {d}/{d}.", .{ cost.amount, ashutil.itemDisplayName(cost.item), owned, maxClaims });
					} else {
						source.sendMessage("#00ff00Land claimed (16x16x32) #8a8a8a(free). You now have {d}/{d}.", .{ owned, maxClaims });
					}
					const px = main.server.anticheat.toI32(user.player().pos[0]) orelse return;
					const pz = main.server.anticheat.toI32(user.player().pos[1]) orelse return;
					if (claims.atColumn(px, pz)) |idx| claims.drawBorder(user, idx);
				},
				.invalidPosition => {
					if (cost.amount > 0) ashutil.refundItem(user, cost.item, cost.amount);
					source.sendMessage("#e6312cYour position is invalid; try again.", .{});
				},
				.tooMany => {
					if (cost.amount > 0) ashutil.refundItem(user, cost.item, cost.amount);
					source.sendMessage("#e6312cYou already have the maximum of {d} claims.", .{maxClaims});
				},
				.alreadyOwned => {
					if (cost.amount > 0) ashutil.refundItem(user, cost.item, cost.amount);
					source.sendMessage("#e6312cYou're already standing inside your own claim.", .{});
				},
				.spawnProtected => {
					if (cost.amount > 0) ashutil.refundItem(user, cost.item, cost.amount);
					source.sendMessage("#e6312cThis is the spawn area — nobody can claim here, but building and shops work.", .{});
				},
				.blocked => |blocker| {
					if (cost.amount > 0) ashutil.refundItem(user, cost.item, cost.amount);
					// Show *where* the blocking claim is (red markers); the message
					// names who it belongs to.
					claims.drawBlocked(user, blocker);
					const c = &claims.allClaims()[blocker];
					if (c.owner == user.playerIndex) {
						source.sendMessage("#e6312cYour own claim is too close — leave an {d}-block gap.", .{claims.barrierBlocks});
					} else {
						source.sendMessage("#e6312c{s} #e6312chas a claim within {d} blocks. #8a8a8a(They must approve you: they run /claim accept {s}.)", .{ c.ownerName, claims.barrierBlocks, user.name });
						if (main.server.getUserByIndex(c.owner)) |owner| {
							// One live request per requester: repeat attempts
							// while blocked must not spam the owner.
							if (claims.notifyRequestOnce(user.playerIndex, c.owner)) {
								owner.sendMessage("#e6e6e6{s} #cfcfcfwants to claim land near yours. Type #e6312c/claim accept {s}#cfcfcf to allow (2 min) or #e6312c/claim deny {s}#cfcfcf.", .{ user.name, user.name, user.name });
							}
						}
					}
				},
			}
		},
		.@"/claim <action>" => |params| switch (params.action) {
			.list => {
				// Compact summary: one line per owner with their claim count,
				// instead of listing every claim's coordinates.
				const Tally = struct { owner: usize, name: []const u8, count: u32 };
				var seen: main.ListManaged(Tally) = .init(main.stackAllocator);
				defer seen.deinit();
				for (claims.allClaims()) |c| {
					var found = false;
					for (seen.items) |*s| {
						if (s.owner == c.owner) {
							s.count += 1;
							found = true;
							break;
						}
					}
					if (!found) seen.append(.{ .owner = c.owner, .name = c.ownerName, .count = 1 });
				}
				if (seen.items.len == 0) {
					source.sendMessage("#cfcfcfNo land is claimed yet. #8a8a8a(Just /claim where you stand.)", .{});
					return;
				}
				source.sendMessage("#f2f2f2--- Claims ({d} owner(s)) ---", .{seen.items.len});
				for (seen.items) |s| {
					source.sendMessage("#cfcfcf{s}#e6312c {d} claim(s)#cfcfcf.", .{ s.name, s.count });
				}
			},
			.info => {
				const px: i32 = @as(i32, @intFromFloat(user.player().pos[0]));
				const py: i32 = @as(i32, @intFromFloat(user.player().pos[2]));
				const pz: i32 = @as(i32, @intFromFloat(user.player().pos[1]));
				if (claims.at(px, py, pz)) |i| {
					const c = &claims.allClaims()[i];
					const access = if (c.owner == user.playerIndex) "yours" else if (claims.isMember(c, user)) "trusted here" else "not trusted";
					source.sendMessage("#cfcfcfThis land is claimed by #e6312c{s}#cfcfcf. #8a8a8a(You are {s}.)", .{ c.ownerName, access });
					claims.drawBorder(user, i);
				} else {
					source.sendMessage("#cfcfcfThis land is unclaimed.", .{});
				}
			},
			.members => {
				const px: i32 = @as(i32, @intFromFloat(user.player().pos[0]));
				const py: i32 = @as(i32, @intFromFloat(user.player().pos[2]));
				const pz: i32 = @as(i32, @intFromFloat(user.player().pos[1]));
				const i = claims.at(px, py, pz) orelse {
					source.sendMessage("#e6312cYou're not standing in claimed land.", .{});
					return;
				};
				const c = &claims.allClaims()[i];
				if (!claims.ownsClaim(c, user)) {
					source.sendMessage("#e6312cOnly the claim owner can see the member list.", .{});
					return;
				}
				if (c.memberCount == 0) {
					source.sendMessage("#cfcfcfNo one is trusted here yet. #8a8a8a(Try /claim trust <player>.)", .{});
					return;
				}
				source.sendMessage("#f2f2f2--- Trusted here ({d}) ---", .{c.memberCount});
				for (c.members[0..c.memberCount]) |idx| {
					if (main.server.getUserByIndex(idx)) |u| {
						source.sendMessage("#cfcfcf- {s}", .{u.name});
					} else {
						source.sendMessage("#cfcfcf- @{d} #8a8a8a(offline)", .{idx});
					}
				}
			},
			.show => {
				const prof = user.player();
				prof.showClaims = !prof.showClaims;
				if (prof.showClaims) {
					prof.lastClaimDraw = 0;
					source.sendMessage("#00ff00Claim borders on.", .{});
				} else {
					source.sendMessage("#cfcfcfClaim borders off.", .{});
				}
			},
			.abandon => {
				const px: i32 = @as(i32, @intFromFloat(user.player().pos[0]));
				const py: i32 = @as(i32, @intFromFloat(user.player().pos[2]));
				const pz: i32 = @as(i32, @intFromFloat(user.player().pos[1]));
				const i = claims.at(px, py, pz) orelse {
					source.sendMessage("#e6312cYou're not standing in claimed land.", .{});
					return;
				};
				if (!claims.ownsClaim(&claims.allClaims()[i], user)) {
					source.sendMessage("#e6312cOnly the claim owner can abandon it.", .{});
					return;
				}
				claims.removeAt(i);
				source.sendMessage("#cfcfcfClaim abandoned. The land is unprotected now.", .{});
			},
			.remove => {
				if (!source.hasPermission("/ashframe/admin/claim")) {
					source.sendMessage("#e6312cYou do not have permission to remove other people's claims.", .{});
					return;
				}
				const px: i32 = @as(i32, @intFromFloat(user.player().pos[0]));
				const py: i32 = @as(i32, @intFromFloat(user.player().pos[2]));
				const pz: i32 = @as(i32, @intFromFloat(user.player().pos[1]));
				const i = claims.at(px, py, pz) orelse {
					source.sendMessage("#e6312cYou're not standing in claimed land.", .{});
					return;
				};
				claims.removeAt(i);
				source.sendMessage("#cfcfcfClaim removed.", .{});
			},
		},
		.@"/claim <action> <target>" => |params| {
			const target = ashutil.findTargetByNameOrIndex(params.target) orelse {
				source.sendMessage("#e6312cPlayer '#cfcfcf{s}#e6312c' not found or offline.", .{params.target});
				return;
			};
			switch (params.action) {
				.accept => {
					if (target.playerIndex == user.playerIndex) {
						source.sendMessage("#e6312cYou can't approve yourself.", .{});
						return;
					}
					claims.approve(user, target);
				},
				.deny => {
					claims.revokeApproval(user, target);
					source.sendMessage("#cfcfcfDenied #e6312c{s}#cfcfcf's claim request.", .{target.name});
					target.sendMessage("#e6312c{s} #cfcfcfdenied your claim request.", .{user.name});
				},
				.trust, .untrust => {
					const px: i32 = @as(i32, @intFromFloat(user.player().pos[0]));
					const py: i32 = @as(i32, @intFromFloat(user.player().pos[2]));
					const pz: i32 = @as(i32, @intFromFloat(user.player().pos[1]));
					const i = claims.at(px, py, pz) orelse {
						source.sendMessage("#e6312cYou're not standing in claimed land.", .{});
						return;
					};
					if (!claims.ownsClaim(&claims.allClaims()[i], user)) {
						source.sendMessage("#e6312cOnly the claim owner can manage who it is shared with.", .{});
						return;
					}
					if (target.playerIndex == user.playerIndex) {
						source.sendMessage("#e6312cYou can't change your own access.", .{});
						return;
					}
					if (params.action == .trust) {
						if (claims.trust(i, target)) {
							source.sendMessage("#00ff00{s} #cfcfcfcan now build here.", .{target.name});
						} else {
							source.sendMessage("#e6312cCouldn't add them. #8a8a8a(Already trusted, or the list is full.)", .{});
						}
					} else {
						if (claims.untrust(i, target)) {
							source.sendMessage("#cfcfcf{s} #e6312ccan no longer build here.", .{target.name});
						} else {
							source.sendMessage("#e6312cThey weren't on the trusted list.", .{});
						}
					}
				},
			}
		},
	}
}
