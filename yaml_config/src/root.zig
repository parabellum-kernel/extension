const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("parabellum_yaml");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

pub const YamlAst = yaml.Node;
pub const EnvInterpolator = yaml.EnvInterpolator;

const c_stdio = struct {
    const FILE = opaque {};
    const SEEK_SET: c_int = 0;
    const SEEK_END: c_int = 2;
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: *FILE) c_long;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
};

fn readFileAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    const path_z = try alloc.allocSentinel(u8, path.len, 0);
    @memcpy(path_z, path);
    defer alloc.free(path_z);

    const fp = c_stdio.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c_stdio.fclose(fp);

    _ = c_stdio.fseek(fp, 0, c_stdio.SEEK_END);
    const sz_long = c_stdio.ftell(fp);
    if (sz_long < 0) return error.FileReadFailed;
    const sz: usize = @intCast(sz_long);
    _ = c_stdio.fseek(fp, 0, c_stdio.SEEK_SET);

    const buf = try alloc.alloc(u8, sz);
    errdefer alloc.free(buf);
    if (sz > 0) {
        const read_n = c_stdio.fread(buf.ptr, 1, sz, fp);
        if (read_n != sz) return error.FileReadFailed;
    }
    return buf;
}

fn interp(alloc: Allocator, env: *EnvInterpolator, raw: []const u8) ![]const u8 {
    return env.interpolate(alloc, raw);
}

fn parseByteSize(raw: []const u8) ?usize {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    const suffixes = [_]struct { suf: []const u8, mult: usize }{
        .{ .suf = "GiB", .mult = 1024 * 1024 * 1024 },
        .{ .suf = "MiB", .mult = 1024 * 1024 },
        .{ .suf = "KiB", .mult = 1024 },
        .{ .suf = "GB", .mult = 1000 * 1000 * 1000 },
        .{ .suf = "MB", .mult = 1000 * 1000 },
        .{ .suf = "KB", .mult = 1000 },
        .{ .suf = "B", .mult = 1 },
    };
    for (suffixes) |entry| {
        if (std.mem.endsWith(u8, s, entry.suf)) {
            const num_str = std.mem.trim(u8, s[0 .. s.len - entry.suf.len], " \t");
            const n = std.fmt.parseInt(usize, num_str, 10) catch return null;
            return n * entry.mult;
        }
    }
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn parseBool(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "yes");
}

fn parseSchedulerCode(s: []const u8) u32 {
    return if (std.mem.eql(u8, s, "dag")) 1 else 0;
}

fn parseRoutingCode(s: []const u8) u32 {
    if (std.mem.eql(u8, s, "type_driven")) return 1;
    if (std.mem.eql(u8, s, "hybrid")) return 2;
    return 0;
}

fn parseRoleCode(s: []const u8) u32 {
    if (std.mem.eql(u8, s, "source")) return 0;
    if (std.mem.eql(u8, s, "sink")) return 1;
    return 2;
}

fn parseSliceList(alloc: Allocator, env: *EnvInterpolator, node: YamlAst) ![]const abi.Slice_ABI {
    var list: std.ArrayListUnmanaged(abi.Slice_ABI) = .empty;
    if (node.asSeq()) |items| {
        for (items) |it| {
            if (it.asScalar()) |s| {
                try list.append(alloc, abi.Slice_ABI.from(try interp(alloc, env, s)));
            }
        }
    } else if (node.asScalar()) |s| {
        try list.append(alloc, abi.Slice_ABI.from(try interp(alloc, env, s)));
    }
    return list.toOwnedSlice(alloc);
}

fn parseConfigParams(alloc: Allocator, env: *EnvInterpolator, node: YamlAst) ![]const abi.ConfigParam_ABI {
    var list: std.ArrayListUnmanaged(abi.ConfigParam_ABI) = .empty;
    if (node.asMap()) |entries| {
        for (entries) |e| {
            if (e.value.asScalar()) |v| {
                try list.append(alloc, .{
                    .key = abi.Slice_ABI.from(e.key),
                    .value = abi.Slice_ABI.from(try interp(alloc, env, v)),
                });
            }
        }
    }
    return list.toOwnedSlice(alloc);
}

fn checkAbi(rc: abi.HostError_ABI) !void {
    if (rc != .ok) return error.BuilderFailed;
}

