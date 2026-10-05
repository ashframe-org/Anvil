const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const discordlink = main.server.discordlink;

pub const description = "Move a lost account's progress to this account, using a code from the Discord bot.";
pub const usage = "/recover <code>";

pub const Args = union(enum) {
	@"/recover <code>": struct { code: []const u8 },
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	switch (discordlink.redeemRecovery(source.user, args.@"/recover <code>".code)) {
		.ok => |name| source.sendMessage("#00ff00Recovery of {s} accepted.#cfcfcf Disconnect and rejoin now to finish.\n#8a8a8aThis account's own progress will be replaced, and the old account's key will be banned.", .{name}),
		.badCode => source.sendMessage("#e6312cThat recovery code is wrong or expired. #cfcfcfRun #00ff00/recover#cfcfcf in our Discord for a new one.", .{}),
		.sameAccount => source.sendMessage("#e6312cThis is already the linked account. #cfcfcfRun /recover on your #00ff00new#cfcfcf account.", .{}),
		.newAccountLinked => source.sendMessage("#e6312cThis account is linked to a different Discord account, so it can't take over another one.", .{}),
		.noKey => source.sendMessage("#e6312cThis account can't be used for recovery (no account key).", .{}),
	}
}
