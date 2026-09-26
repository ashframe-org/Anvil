const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const chatfilter = main.server.chatfilter;

pub const description = "Permanently ban a player by name, @playerIndex, or public key (admin).";
pub const usage = "/ban <name|@playerIndex|publicKey> [reason]";

pub const Args = union(enum) {
	@"/ban <target> [reason]": struct { target: []const u8, reason: ?command.RestOfLine },
};

pub fn execute(args: Args, source: Source) void {
	if (!source.hasPermission("/ashframe/admin/ban")) {
		source.sendMessage("#e6312cYou do not have permission to ban players.", .{});
		return;
	}
	const target = args.@"/ban <target> [reason]".target;
	const reason: ?[]const u8 = if (args.@"/ban <target> [reason]".reason) |r| r.text else null;

	// Resolve the target: @playerIndex (online), a public key (contains ':'),
	// or a bare name.
	var name: []const u8 = target;
	var key: ?[]const u8 = null;
	var online: ?*main.server.User = null;

	if (std.ascii.startsWithIgnoreCase(target, "@")) {
		const idx = std.fmt.parseInt(usize, target[1..], 10) catch {
			source.sendMessage("#e6312cInvalid player index '#cfcfcf{s}#e6312c'.", .{target});
			return;
		};
		online = main.server.getUserByIndex(idx) orelse {
			source.sendMessage("#e6312cPlayer with index {d} not found or not online.", .{idx});
			return;
		};
		name = online.?.name;
		key = online.?.newKeyString;
	} else if (std.mem.indexOfScalar(u8, target, ':') != null) {
		// Looks like a public key "<keyType>:<base64>". Validate it so a typo
		// doesn't silently create an unverifiable ban entry.
		const colon = std.mem.indexOfScalar(u8, target, ':').?;
		const keyType = std.meta.stringToEnum(main.network.authentication.KeyTypeEnum, target[0..colon]) orelse {
			source.sendMessage("#e6312cUnknown key type in '#cfcfcf{s}#e6312c'.", .{target});
			return;
		};
		_ = main.network.authentication.PublicKey.initFromBase64(target[colon + 1 ..], keyType) catch {
			source.sendMessage("#e6312cInvalid public key '#cfcfcf{s}#e6312c'.", .{target});
			return;
		};
		name = "";
		key = target;
	}

	if (!chatfilter.banManual(name, key, reason)) {
		source.sendMessage("#e6312cNothing to ban.", .{});
		return;
	}

	const shown = if (name.len != 0) name else target;
	if (reason) |r| {
		source.sendMessage("#00ff00Banned #cfcfcf{s}#00ff00. #8a8a8aReason: {s}", .{ shown, r });
	} else {
		source.sendMessage("#00ff00Banned #cfcfcf{s}#00ff00.", .{shown});
	}

	// If they're online, disconnect them (run on the server thread, so safe).
	if (online) |u| {
		main.server.sendMessage("{s}§#e6312c was banned.", .{u.name});
		main.server.disconnect(u);
	}
}