fn emitStep(
    alloc: Allocator,
    env: *EnvInterpolator,
    node: YamlAst,
    builder: *abi.extension.PipelineBuilderHandle_ABI,
    vtable: *const abi.extension.PipelineBuilderVTable_ABI,
) !void {
    if (node.get("router")) |router_node| {
        const rid = router_node.asScalar() orelse (if (node.get("id")) |id_n| id_n.asScalar() orelse "router" else "router");
        var cases: std.ArrayListUnmanaged(abi.extension.RouterCase_ABI) = .empty;
        if (node.get("cases")) |cases_n| {
            if (cases_n.asSeq()) |seq| {
                for (seq) |c_node| {
                    const when_s = if (c_node.get("when")) |w| w.asScalar() orelse "" else "";
                    const goto_s = if (c_node.get("goto")) |g| g.asScalar() orelse "" else "";
                    try cases.append(alloc, .{
                        .when_predicate = abi.Slice_ABI.from(try interp(alloc, env, when_s)),
                        .goto_pipeline = abi.Slice_ABI.from(try interp(alloc, env, goto_s)),
                    });
                }
            }
        }
        const def_pipe: abi.Slice_ABI = if (node.get("default")) |d|
            (if (d.asScalar()) |s| abi.Slice_ABI.from(try interp(alloc, env, s)) else abi.Slice_ABI.empty)
        else
            abi.Slice_ABI.empty;

        try checkAbi(vtable.add_router_step(
            builder,
            abi.Slice_ABI.from(try interp(alloc, env, rid)),
            if (cases.items.len > 0) cases.items.ptr else (&[_]abi.extension.RouterCase_ABI{}).ptr,
            cases.items.len,
            def_pipe,
        ));
        return;
    }

    const id_s = if (node.get("id")) |n| (n.asScalar() orelse "") else "";
    var mod_s: []const u8 = "";
    var task_s: []const u8 = "";
    if (node.get("uses")) |uses_n| {
        if (uses_n.asScalar()) |raw_u| {
            const u = try interp(alloc, env, raw_u);
            if (std.mem.indexOfScalar(u8, u, '/')) |slash| {
                mod_s = u[0..slash];
                task_s = u[slash + 1 ..];
            } else {
                task_s = u;
            }
        }
    }
    if (node.get("module")) |m_n| {
        if (m_n.asScalar()) |ms| mod_s = try interp(alloc, env, ms);
    }
    if (node.get("task")) |t_n| {
        if (t_n.asScalar()) |ts| task_s = try interp(alloc, env, ts);
    }

    var inputs: std.ArrayListUnmanaged(abi.extension.InputBinding_ABI) = .empty;
    if (node.get("from")) |from_n| {
        if (from_n.asScalar()) |fs| {
            try inputs.append(alloc, .{
                .param_name = abi.Slice_ABI.from("input"),
                .stream_ref = abi.Slice_ABI.from(try interp(alloc, env, fs)),
            });
        } else if (from_n.asMap()) |f_entries| {
            for (f_entries) |fe| {
                if (fe.value.asScalar()) |vs| {
                    try inputs.append(alloc, .{
                        .param_name = abi.Slice_ABI.from(fe.key),
                        .stream_ref = abi.Slice_ABI.from(try interp(alloc, env, vs)),
                    });
                }
            }
        }
    }
    if (node.get("inputs")) |in_n| {
        if (in_n.asMap()) |in_entries| {
            for (in_entries) |ie| {
                if (ie.value.asScalar()) |vs| {
                    try inputs.append(alloc, .{
                        .param_name = abi.Slice_ABI.from(ie.key),
                        .stream_ref = abi.Slice_ABI.from(try interp(alloc, env, vs)),
                    });
                } else if (ie.value.asMap() != null) {
                    const sref = if (ie.value.get("from")) |fn_| fn_.asScalar() else null;
                    const wf = if (ie.value.get("where")) |wn| wn.asScalar() else null;
                    try inputs.append(alloc, .{
                        .param_name = abi.Slice_ABI.from(ie.key),
                        .stream_ref = if (sref) |sr| abi.Slice_ABI.from(try interp(alloc, env, sr)) else abi.Slice_ABI.empty,
                        .where_filter = if (wf) |w| abi.Slice_ABI.from(try interp(alloc, env, w)) else abi.Slice_ABI.empty,
                    });
                }
            }
        }
    }

    var outputs: std.ArrayListUnmanaged(abi.extension.ChannelOutput_ABI) = .empty;
    if (node.get("outputs")) |out_n| {
        if (out_n.asMap()) |out_entries| {
            for (out_entries) |oe| {
                const ds = if (oe.value.get("datasource")) |d| d.asScalar() orelse "default" else if (oe.value.get("to")) |t| t.asScalar() orelse "default" else "default";
                const from_f = if (oe.value.get("from")) |f| f.asScalar() else null;
                const schema_r = if (oe.value.get("schema")) |s| s.asScalar() else null;
                const filter_s = if (oe.value.get("filter")) |fl| fl.asScalar() else null;
                const retain_b = if (oe.value.get("retain")) |rt| (if (rt.asScalar()) |rs| parseBool(rs) else false) else false;
                const app_p = if (oe.value.get("append")) |an| try parseConfigParams(alloc, env, an) else &.{};
                const rem_l = if (oe.value.get("remove")) |rn| try parseSliceList(alloc, env, rn) else &.{};
                try outputs.append(alloc, .{
                    .name = abi.Slice_ABI.from(oe.key),
                    .from_field = if (from_f) |ff| abi.Slice_ABI.from(try interp(alloc, env, ff)) else abi.Slice_ABI.empty,
                    .schema_ref = if (schema_r) |sr| abi.Slice_ABI.from(try interp(alloc, env, sr)) else abi.Slice_ABI.empty,
                    .datasource = abi.Slice_ABI.from(try interp(alloc, env, ds)),
                    .filter = if (filter_s) |fs| abi.Slice_ABI.from(try interp(alloc, env, fs)) else abi.Slice_ABI.empty,
                    .retain = retain_b,
                    .append_ptr = if (app_p.len > 0) app_p.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
                    .append_len = app_p.len,
                    .remove_ptr = if (rem_l.len > 0) rem_l.ptr else (&[_]abi.Slice_ABI{}).ptr,
                    .remove_len = rem_l.len,
                });
            }
        } else if (out_n.asSeq()) |out_seq| {
            for (out_seq) |on| {
                const name = if (on.get("name")) |nn| nn.asScalar() orelse "out" else "out";
                const ds = if (on.get("datasource")) |d| d.asScalar() orelse "default" else "default";
                try outputs.append(alloc, .{
                    .name = abi.Slice_ABI.from(try interp(alloc, env, name)),
                    .datasource = abi.Slice_ABI.from(try interp(alloc, env, ds)),
                });
            }
        }
    }

    const where_f = if (node.get("where")) |wn| (if (wn.asScalar()) |ws| abi.Slice_ABI.from(try interp(alloc, env, ws)) else abi.Slice_ABI.empty) else abi.Slice_ABI.empty;
    const conc: ?usize = if (node.get("concurrency")) |cn| (if (cn.asScalar()) |cs| std.fmt.parseInt(usize, cs, 10) catch null else null) else null;
    const static_p = if (node.get("params")) |pn|
        try parseConfigParams(alloc, env, pn)
    else if (node.get("with")) |wn|
        try parseConfigParams(alloc, env, wn)
    else
        &.{};
    const after_l = if (node.get("after")) |an| try parseSliceList(alloc, env, an) else &.{};
    const nets_l = if (node.get("networks")) |nn| try parseSliceList(alloc, env, nn) else if (node.get("network")) |n1| try parseSliceList(alloc, env, n1) else &.{};

    const spec = abi.extension.TaskStep_ABI{
        .id = abi.Slice_ABI.from(try interp(alloc, env, id_s)),
        .module = abi.Slice_ABI.from(mod_s),
        .task = abi.Slice_ABI.from(task_s),
        .networks_ptr = if (nets_l.len > 0) nets_l.ptr else (&[_]abi.Slice_ABI{}).ptr,
        .networks_len = nets_l.len,
        .inputs_ptr = if (inputs.items.len > 0) inputs.items.ptr else (&[_]abi.extension.InputBinding_ABI{}).ptr,
        .inputs_len = inputs.items.len,
        .where_filter = where_f,
        .concurrency = conc orelse 0,
        .has_concurrency = conc != null,
        .static_params_ptr = if (static_p.len > 0) static_p.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
        .static_params_len = static_p.len,
        .outputs_ptr = if (outputs.items.len > 0) outputs.items.ptr else (&[_]abi.extension.ChannelOutput_ABI{}).ptr,
        .outputs_len = outputs.items.len,
        .after_ptr = if (after_l.len > 0) after_l.ptr else (&[_]abi.Slice_ABI{}).ptr,
        .after_len = after_l.len,
    };
    try checkAbi(vtable.add_task_step(builder, &spec));
}

