const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Progress) ---
// Deferred item refunds. Refunding inside a block-change command would run a
// nested inventory command while the outer one is still executing, which
// corrupts the command lists (double free). Queue here and flush in the tick.
// (The community goal, quests and the luck system were retired; see archive.)

const Refund = struct {
	playerIndex: usize,
	item: main.items.BaseItemIndex,
	amount: u16,
};
var refunds: main.ListManaged(Refund) = undefined;
var refundReady: bool = false;

pub fn queueRefund(user: *User, itemId: []const u8, amount: u16) void {
	if (!refundReady) {
		refunds = main.ListManaged(Refund).init(main.globalAllocator);
		refundReady = true;
	}
	const base = main.items.BaseItemIndex.fromId(itemId) orelse return;
	refunds.append(.{ .playerIndex = user.playerIndex, .item = base, .amount = amount });
}

pub fn processRefunds() void {
	if (!refundReady) return;
	for (refunds.items) |r| {
		const user = main.server.getUserByIndex(r.playerIndex) orelse continue;
		var stack = main.items.ItemStack{ .item = .{.baseItem = r.item}, .amount = r.amount };
		main.items.Inventory.server.tryCollectingToPlayerInventory(user, &stack);
	}
	refunds.clearRetainingCapacity();
}
// --- ASHFRAME CUSTOM (Progress) ---
