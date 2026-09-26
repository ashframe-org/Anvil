const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const report = main.server.report;

pub const description = "Show the server report (staff).";
pub const usage =
	\\/report
	\\/report all
	\\/report yes
	\\/report no
	\\/report clear
;

pub const Args = union(enum) {
	@"/report <action>": struct { action: enum { all, yes, no, clear } },
	@"/report": struct {},
};

pub fn execute(args: Args, source: Source) void {
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const user = source.user;
	if (!main.entity.components.@"cubyz:permissions".server.hasPermission(user.id, report.permissionPath)) {
		source.sendMessage("#e6312cYou don't have permission to view the server report.", .{});
		return;
	}
	switch (args) {
		.@"/report" => report.sendSummary(user),
		.@"/report <action>" => |params| switch (params.action) {
			.all => report.sendAll(user),
			.yes => {
				report.sendSummary(user);
				report.acknowledge(user);
			},
			.no => {
				report.acknowledge(user);
				source.sendMessage("#8a8a8aServer report dismissed.", .{});
			},
			.clear => report.clear(user),
		},
	}
}