fn emitPipelinesMap(
    alloc: Allocator,
    env: *EnvInterpolator,
    pipes_node: YamlAst,
    builder: *abi.extension.PipelineBuilderHandle_ABI,
    vtable: *const abi.extension.PipelineBuilderVTable_ABI,
) !void {
    const entries = pipes_node.asMap() orelse return;
    for (entries) |pe| {
        const routing_code: i32 = if (pe.value.get("routing")) |rn|
            (if (rn.asScalar()) |rs| @intCast(parseRoutingCode(try interp(alloc, env, rs))) else -1)
        else
            -1;
        const enabled_b: bool = if (pe.value.get("enabled")) |en| (if (en.asScalar()) |es| parseBool(es) else true) else true;
        const conc: ?usize = if (pe.value.get("concurrency")) |cn| (if (cn.asScalar()) |cs| std.fmt.parseInt(usize, cs, 10) catch null else null) else null;

        try checkAbi(vtable.begin_pipeline(
            builder,
            abi.Slice_ABI.from(pe.key),
            routing_code,
            enabled_b,
            conc orelse 0,
            conc != null,
        ));

        if (pe.value.get("steps")) |steps_n| {
            if (steps_n.asSeq()) |seq| {
                for (seq) |sn| {
                    try emitStep(alloc, env, sn, builder, vtable);
                }
            }
        }
    }
}

fn parseFieldType(s: []const u8) sdk.capabilities.FieldType {
    return std.meta.stringToEnum(sdk.capabilities.FieldType, s) orelse .text;
}

