const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const discordlink = main.server.discordlink;

pub const description = "Link your account to Discord (lets you recover it if you lose access).";
pub const usage = "/link";

pub const Args = union(enum) {
	@"/link": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	switch (discordlink.startLink(source.user)) {
		.code => |code| source.sendMessage("#cfcfcfYour link code: #00ff00{s}#cfcfcf (valid 10 min).\nIn our Discord, run the slash command #00ff00/verify code:{s}#cfcfcf (only you can see it).\n#8a8a8aNever post the code as a normal message.", .{&code, &code}),
		.alreadyLinked => |name| source.sendMessage("#cfcfcfThis account is already linked to Discord #00ff00{s}#cfcfcf.", .{name}),
		.noKey => source.sendMessage("#e6312cThis account can't be linked (no account key).", .{}),
	}
}