fn parseFieldSpec(alloc: Allocator, env: *EnvInterpolator, node: YamlAst) !sdk.capabilities.FieldSpec {
    const name = if (node.get("name")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
    const label = if (node.get("label")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
    const desc = if (node.get("description")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
    const ftype = if (node.get("field_type")) |n| (if (n.asScalar()) |s| parseFieldType(try interp(alloc, env, s)) else .text) else .text;
    const req = if (node.get("required")) |n| (if (n.asScalar()) |s| parseBool(try interp(alloc, env, s)) else true) else true;
    const def_v = if (node.get("default_value")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
    const pat = if (node.get("pattern")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
    var ev_list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (node.get("enum_values")) |en| {
        if (en.asSeq()) |seq| {
            for (seq) |it| {
                if (it.asScalar()) |s| try ev_list.append(alloc, try interp(alloc, env, s));
            }
        }
    }
    return .{
        .name = name,
        .label = label,
        .description = desc,
        .field_type = ftype,
        .required = req,
        .default_value = def_v,
        .enum_values = try ev_list.toOwnedSlice(alloc),
        .pattern = pat,
    };
}

pub fn loadCapabilityCatalogFile(alloc: Allocator, path: []const u8) !sdk.capabilities.CapabilityCatalog {
    const bytes = try readFileAlloc(alloc, path);
    if (std.mem.endsWith(u8, path, ".json")) {
        const parsed = try std.json.parseFromSlice(sdk.capabilities.CapabilityCatalog, alloc, bytes, .{
            .ignore_unknown_fields = true,
        });
        return parsed.value;
    }
    var env = EnvInterpolator.init(true);
    const root_node = try yaml.parseAst(alloc, bytes, .{});
    return try parseCapabilityCatalogYaml(alloc, &env, root_node);
}

fn parseCapabilityCatalogYaml(alloc: Allocator, env: *EnvInterpolator, root_node: YamlAst) !sdk.capabilities.CapabilityCatalog {
    const id = if (root_node.get("id")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "parabellum") else "parabellum";
    const name = if (root_node.get("name")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "Parabellum") else "Parabellum";
    const version = if (root_node.get("version")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "0.1.0") else "0.1.0";
    const desc = if (root_node.get("description")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;

    var caps: std.ArrayListUnmanaged(sdk.capabilities.CapabilitySpec) = .empty;
    if (root_node.get("capabilities")) |caps_n| {
        if (caps_n.asSeq()) |seq| {
            for (seq) |cn| {
                const cid = if (cn.get("id")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                const grp = if (cn.get("group")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "default") else "default";
                const title = if (cn.get("title")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
                const cdesc = if (cn.get("description")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
                const tk: sdk.capabilities.CapabilityTargetKind = if (cn.get("target_kind")) |n|
                    (if (n.asScalar()) |s| (std.meta.stringToEnum(sdk.capabilities.CapabilityTargetKind, try interp(alloc, env, s)) orelse .pipeline) else .pipeline)
                else
                    .pipeline;
                const target = if (cn.get("target")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
                const mode: sdk.capabilities.ExecutionMode = if (cn.get("execution_mode")) |n|
                    (if (n.asScalar()) |s| (std.meta.stringToEnum(sdk.capabilities.ExecutionMode, try interp(alloc, env, s)) orelse .sync_fast) else .sync_fast)
                else
                    .sync_fast;
                const accepts_batch = if (cn.get("accepts_batch")) |n| (if (n.asScalar()) |s| parseBool(s) else false) else false;
                const input_stream = if (cn.get("input_stream")) |n| (if (n.asScalar()) |s| parseBool(s) else false) else false;

                var inputs: std.ArrayListUnmanaged(sdk.capabilities.FieldSpec) = .empty;
                if (cn.get("inputs")) |in_n| {
                    if (in_n.asSeq()) |in_seq| {
                        for (in_seq) |fn_| {
                            try inputs.append(alloc, try parseFieldSpec(alloc, env, fn_));
                        }
                    }
                }

                var out_spec = sdk.capabilities.OutputSpec{};
                if (cn.get("output")) |on| {
                    if (on.get("kind")) |kn| {
                        if (kn.asScalar()) |ks| {
                            out_spec.kind = std.meta.stringToEnum(sdk.capabilities.OutputKind, try interp(alloc, env, ks)) orelse .none;
                        }
                    }
                    if (on.get("mime_type")) |mn| {
                        if (mn.asScalar()) |ms| out_spec.mime_type = try interp(alloc, env, ms);
                    }
                    if (on.get("mime_field")) |mfn| {
                        if (mfn.asScalar()) |mfs| out_spec.mime_field = try interp(alloc, env, mfs);
                    }
                    if (on.get("fields")) |fsn| {
                        if (fsn.asSeq()) |fseq| {
                            var out_fields: std.ArrayListUnmanaged(sdk.capabilities.FieldSpec) = .empty;
                            for (fseq) |ffn| {
                                try out_fields.append(alloc, try parseFieldSpec(alloc, env, ffn));
                            }
                            out_spec.fields = try out_fields.toOwnedSlice(alloc);
                        }
                    }
                }

                var actions: std.ArrayListUnmanaged(sdk.capabilities.ActionLink) = .empty;
                if (cn.get("actions")) |acts_n| {
                    if (acts_n.asSeq()) |aseq| {
                        for (aseq) |an| {
                            const lbl = if (an.get("label")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                            const cap_id = if (an.get("capability_id")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                            const cond_f = if (an.get("condition_field")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
                            const cond_eq = if (an.get("condition_equals")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;

                            var pmap: std.ArrayListUnmanaged(sdk.capabilities.ActionParamMap) = .empty;
                            if (an.get("param_map")) |pmn| {
                                if (pmn.asSeq()) |pseq| {
                                    for (pseq) |pn| {
                                        const ti = if (pn.get("target_input")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                                        const sf = if (pn.get("source_field")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                                        try pmap.append(alloc, .{ .target_input = ti, .source_field = sf });
                                    }
                                }
                            }
                            try actions.append(alloc, .{
                                .label = lbl,
                                .capability_id = cap_id,
                                .condition_field = cond_f,
                                .condition_equals = cond_eq,
                                .param_map = try pmap.toOwnedSlice(alloc),
                            });
                        }
                    }
                }

                var hints: std.ArrayListUnmanaged(sdk.capabilities.KeyValue) = .empty;
                if (cn.get("hints")) |hn| {
                    if (hn.asMap()) |hentries| {
                        for (hentries) |he| {
                            if (he.value.asScalar()) |hs| {
                                try hints.append(alloc, .{ .key = he.key, .value = try interp(alloc, env, hs) });
                            }
                        }
                    }
                }

                try caps.append(alloc, .{
                    .id = cid,
                    .group = grp,
                    .title = title,
                    .description = cdesc,
                    .target_kind = tk,
                    .target = target,
                    .execution_mode = mode,
                    .accepts_batch = accepts_batch,
                    .input_stream = input_stream,
                    .inputs = try inputs.toOwnedSlice(alloc),
                    .output = out_spec,
                    .actions = try actions.toOwnedSlice(alloc),
                    .hints = try hints.toOwnedSlice(alloc),
                });
            }
        }
    }

    var events: std.ArrayListUnmanaged(sdk.capabilities.EventSpec) = .empty;
    if (root_node.get("events")) |evs_n| {
        if (evs_n.asSeq()) |seq| {
            for (seq) |en| {
                const topic = if (en.get("topic")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                const edesc = if (en.get("description")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else null) else null;
                var efields: std.ArrayListUnmanaged(sdk.capabilities.FieldSpec) = .empty;
                if (en.get("fields")) |efn| {
                    if (efn.asSeq()) |fseq| {
                        for (fseq) |ffn| {
                            try efields.append(alloc, try parseFieldSpec(alloc, env, ffn));
                        }
                    }
                }
                try events.append(alloc, .{
                    .topic = topic,
                    .description = edesc,
                    .fields = try efields.toOwnedSlice(alloc),
                });
            }
        }
    }

    var cat_hints: std.ArrayListUnmanaged(sdk.capabilities.KeyValue) = .empty;
    if (root_node.get("hints")) |hn| {
        if (hn.asMap()) |hentries| {
            for (hentries) |he| {
                if (he.value.asScalar()) |hs| {
                    try cat_hints.append(alloc, .{ .key = he.key, .value = try interp(alloc, env, hs) });
                }
            }
        }
    }

    return .{
        .id = id,
        .name = name,
        .version = version,
        .description = desc,
        .capabilities = try caps.toOwnedSlice(alloc),
        .events = try events.toOwnedSlice(alloc),
        .hints = try cat_hints.toOwnedSlice(alloc),
    };
}

fn emitApiSpec(
    alloc: Allocator,
    env: *EnvInterpolator,
    pipe_dir: []const u8,
    datasource_id: []const u8,
    raw_spec_ref: []const u8,
    ds_network: []const u8,
    builder: *abi.extension.PipelineBuilderHandle_ABI,
    vtable: *const abi.extension.PipelineBuilderVTable_ABI,
) !void {
    const begin_fn = vtable.begin_datasource_api orelse return;
    const add_ep_fn = vtable.add_datasource_api_endpoint orelse return;

    var file_path = raw_spec_ref;
    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, raw_spec_ref, '#')) |hash_idx| {
        file_path = raw_spec_ref[0..hash_idx];
        fragment = raw_spec_ref[hash_idx + 1 ..];
    }

    const rel_cand = try std.fs.path.join(alloc, &.{ pipe_dir, file_path });
    const bytes = readFileAlloc(alloc, file_path) catch (readFileAlloc(alloc, rel_cand) catch return);
    const root_doc = yaml.parseAst(alloc, bytes, .{}) catch return;

    // Support top-level `id:` or `apis: { <fragment>: ... }`
    var api_node = root_doc;
    if (fragment) |frag| {
        if (root_doc.get("apis")) |apis_n| {
            if (apis_n.get(frag)) |sub| api_node = sub;
        }
    }

    const api_id = if (api_node.get("id")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else fragment orelse datasource_id) else (fragment orelse datasource_id);
    const base_url = if (api_node.get("base_url")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
    const net_s = if (ds_network.len > 0) ds_network else if (api_node.get("network")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
    const def_headers = if (api_node.get("headers")) |hn| try parseConfigParams(alloc, env, hn) else &.{};

    var auth_kind: []const u8 = "";
    var auth_token: []const u8 = "";
    var auth_header_name: []const u8 = "";
    var auth_query_param: []const u8 = "";
    var auth_username: []const u8 = "";
    var auth_password: []const u8 = "";
    var auth_creds: []const u8 = "";
    var auth_scope: []const u8 = "";
    var auth_token_uri: []const u8 = "";

    if (api_node.get("auth")) |an| {
        if (an.get("type") orelse an.get("kind")) |n| {
            if (n.asScalar()) |s| auth_kind = try interp(alloc, env, s);
        }
        if (an.get("token")) |n| {
            if (n.asScalar()) |s| auth_token = try interp(alloc, env, s);
        }
        if (an.get("header_name")) |n| {
            if (n.asScalar()) |s| auth_header_name = try interp(alloc, env, s);
        }
        if (an.get("query_param")) |n| {
            if (n.asScalar()) |s| auth_query_param = try interp(alloc, env, s);
        }
        if (an.get("username")) |n| {
            if (n.asScalar()) |s| auth_username = try interp(alloc, env, s);
        }
        if (an.get("password")) |n| {
            if (n.asScalar()) |s| auth_password = try interp(alloc, env, s);
        }
        if (an.get("credentials_path") orelse an.get("credentials")) |n| {
            if (n.asScalar()) |s| auth_creds = try interp(alloc, env, s);
        }
        if (an.get("scope")) |n| {
            if (n.asScalar()) |s| auth_scope = try interp(alloc, env, s);
        }
        if (an.get("token_uri")) |n| {
            if (n.asScalar()) |s| auth_token_uri = try interp(alloc, env, s);
        }
    }

    const hdr_abi = abi.extension.ApiSpecHeader_ABI{
        .datasource_id = abi.Slice_ABI.from(datasource_id),
        .api_id = abi.Slice_ABI.from(api_id),
        .base_url = abi.Slice_ABI.from(base_url),
        .network = abi.Slice_ABI.from(net_s),
        .auth_kind = abi.Slice_ABI.from(auth_kind),
        .auth_token = abi.Slice_ABI.from(auth_token),
        .auth_header_name = abi.Slice_ABI.from(auth_header_name),
        .auth_query_param = abi.Slice_ABI.from(auth_query_param),
        .auth_username = abi.Slice_ABI.from(auth_username),
        .auth_password = abi.Slice_ABI.from(auth_password),
        .auth_credentials_path = abi.Slice_ABI.from(auth_creds),
        .auth_scope = abi.Slice_ABI.from(auth_scope),
        .auth_token_uri = abi.Slice_ABI.from(auth_token_uri),
        .headers_ptr = if (def_headers.len > 0) def_headers.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
        .headers_len = def_headers.len,
    };
    try checkAbi(begin_fn(builder, &hdr_abi));

    if (api_node.get("endpoints")) |eps_n| {
        if (eps_n.asMap()) |ep_entries| {
            for (ep_entries) |ee| {
                const ep_val = ee.value;
                const method = if (ep_val.get("method")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "GET") else "GET";
                const path = if (ep_val.get("path")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "/") else "/";
                const query = if (ep_val.get("query")) |qn| try parseConfigParams(alloc, env, qn) else &.{};
                const headers = if (ep_val.get("headers")) |hn| try parseConfigParams(alloc, env, hn) else &.{};

                var req_fmt: []const u8 = "";
                var req_ct: []const u8 = "";
                var req_body: []const u8 = "";
                var req_bnd: []const u8 = "";
                if (ep_val.get("request")) |rn| {
                    if (rn.get("format")) |n| {
                        if (n.asScalar()) |s| req_fmt = try interp(alloc, env, s);
                    }
                    if (rn.get("content_type")) |n| {
                        if (n.asScalar()) |s| req_ct = try interp(alloc, env, s);
                    }
                    if (rn.get("body_template")) |n| {
                        if (n.asScalar()) |s| req_body = try interp(alloc, env, s);
                    }
                    if (rn.get("multipart_boundary")) |n| {
                        if (n.asScalar()) |s| req_bnd = try interp(alloc, env, s);
                    }
                }

                var resp_fmt: []const u8 = "";
                var resp_root: []const u8 = "";
                var statuses: std.ArrayListUnmanaged(u16) = .empty;
                var mappings: std.ArrayListUnmanaged(abi.extension.ApiFieldMapping_ABI) = .empty;
                if (ep_val.get("response")) |resp_n| {
                    if (resp_n.asScalar()) |s| {
                        resp_fmt = try interp(alloc, env, s);
                    } else {
                        if (resp_n.get("format")) |n| {
                            if (n.asScalar()) |s| resp_fmt = try interp(alloc, env, s);
                        }
                    if (resp_n.get("root_path")) |n| {
                        if (n.asScalar()) |s| resp_root = try interp(alloc, env, s);
                    }
                    if (resp_n.get("success_status")) |sn| {
                        if (sn.asSeq()) |seq| {
                            for (seq) |it| {
                                if (it.asScalar()) |s| {
                                    if (std.fmt.parseInt(u16, s, 10)) |code| {
                                        try statuses.append(alloc, code);
                                    } else |_| {}
                                }
                            }
                        }
                    }
                    if (resp_n.get("mapping")) |mn| {
                        if (mn.asMap()) |m_entries| {
                            for (m_entries) |me| {
                                const sk = if (me.value.get("source")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                                const se = if (me.value.get("path")) |n|
                                    (if (n.asScalar()) |s| try interp(alloc, env, s) else "")
                                else if (me.value.get("expr")) |n|
                                    (if (n.asScalar()) |s| try interp(alloc, env, s) else "")
                                else
                                    "";
                                const lt = if (me.value.get("type")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                                const dv = if (me.value.get("default")) |n| (if (n.asScalar()) |s| try interp(alloc, env, s) else "") else "";
                                try mappings.append(alloc, .{
                                    .field_name = abi.Slice_ABI.from(me.key),
                                    .source_kind = abi.Slice_ABI.from(sk),
                                    .source_expr = abi.Slice_ABI.from(se),
                                    .logical_type = abi.Slice_ABI.from(lt),
                                    .default_value = abi.Slice_ABI.from(dv),
                                });
                            }
                        }
                    }
                    }
                }

                const ep_abi = abi.extension.ApiEndpoint_ABI{
                    .name = abi.Slice_ABI.from(ee.key),
                    .method = abi.Slice_ABI.from(method),
                    .path = abi.Slice_ABI.from(path),
                    .query_ptr = if (query.len > 0) query.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
                    .query_len = query.len,
                    .headers_ptr = if (headers.len > 0) headers.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
                    .headers_len = headers.len,
                    .request_format = abi.Slice_ABI.from(req_fmt),
                    .request_content_type = abi.Slice_ABI.from(req_ct),
                    .request_body_template = abi.Slice_ABI.from(req_body),
                    .request_multipart_boundary = abi.Slice_ABI.from(req_bnd),
                    .response_format = abi.Slice_ABI.from(resp_fmt),
                    .response_root_path = abi.Slice_ABI.from(resp_root),
                    .success_status_ptr = if (statuses.items.len > 0) statuses.items.ptr else (&[_]u16{}).ptr,
                    .success_status_len = statuses.items.len,
                    .mapping_ptr = if (mappings.items.len > 0) mappings.items.ptr else (&[_]abi.extension.ApiFieldMapping_ABI{}).ptr,
                    .mapping_len = mappings.items.len,
                };
                try checkAbi(add_ep_fn(builder, abi.Slice_ABI.from(datasource_id), &ep_abi));
            }
        }
    }
}

pub fn loadPipelineWithBuilder(
    alloc: Allocator,
    pipeline_path: []const u8,
    builder: *abi.extension.PipelineBuilderHandle_ABI,
    vtable: *const abi.extension.PipelineBuilderVTable_ABI,
) !void {
    var env = EnvInterpolator.init(true);
    defer env.deinit(alloc);

    const pipe_dir = std.fs.path.dirname(pipeline_path) orelse ".";
    const env_candidates = [_][]const u8{
        ".env",
        "configs/.env",
        try std.fs.path.join(alloc, &.{ pipe_dir, ".env" }),
    };
    for (env_candidates) |ep| {
        if (readFileAlloc(alloc, ep)) |bytes| {
            try env.parseDotEnv(alloc, bytes);
            break;
        } else |_| {}
    }

    const yaml_bytes = try readFileAlloc(alloc, pipeline_path);
    const root_node = try yaml.parseAst(alloc, yaml_bytes, .{});

    // runtime
    var rt_abi = abi.extension.RuntimeConfig_ABI{
        .default_network = abi.Slice_ABI.from("isolated"),
    };
    if (root_node.get("runtime")) |rt| {
        if (rt.get("workers")) |w| {
            if (w.asScalar()) |ws| {
                const v = try interp(alloc, &env, ws);
                rt_abi.workers = if (std.mem.eql(u8, v, "auto")) (std.Thread.getCpuCount() catch 4) else (std.fmt.parseInt(usize, v, 10) catch 1);
            }
        }
        if (rt.get("default_network")) |dn| {
            if (dn.asScalar()) |dns| rt_abi.default_network = abi.Slice_ABI.from(try interp(alloc, &env, dns));
        }
        if (rt.get("scheduler")) |sc| {
            if (sc.asScalar()) |scs| rt_abi.scheduler = parseSchedulerCode(try interp(alloc, &env, scs));
        }
        if (rt.get("routing")) |rn| {
            if (rn.asScalar()) |rns| rt_abi.routing = parseRoutingCode(try interp(alloc, &env, rns));
        }
        if (rt.get("max_inflight_bytes")) |mb| {
            if (mb.asScalar()) |mbs| {
                if (parseByteSize(try interp(alloc, &env, mbs))) |sz| {
                    rt_abi.max_inflight_bytes = sz;
                    rt_abi.has_max_inflight_bytes = true;
                }
            }
        }
        if (rt.get("retain_all")) |ra| {
            if (ra.asScalar()) |ras| rt_abi.retain_all = parseBool(try interp(alloc, &env, ras));
        }
        if (rt.get("max_activations_per_node")) |ma| {
            if (ma.asScalar()) |mas| rt_abi.max_activations_per_node = std.fmt.parseInt(u32, try interp(alloc, &env, mas), 10) catch 8;
        }
    }
    try checkAbi(vtable.set_runtime(builder, &rt_abi));

    // modules
    if (root_node.get("modules")) |mods_n| {
        if (mods_n.asMap()) |m_entries| {
            for (m_entries) |me| {
                const raw_path = if (me.value.asScalar()) |s| s else if (me.value.get("path")) |pn| pn.asScalar() orelse "" else "";
                try checkAbi(vtable.add_module(
                    builder,
                    abi.Slice_ABI.from(me.key),
                    abi.Slice_ABI.from(try interp(alloc, &env, raw_path)),
                ));
            }
        }
    }

    // networks
    if (vtable.add_network) |add_net_fn| {
        if (root_node.get("networks")) |nets_n| {
            if (nets_n.asMap()) |n_entries| {
                for (n_entries) |ne| {
                    const drv = if (ne.value.get("driver")) |dn| (if (dn.asScalar()) |s| try interp(alloc, &env, s) else "egress") else "egress";
                    var def_act: []const u8 = "";
                    if (ne.value.get("policy")) |pn| {
                        if (pn.get("default_action")) |dan| {
                            if (dan.asScalar()) |s| def_act = try interp(alloc, &env, s);
                        }
                    }
                    const net_abi = abi.extension.NetworkSpec_ABI{
                        .id = abi.Slice_ABI.from(ne.key),
                        .driver = abi.Slice_ABI.from(drv),
                        .default_action = abi.Slice_ABI.from(def_act),
                    };
                    try checkAbi(add_net_fn(builder, &net_abi));
                }
            }
        }
    }

    // datasources + schema path + rest_api specs
    var schemas_path: abi.Slice_ABI = abi.Slice_ABI.empty;
    if (root_node.get("datasources")) |ds_n| {
        if (ds_n.asMap()) |d_entries| {
            for (d_entries) |de| {
                const drv = if (de.value.get("driver")) |dn| dn.asScalar() orelse "memory" else "memory";
                const drv_interp = try interp(alloc, &env, drv);
                const role = if (de.value.get("role")) |rn| rn.asScalar() orelse "duplex" else "duplex";
                var spec_ref: ?[]const u8 = null;
                var ds_net: []const u8 = "";
                var params: std.ArrayListUnmanaged(abi.ConfigParam_ABI) = .empty;
                if (de.value.asMap()) |p_entries| {
                    for (p_entries) |pe| {
                        if (std.mem.eql(u8, pe.key, "driver") or std.mem.eql(u8, pe.key, "role")) continue;
                        if (pe.value.asScalar()) |pv| {
                            const val = try interp(alloc, &env, pv);
                            if (std.mem.eql(u8, pe.key, "schema") and schemas_path.len == 0) {
                                schemas_path = abi.Slice_ABI.from(val);
                            } else if (std.mem.eql(u8, pe.key, "spec")) {
                                spec_ref = val;
                            } else if (std.mem.eql(u8, pe.key, "network")) {
                                ds_net = val;
                            }
                            try params.append(alloc, .{
                                .key = abi.Slice_ABI.from(pe.key),
                                .value = abi.Slice_ABI.from(val),
                            });
                        }
                    }
                }
                try checkAbi(vtable.add_datasource(
                    builder,
                    abi.Slice_ABI.from(de.key),
                    abi.Slice_ABI.from(drv_interp),
                    parseRoleCode(try interp(alloc, &env, role)),
                    if (params.items.len > 0) params.items.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
                    params.items.len,
                ));
                if ((std.mem.eql(u8, drv_interp, "rest_api") or std.mem.eql(u8, drv_interp, "http_api")) and spec_ref != null) {
                    try emitApiSpec(alloc, &env, pipe_dir, de.key, spec_ref.?, ds_net, builder, vtable);
                }
            }
        }
    }

    // extensions
    if (root_node.get("extensions")) |exts_n| {
        if (exts_n.asMap()) |e_entries| {
            for (e_entries) |ee| {
                var listen: abi.Slice_ABI = abi.Slice_ABI.empty;
                if (ee.value.get("listen")) |ln| {
                    if (ln.asScalar()) |ls| listen = abi.Slice_ABI.from(try interp(alloc, &env, ls));
                } else if (ee.value.get("host")) |hn| {
                    if (hn.asScalar()) |hs| {
                        const port_s = if (ee.value.get("port")) |pn| (pn.asScalar() orelse "8080") else "8080";
                        listen = abi.Slice_ABI.from(try std.fmt.allocPrint(alloc, "{s}:{s}", .{ try interp(alloc, &env, hs), try interp(alloc, &env, port_s) }));
                    }
                }
                var env_list: std.ArrayListUnmanaged(abi.ConfigParam_ABI) = .empty;
                if (std.mem.eql(u8, ee.key, "opentelemetry")) {
                    if (ee.value.get("file")) |fn_| {
                        if (fn_.asScalar()) |fs| {
                            const v = try interp(alloc, &env, fs);
                            try env_list.append(alloc, .{ .key = abi.Slice_ABI.from("PARABELLUM_OTEL_FILE"), .value = abi.Slice_ABI.from(v) });
                            try env_list.append(alloc, .{ .key = abi.Slice_ABI.from("OTEL_EXPORTER_FILE_PATH"), .value = abi.Slice_ABI.from(v) });
                            try env_list.append(alloc, .{ .key = abi.Slice_ABI.from("PARABELLUM_OTEL_OUT"), .value = abi.Slice_ABI.from(v) });
                        }
                    }
                    if (ee.value.get("console")) |cn| {
                        if (cn.asScalar()) |cs| {
                            const v = try interp(alloc, &env, cs);
                            try env_list.append(alloc, .{ .key = abi.Slice_ABI.from("OTEL_LOG_CONSOLE"), .value = abi.Slice_ABI.from(v) });
                            try env_list.append(alloc, .{ .key = abi.Slice_ABI.from("PARABELLUM_OTEL_CONSOLE"), .value = abi.Slice_ABI.from(v) });
                        }
                    }
                } else if (std.mem.eql(u8, ee.key, "trace_jsonl")) {
                    if (ee.value.get("file")) |fn_| {
                        if (fn_.asScalar()) |fs| {
                            try env_list.append(alloc, .{ .key = abi.Slice_ABI.from("PARABELLUM_TRACE_OUT"), .value = abi.Slice_ABI.from(try interp(alloc, &env, fs)) });
                        }
                    }
                }
                try checkAbi(vtable.add_extension_config(
                    builder,
                    abi.Slice_ABI.from(ee.key),
                    listen,
                    if (env_list.items.len > 0) env_list.items.ptr else (&[_]abi.ConfigParam_ABI{}).ptr,
                    env_list.items.len,
                ));
            }
        }
    }

    // metadata paths + capability catalog
    var caps_path: abi.Slice_ABI = abi.Slice_ABI.empty;
    if (root_node.get("capabilities")) |cap_n| {
        if (cap_n.asScalar()) |cs| {
            const cpath = try interp(alloc, &env, cs);
            caps_path = abi.Slice_ABI.from(cpath);
            if (vtable.set_capability_catalog_json) |set_caps_fn| {
                const rel_cand = try std.fs.path.join(alloc, &.{ pipe_dir, cpath });
                if (readFileAlloc(alloc, cpath) catch (readFileAlloc(alloc, rel_cand) catch null)) |cap_bytes| {
                    if (std.mem.endsWith(u8, cpath, ".json")) {
                        try checkAbi(set_caps_fn(builder, abi.Slice_ABI.from(cap_bytes)));
                    } else if (yaml.parseAst(alloc, cap_bytes, .{})) |cap_root| {
                        const cat = try parseCapabilityCatalogYaml(alloc, &env, cap_root);
                        const json_bytes = try sdk.capabilities.toJson(alloc, cat);
                        try checkAbi(set_caps_fn(builder, abi.Slice_ABI.from(json_bytes)));
                    } else |_| {}
                }
            }
        } else if (cap_n.asMap() != null) {
            if (vtable.set_capability_catalog_json) |set_caps_fn| {
                const cat = try parseCapabilityCatalogYaml(alloc, &env, root_node);
                const json_bytes = try sdk.capabilities.toJson(alloc, cat);
                try checkAbi(set_caps_fn(builder, abi.Slice_ABI.from(json_bytes)));
            }
        }
    }
    try checkAbi(vtable.set_metadata_paths(builder, caps_path, schemas_path));

    // schemas.yaml -> add_schema_table
    if (vtable.add_schema_table) |add_tbl_fn| {
        const effective_schema = if (schemas_path.len > 0) schemas_path.toSlice() else "configs/schemas.yaml";
        const rel_schema = try std.fs.path.join(alloc, &.{ pipe_dir, effective_schema });
        if (readFileAlloc(alloc, effective_schema) catch (readFileAlloc(alloc, rel_schema) catch null)) |schema_bytes| {
            if (yaml.parseAst(alloc, schema_bytes, .{})) |s_root| {
                if (s_root.get("schemas")) |schemas_n| {
                    if (schemas_n.asMap()) |dom_entries| {
                        for (dom_entries) |de| {
                            if (de.value.asMap()) |tbl_entries| {
                                for (tbl_entries) |te| {
                                    var col_names: std.ArrayListUnmanaged(abi.Slice_ABI) = .empty;
                                    if (te.value.get("columns")) |cols_n| {
                                        if (cols_n.asMap()) |c_entries| {
                                            for (c_entries) |ce| {
                                                try col_names.append(alloc, abi.Slice_ABI.from(ce.key));
                                            }
                                        }
                                    }
                                    try checkAbi(add_tbl_fn(
                                        builder,
                                        abi.Slice_ABI.from(de.key),
                                        abi.Slice_ABI.from(te.key),
                                        if (col_names.items.len > 0) col_names.items.ptr else (&[_]abi.Slice_ABI{}).ptr,
                                        col_names.items.len,
                                    ));
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        }
    }

    // pipelines + imports
    if (root_node.get("imports")) |imp_n| {
        if (imp_n.asSeq()) |imp_seq| {
            for (imp_seq) |it| {
                if (it.asScalar()) |raw_imp| {
                    const imp_rel = try interp(alloc, &env, raw_imp);
                    const imp_path = try std.fs.path.join(alloc, &.{ pipe_dir, imp_rel });
                    const imp_bytes = readFileAlloc(alloc, imp_path) catch readFileAlloc(alloc, imp_rel) catch continue;
                    const imp_root = yaml.parseAst(alloc, imp_bytes, .{}) catch continue;
                    if (imp_root.get("pipelines")) |imp_pipes| {
                        try emitPipelinesMap(alloc, &env, imp_pipes, builder, vtable);
                    }
                }
            }
        }
    }
    if (root_node.get("pipelines")) |pipes_n| {
        try emitPipelinesMap(alloc, &env, pipes_n, builder, vtable);
    }
}

test "yaml_config smoke" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const doc = try yaml.parseAst(arena.allocator(), "key: value\n", .{});
    try std.testing.expect(doc.asMap() != null);
}
