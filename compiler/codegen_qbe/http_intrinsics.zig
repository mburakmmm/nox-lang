//! `nox.http.*` intrinsic'lerinin GERÇEK codegen İMPLEMENTASYONLARI (`genHttpServe`/
//! `genHttpServeFd`/`genHttpServeMulticore`/ilgili sarmalayıcı/worker
//! üreticileri) — bkz. plan dosyası "QBE codegen backend'ini alt modüllere
//! bölme". Bu çağrıların HANGİ callee'lerin bu ÖZEL kod yoluna GİRDİĞİNİN
//! sınıflandırması ARTIK burada DEĞİL — Faz P1.6 (bkz. proje belleği
//! "stdlib-vs-language boundary" kararı): `async_thread.zig`nin
//! `intrinsic_table`/`matchIntrinsicKind`i (`nox.thread.start`la PAYLAŞILAN
//! GENEL bir mekanizma) bu dosyanın fonksiyonlarını `genCall`e BAĞLAR — bu
//! dosya yalnızca `nox.http` İçin GEÇERLİ olan GÖVDE üretimini barındırır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const ClassInfo = types.ClassInfo;
const UsedRequestFields = types.UsedRequestFields;
const HttpServeWrapperSpec = types.HttpServeWrapperSpec;
const HttpServeMulticoreWorkerSpec = types.HttpServeMulticoreWorkerSpec;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;
const isHeapManaged = abi.isHeapManaged;

/// Faz HH.4: `attr` `method`/`target`/`body`/`headers`den biriyse
/// İLGİLİ bayrağı işaretler. `HttpRequest`in checker TARAFINDAN ZATEN
/// TAM OLARAK bu dört alanla SINIRLANDIĞI (bkz. `stdlib/nox/http.nox`)
/// İÇİN, `req.<attr>` biçiminde GEÇERLİ (tip-denetimini GEÇMİŞ) BAŞKA
/// bir `attr` OLAMAZ — eşleşmeyen bir isim BURAYA HİÇ ULAŞMAZ.
pub fn markRequestField(used: *UsedRequestFields, attr: []const u8) void {
    if (std.mem.eql(u8, attr, "method")) used.method = true;
    if (std.mem.eql(u8, attr, "target")) used.target = true;
    if (std.mem.eql(u8, attr, "body")) used.body = true;
    if (std.mem.eql(u8, attr, "headers")) used.headers = true;
}

/// Faz HH.4: `param_name` isimli tanımlayıcının (`handle`in `req`
/// parametresi) bir ifade AĞACI İÇİNDE nasıl kullanıldığını TAM OLARAK
/// (17 `ast.Expr` varyantının HEPSİNİ ele alarak — `else` KULLANILMAZ,
/// Zig'in KAPSAMLI switch zorunluluğu GELECEKTE eklenecek yeni bir
/// varyantı BURADA UNUTMAYI derleme-zamanı hatasına ÇEVİRİR) dolaşır.
/// **Güvenlik ilkesi:** `req.<field>` biçimindeki DOĞRUDAN erişimler
/// İLGİLİ bayrağı işaretler; `req`in KENDİSİ (çıplak bir tanımlayıcı
/// olarak) BAŞKA HERHANGİ bir bağlamda (bir çağrıya argüman, bir
/// atamanın sağı/solu, bir listeye/dict'e eleman, vb.) GÖRÜNÜRSE bu bir
/// "kaçış" SAYILIR ve TÜM alanlar KONSERVATİF olarak kullanılmış
/// İŞARETLENİR (GG.2/GG.5/GG.9'un AYNI "kaçış ⇒ muhafazakâr" disiplini).
pub fn visitExprForReqUsage(e: ast.Expr, param_name: []const u8, used: *UsedRequestFields) void {
    switch (e) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => {},
        .identifier => |name| if (std.mem.eql(u8, name, param_name)) {
            used.* = UsedRequestFields.allUsed();
        },
        .unary => |u| visitExprForReqUsage(u.operand.*, param_name, used),
        .binary => |b| {
            visitExprForReqUsage(b.left.*, param_name, used);
            visitExprForReqUsage(b.right.*, param_name, used);
        },
        .call => |c| {
            visitExprForReqUsage(c.callee.*, param_name, used);
            for (c.args) |arg| visitExprForReqUsage(arg, param_name, used);
        },
        .attribute => |a| {
            if (a.obj.* == .identifier and std.mem.eql(u8, a.obj.identifier, param_name)) {
                markRequestField(used, a.attr);
            } else {
                visitExprForReqUsage(a.obj.*, param_name, used);
            }
        },
        .index => |ix| {
            visitExprForReqUsage(ix.obj.*, param_name, used);
            visitExprForReqUsage(ix.index.*, param_name, used);
        },
        .list_lit => |items| for (items) |it| visitExprForReqUsage(it, param_name, used),
        .dict_lit => |pairs| for (pairs) |p| {
            visitExprForReqUsage(p.key, param_name, used);
            visitExprForReqUsage(p.value, param_name, used);
        },
        .await_expr => |op| visitExprForReqUsage(op.*, param_name, used),
        .spawn_expr => |op| visitExprForReqUsage(op.*, param_name, used),
        .generic_construct => |gc| for (gc.args) |arg| visitExprForReqUsage(arg, param_name, used),
    }
}

/// Faz HH.4: `visitExprForReqUsage`in deyim-seviyesi eşleniği — HER
/// deyim varyantındaki alt-ifadeleri/iç-içe gövdeleri dolaşır. Bir
/// iç-içe `func_def` (closure) `req`i YAKALAYABİLECEĞİNDEN (yakalama
/// semantiğini analiz ETMEK yerine, `bodyHasNestedFuncDef`in AYNI
/// konservatif kararıyla) TÜM alanlar kullanılmış SAYILIR.
pub fn visitStmtsForReqUsage(stmts: []const ast.Stmt, param_name: []const u8, used: *UsedRequestFields) void {
    for (stmts) |stmt| {
        switch (stmt.kind) {
            .expr_stmt => |e| visitExprForReqUsage(e, param_name, used),
            .var_decl => |v| visitExprForReqUsage(v.value, param_name, used),
            .assign => |a| {
                visitExprForReqUsage(a.target, param_name, used);
                visitExprForReqUsage(a.value, param_name, used);
            },
            .if_stmt => |s| {
                visitExprForReqUsage(s.cond, param_name, used);
                visitStmtsForReqUsage(s.then_body, param_name, used);
                for (s.elif_clauses) |ec| {
                    visitExprForReqUsage(ec.cond, param_name, used);
                    visitStmtsForReqUsage(ec.body, param_name, used);
                }
                if (s.else_body) |eb| visitStmtsForReqUsage(eb, param_name, used);
            },
            .while_stmt => |s| {
                visitExprForReqUsage(s.cond, param_name, used);
                visitStmtsForReqUsage(s.body, param_name, used);
            },
            .for_stmt => |s| {
                visitExprForReqUsage(s.iterable, param_name, used);
                visitStmtsForReqUsage(s.body, param_name, used);
            },
            .return_stmt => |maybe_e| if (maybe_e) |e| visitExprForReqUsage(e, param_name, used),
            .raise_stmt => |e| visitExprForReqUsage(e, param_name, used),
            .try_stmt => |s| {
                visitStmtsForReqUsage(s.try_body, param_name, used);
                for (s.except_clauses) |ec| visitStmtsForReqUsage(ec.body, param_name, used);
                if (s.finally_body) |fb| visitStmtsForReqUsage(fb, param_name, used);
            },
            .lowlevel_stmt => |s| visitStmtsForReqUsage(s.body, param_name, used),
            .with_stmt => |s| {
                visitExprForReqUsage(s.ctx_expr, param_name, used);
                visitStmtsForReqUsage(s.body, param_name, used);
            },
            .defer_stmt => |d| visitExprForReqUsage(.{ .call = d.call }, param_name, used),
            .func_def => used.* = UsedRequestFields.allUsed(),
            .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt => {},
        }
    }
}

/// Faz HH.4: `fd` (`nox.http.serve`nin `handle` argümanı) İçin HANGİ
/// `HttpRequest` alanlarının GERÇEKTEN OKUNDUĞUNU döner — `fd.params[0]`
/// checker TARAFINDAN ZATEN `HttpRequest` (ya da eşdeğeri) tipinde
/// OLDUĞU doğrulanmış TEK parametredir (bkz. `genHttpServe`nin `sig.
/// params.len != 1` kontrolü).
pub fn computeUsedRequestFields(fd: ast.FuncDef) UsedRequestFields {
    var used: UsedRequestFields = .{};
    if (fd.params.len != 1) return UsedRequestFields.allUsed();
    visitStmtsForReqUsage(fd.body, fd.params[0].name, &used);
    return used;
}

/// Faz HH.4: `genHttpServe`/`genHttpServeFd`/`genHttpServeMulticore`nin
/// ÜÇÜNÜN de KULLANDIĞI ortak arama — `handle_name`in gövdesi `self.
/// func_defs`de BULUNAMAZSA (BEKLENMEDİK bir durum, `sig`in ZATEN
/// `self.functions`de bulunduğu doğrulanmıştır) KONSERVATİF olarak TÜM
/// alanlar kullanılmış SAYILIR.
pub fn computeUsedFieldsFor(self: *Codegen, handle_name: []const u8) UsedRequestFields {
    const hfd = self.func_defs.get(handle_name) orelse return UsedRequestFields.allUsed();
    return computeUsedRequestFields(hfd);
}

/// `nox.http.serve(port, handle[, max_connections])` çağrı sitesi
/// codegen'i — checker ZATEN `handle`in bir `(HttpRequest) -> HttpResponse`
/// imzalı, `async def` OLMAYAN çıplak bir isim olduğunu doğruladı (bkz.
/// checker.zig'in `tryResolveHttpServeCall`ı). `port` (ve varsa üçüncü
/// `max_connections` argümanı) değerlendirilir, `nox_http_server_listen`
/// ile dinlemeye başlanır, HER çağrı sitesi İÇİN AYRI bir C-ABI
/// sarmalayıcı (bkz. `HttpServeWrapperSpec`) TEMBEL kaydedilip
/// `nox_http_serve_raw`a `HandlerFn` olarak geçirilir — `rt`nin KENDİSİ
/// `handler_ctx` parametresi olarak taşınır (bkz. `HttpServeWrapperSpec`in
/// belge notu, `spawn`ın kapanış paketlemesinin AKSİNE).
pub fn genHttpServe(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 2 and c.args.len != 3) return error.Unsupported;

    const port_v0 = try self.genExpr(c.args[0]);
    try self.checkNoLowlevelEscape(port_v0);
    const port_v = try self.convert(port_v0, .l);
    try self.releaseIfTemporary(c.args[0], port_v0);

    const handle_name = switch (c.args[1]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    const sig = self.functions.get(handle_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;
    if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
    if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
    const req_class = sig.params[0].class_name.?;
    const resp_class = sig.ret.class_name.?;

    var max_conn_text: []const u8 = "0";
    if (c.args.len == 3) {
        const mc_v0 = try self.genExpr(c.args[2]);
        try self.checkNoLowlevelEscape(mc_v0);
        const mc_v = try self.convert(mc_v0, .l);
        try self.releaseIfTemporary(c.args[2], mc_v0);
        max_conn_text = mc_v.text;
    }

    const server = try self.newTemp();
    try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_listen", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_v.text } });

    const used_fields = self.computeUsedFieldsFor(handle_name);
    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = used_fields });

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    const needs_headers_text: []const u8 = if (used_fields.headers) "1" else "0";
    try self.qbeCall(null, "$nox_http_serve_raw", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = server }, .{ .ty = .l, .text = wrapper_sym }, .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = max_conn_text }, .{ .ty = .w, .text = needs_headers_text }, .{ .ty = .l, .text = "0" } });
    try self.qbeCall(null, "$nox_http_server_close", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = server } });
    return .{ .text = "0", .qtype = .none };
}

/// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — `nox_http_
/// server_from_fd`+`nox_http_serve_raw`+`nox_http_server_close` ÜÇ-
/// satırlık diziyi yayınlar. `genHttpServeFd`nin kuyruğu VE
/// `genHttpServeMulticoreWorker`nin SENTEZLENMİŞ gövdesi TARAFINDAN
/// paylaşılır (kod TEKRARI önlenir) — HER İKİSİ de MEVCUT `RT_PARAM`
/// (`"%rt"`) ismini KENDİ fonksiyon gövdelerinde ÖNCEDEN TANIMLAMIŞ
/// olmalıdır (`genThreadStartWrapper`nin `%argp`den `RT_PARAM`
/// YÜKLEMESİYLE AYNI sözleşme).
/// Faz "sunucu-tarafı TLS + WS": `tls_ctx_text` (varsa) `nox_http_server_
/// from_fd` YERİNE `nox_http_server_from_fd_tls`i, `ws_wrapper_name`
/// (varsa) `nox_http_serve_raw` YERİNE `nox_http_serve_ws_raw`ı seçer —
/// `null` GEÇİLDİĞİNDE davranış BİREBİR ÖNCEKİYLE AYNIDIR (mevcut TÜM
/// çağıranlar `null, null` geçer).
/// `ws_wrapper_name` VARSA `nox_http_serve_raw` YERİNE `nox_http_serve_
/// ws_raw`ı çağırır, SONRA `server`ı kapatır — `emitFdServeTail`/
/// `genHttpServe*Generic`nin ÜÇÜ de PAYLAŞTIĞI ORTAK kuyruk.
/// `shared_budget_text` (Faz MN.11.1): `"0"` (null işaretçi) İSE davranış
/// AYNEN ÖNCEKİYLE AYNIDIR — `serve`/`serve_tls`/`serve_ws`/`serve_fd*`nin
/// TÜM mevcut çağrı siteleri BUNU geçer. SADECE `serve_multicore`nin
/// SINIRLI (`max_connections>0`) yolu GERÇEK bir `SharedServeBudget*`
/// SSA metni geçirir (bkz. `SharedServeBudget`nin runtime tarafındaki
/// belge notu).
pub fn emitServeAndClose(self: *Codegen, server: []const u8, wrapper_name: []const u8, max_conn_text: []const u8, ws_wrapper_name: ?[]const u8, needs_headers: bool, shared_budget_text: []const u8) CodegenError!void {
    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    const needs_headers_text: []const u8 = if (needs_headers) "1" else "0";
    if (ws_wrapper_name) |wsw| {
        const wsw_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wsw});
        try self.qbeCall(null, "$nox_http_serve_ws_raw", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = server }, .{ .ty = .l, .text = wrapper_sym }, .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = wsw_sym }, .{ .ty = .l, .text = max_conn_text }, .{ .ty = .w, .text = needs_headers_text }, .{ .ty = .l, .text = shared_budget_text } });
    } else {
        try self.qbeCall(null, "$nox_http_serve_raw", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = server }, .{ .ty = .l, .text = wrapper_sym }, .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = max_conn_text }, .{ .ty = .w, .text = needs_headers_text }, .{ .ty = .l, .text = shared_budget_text } });
    }
    try self.qbeCall(null, "$nox_http_server_close", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = server } });
}

/// Faz "sunucu-tarafı TLS + WS": `tls_ctx_text` (varsa) `nox_http_server_
/// from_fd` YERİNE `nox_http_server_from_fd_tls`i seçer — `null` GEÇİLDİĞİNDE
/// davranış BİREBİR ÖNCEKİYLE AYNIDIR (`genHttpServeFd`nin AYNI çağrısı
/// `null, null` geçer).
pub fn emitFdServeTail(self: *Codegen, fd_text: []const u8, wrapper_name: []const u8, max_conn_text: []const u8, tls_ctx_text: ?[]const u8, ws_wrapper_name: ?[]const u8, needs_headers: bool) CodegenError!void {
    const server = try self.newTemp();
    if (tls_ctx_text) |ctx| {
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_from_fd_tls", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = fd_text }, .{ .ty = .l, .text = ctx } });
    } else {
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_from_fd", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = fd_text } });
    }
    try self.emitServeAndClose(server, wrapper_name, max_conn_text, ws_wrapper_name, needs_headers, "0");
}

/// Faz MN.11: `emitFdServeTail`nin `serve_multicore`-ÖZEL eşleniği —
/// PAYLAŞILAN, ÖNCEDEN hesaplanmış bir `fd`yi `nox_http_server_from_fd`
/// İLE SARMAK YERİNE `nox_http_server_listen_multicore_worker(_tls)`i
/// ÇAĞIRIR (KENDİ BAĞIMSIZ `SO_REUSEPORT` soketini TAZE AÇAR — standalone
/// bir C deneyiyle kanıtlanmış OS-seviyesi "paylaşılan fd + N kqueue"
/// thundering-herd maliyetini ORTADAN KALDIRAN düzeltme, bkz. proje
/// planı). `genHttpServeMulticore`/`genHttpServeMulticoreGeneric`nin
/// ÇAĞIRANIN KENDİ payı İLE `genHttpServeMulticoreWorker`nin ÜRETİLEN
/// worker gövdesi TARAFINDAN paylaşılır.
pub fn emitListenServeTail(self: *Codegen, port_text: []const u8, wrapper_name: []const u8, max_conn_text: []const u8, tls_ctx_text: ?[]const u8, ws_wrapper_name: ?[]const u8, needs_headers: bool, shared_budget_text: []const u8) CodegenError!void {
    const server = try self.newTemp();
    if (tls_ctx_text) |ctx| {
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_listen_multicore_worker_tls", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_text }, .{ .ty = .l, .text = ctx } });
    } else {
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_listen_multicore_worker", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_text } });
    }
    try self.emitServeAndClose(server, wrapper_name, max_conn_text, ws_wrapper_name, needs_headers, shared_budget_text);
}

/// `nox.http.serve_fd(fd, handle[, max_connections])` çağrı sitesi
/// codegen'i — Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60).
/// `genHttpServe` İLE NEREDEYSE ÖZDEŞ, TEK fark: `nox_http_server_
/// listen(rt, port)` (YENİ bir soket YARATIR) YERİNE `nox_http_server_
/// from_fd(rt, fd)` (ZATEN dinlemede olan PAYLAŞILAN bir fd'yi SARAR) —
/// `HttpServeWrapperSpec`/`genHttpServeWrapper` DEĞİŞTİRİLMEDEN
/// yeniden kullanılır.
pub fn genHttpServeFd(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 2 and c.args.len != 3) return error.Unsupported;

    const fd_v0 = try self.genExpr(c.args[0]);
    try self.checkNoLowlevelEscape(fd_v0);
    const fd_v = try self.convert(fd_v0, .l);
    try self.releaseIfTemporary(c.args[0], fd_v0);

    const handle_name = switch (c.args[1]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    const sig = self.functions.get(handle_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;
    if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
    if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
    const req_class = sig.params[0].class_name.?;
    const resp_class = sig.ret.class_name.?;

    var max_conn_text: []const u8 = "0";
    if (c.args.len == 3) {
        const mc_v0 = try self.genExpr(c.args[2]);
        try self.checkNoLowlevelEscape(mc_v0);
        const mc_v = try self.convert(mc_v0, .l);
        try self.releaseIfTemporary(c.args[2], mc_v0);
        max_conn_text = mc_v.text;
    }

    const used_fields = self.computeUsedFieldsFor(handle_name);
    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = used_fields });

    try self.emitFdServeTail(fd_v.text, wrapper_name, max_conn_text, null, null, used_fields.headers);
    return .{ .text = "0", .qtype = .none };
}

/// `nox.http.serve_multicore(port, handle, num_threads[,
/// max_connections])` çağrı sitesi codegen'i — Faz DD.1 (bkz. nox-
/// teknik-spesifikasyon.md §3.60). **Faz MN.11'DEN İTİBAREN**: `port`
/// (ÇIPLAK bir i64, HİÇBİR fd ÖNCEDEN hesaplanmaz) `num_threads - 1`
/// ek `nox.thread` worker'ına (bkz. `genHttpServeMulticoreWorker`)
/// `nox_thread_spawn` İLE payload OLARAK geçirilir — HER worker `nox_
/// http_server_listen_multicore_worker`i (bkz. `emitListenServeTail`)
/// KENDİ gövdesinde ÇAĞIRIP `SO_REUSEPORT` İLE KENDİ BAĞIMSIZ soketini
/// TAZE açar (standalone bir C deneyiyle kanıtlanmış, "TEK paylaşılan
/// fd + N kqueue" OS-seviyesi thundering-herd maliyetinin düzeltmesi,
/// bkz. proje planı) — `genForRange`nin AYNI sayaçlı-döngü şekli (bkz.
/// onun belge notu), TEK fark: döngü değişkeni bir Nox kullanıcı
/// değişkeni DEĞİL, `self.vars`e HİÇ kaydedilmeyen sentetik bir yığın
/// yuvasıdır. ÇAĞIRAN iş parçacığının KENDİSİ Nninci worker OLUR
/// (`emitListenServeTail` İLE, KENDİ BAĞIMSIZ soketiyle) — bugünkü
/// `nox.http.serve`nin "çağrı sonsuza kadar bloke olur" sözleşmesiyle
/// TUTARLI.
///
/// **`ThreadHandle`lar KENDİ `emitListenServeTail`imizden SONRA join
/// edilir (ARTIK "fire-and-forget" DEĞİL — bkz. aşağıdaki GERÇEK hata
/// notuyla DÜZELTİLDİ):** `max_connections=0` (sınırsız) OLDUĞUNDA
/// ÇAĞIRANIN KENDİ `emitFdServeTail`i ZATEN SONSUZA dek bloke olur, bu
/// yüzden aşağıdaki join döngüsüne HİÇ ULAŞILMAZ — davranış ESKİSİYLE
/// AYNI kalır. AMA `max_connections` SONLU olduğunda (üretimde nadir,
/// AMA testlerde/gelecekteki bir "zarif kapatma" özelliğinde GERÇEK bir
/// senaryo), ÇAĞIRANIN KENDİ payı biterse biterse HEMEN `$main`
/// tamamlanıp SÜREÇ çıkabilirdi — spawn edilen worker OS iş parçacıkları
/// KENDİ bağlantılarını HENÜZ kabul/sunmamışken bile (bkz. `nox_thread_
/// join`in fiber-duyarlı, `runtime/async_rt/thread_bridge.zig`deki
/// KANITLANMIŞ implementasyonu — SADECE ÇAĞIRAN FIBER'ı askıya alır,
/// AYNI OS iş parçacığındaki DİĞER fiber'lar/BAŞKA hiçbir şey BLOKE
/// OLMAZ).
pub fn genHttpServeMulticore(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 3 and c.args.len != 4) return error.Unsupported;

    const port_v0 = try self.genExpr(c.args[0]);
    try self.checkNoLowlevelEscape(port_v0);
    const port_v = try self.convert(port_v0, .l);
    try self.releaseIfTemporary(c.args[0], port_v0);

    const handle_name = switch (c.args[1]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    const sig = self.functions.get(handle_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;
    if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
    if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
    const req_class = sig.params[0].class_name.?;
    const resp_class = sig.ret.class_name.?;

    const num_threads_v0 = try self.genExpr(c.args[2]);
    try self.checkNoLowlevelEscape(num_threads_v0);
    const num_threads_v = try self.convert(num_threads_v0, .l);
    try self.releaseIfTemporary(c.args[2], num_threads_v0);

    // Checker ZATEN `.int_lit` olduğunu garanti etti (bkz.
    // `tryResolveHttpServeMulticoreCall`in belge notu) — DERLEME-
    // ZAMANI bir metin sabiti olarak HEM aşağıdaki `emitFdServeTail`
    // çağrısına HEM `genHttpServeMulticoreWorker`in sentezlediği
    // worker gövdesine gömülür.
    var max_conn_text: []const u8 = "0";
    var is_bounded = false;
    if (c.args.len == 4) {
        max_conn_text = try std.fmt.allocPrint(self.allocator, "{d}", .{c.args[3].int_lit});
        is_bounded = c.args[3].int_lit > 0;
    }

    // Faz MN.11.1 (bkz. `SharedServeBudget`nin runtime tarafındaki belge
    // notu — SO_REUSEPORT'un KÜÇÜK, SABİT `max_connections`ta kernel-
    // seviyesi bağlantı dağılım DENGESİZLİĞİ düzeltmesi): `is_bounded`
    // İSE, worker'lar spawn edilmeden ÖNCE TEK bir PAYLAŞILAN
    // `SharedServeBudget` ayrılır — HER worker'ın payload'ı ARTIK ÇIPLAK
    // `port` DEĞİL, bu bütçeyi de TAŞIYAN bir `MulticoreBoundedPayload*`dir.
    var shared_budget_text: []const u8 = "0";
    var worker_payload_text: []const u8 = port_v.text;
    if (is_bounded) {
        const budget_v = try self.newTemp();
        try self.qbeCall(.{ .name = budget_v, .ty = .l }, "$nox_http_make_shared_budget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = max_conn_text }, .{ .ty = .l, .text = num_threads_v.text } });
        shared_budget_text = budget_v;
        const payload_v = try self.newTemp();
        try self.qbeCall(.{ .name = payload_v, .ty = .l }, "$nox_http_make_bounded_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_v.text }, .{ .ty = .l, .text = "0" }, .{ .ty = .l, .text = budget_v } });
        worker_payload_text = payload_v;
    }

    // Faz MN.11 (bkz. proje planı — standalone bir C deneyiyle kanıtlanmış
    // OS-seviyesi "paylaşılan fd + N kqueue" thundering-herd maliyetinin
    // düzeltmesi): TEK bir `nox_http_listen_fd` çağrısıyla ÖNCEDEN
    // hesaplanmış, HER worker'a AYNI değer olarak GEÇİRİLEN bir `fd`
    // ARTIK YOK — payload SADECE `port` (HER worker İçİn GERÇEKTEN AYNI
    // OLAN bir i64), HER worker `nox_http_server_listen_multicore_worker`i
    // KENDİ gövdesinde (bkz. `genHttpServeMulticoreWorker`) ÇAĞIRIP
    // `SO_REUSEPORT` İLE KENDİ BAĞIMSIZ soketini TAZE açar.
    const used_fields = self.computeUsedFieldsFor(handle_name);
    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = used_fields });

    const worker_name = try std.fmt.allocPrint(self.allocator, "http_serve_mc_worker_{d}", .{self.http_serve_multicore_worker_counter});
    self.http_serve_multicore_worker_counter += 1;
    try self.http_serve_multicore_workers.append(self.allocator, .{ .name = worker_name, .wrapper_name = wrapper_name, .max_conn_text = max_conn_text, .needs_headers = used_fields.headers, .bounded = is_bounded });

    // Faz MN.7b: `--release` (LLVM backend) altında, `num_threads - 1`
    // × `$nox_thread_spawn` (AŞAĞIDAKİ, `.qbe`de DEĞİŞMEDEN KALAN yol)
    // YERİNE TEK bir `$nox_pool_serve` çağrısı — TÜM `num_threads` worker
    // (0 DAHİL) TEK bir paylaşılan `WorkerPool`a BAĞLANIR, bir handler
    // İçİNDE spawn edilen alt-görevler ARTIK ÇAPRAZ-worker ÇALINABİLİR.
    // `genHttpServeMulticoreWorker`nin (aşağıda, ÜRETİLEN worker
    // fonksiyonu) `%argp` şekli (`{rt, payload}`, `payload` @ offset 8 =
    // Faz MN.11'DEN İTİBAREN ÇIPLAK `port`) `nox_pool_serve`nin
    // `PoolServeClosure`ıyla BİREBİR AYNI olduğundan — AYNI ÜRETİLEN
    // fonksiyon HEM `$nox_thread_spawn` (`.qbe`) HEM `$nox_pool_serve`
    // (`.llvm`) TARAFINDAN `entry_fn` OLARAK KULLANILABİLİR, İKİNCİ bir
    // sarmalayıcı GEREKMEZ.
    if (self.backend == .llvm) {
        const worker_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{worker_name});
        const rc = try self.newTemp();
        try self.qbeCall(.{ .name = rc, .ty = .w }, "$nox_pool_serve", &.{
            .{ .ty = .l, .text = RT_PARAM },
            .{ .ty = .l, .text = num_threads_v.text },
            .{ .ty = .l, .text = worker_sym },
            .{ .ty = .l, .text = worker_payload_text },
        });
        // Faz MN.11.1: `$nox_pool_serve` SENKRON döner (TÜM worker'lar
        // BİTTİKTEN SONRA) — bu YÜZDEN paylaşılan bütçe/payload'ı BURADA
        // GÜVENLE serbest bırakmak mümkün (hiçbir worker ARTIK BUNLARA
        // dokunmuyor).
        if (is_bounded) {
            try self.qbeCall(null, "$nox_http_free_bounded_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = worker_payload_text } });
            try self.qbeCall(null, "$nox_http_free_shared_budget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = shared_budget_text } });
        }
        return .{ .text = "0", .qtype = .none };
    }

    // Faz HH.8 (bkz. nox-teknik-spesifikasyon.md §3.66): spawn edilen
    // `ThreadHandle`ları (yalnızca `num_threads - 1` kadarı KULLANILIR,
    // indeks 0 hiç YAZILMAZ) daha SONRA join edebilmek İçin geçici bir
    // dizide TUTULUR — `num_threads` derleme-zamanı sabiti OLMAYABİLDİĞİNDEN
    // (bkz. yukarıdaki `.int` denetimi, `max_connections`in AKSİNE
    // `.int_lit` ZORUNLU DEĞİL) boyut ÇALIŞMA ZAMANINDA hesaplanır.
    const handles_bytes = try self.newTemp();
    try self.qbeOp2Imm(handles_bytes, .l, "mul", num_threads_v.text, 8);
    const handles_arr = try self.newTemp();
    try self.qbeCall(.{ .name = handles_arr, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handles_bytes } });

    const i_slot = try self.newTemp();
    try self.qbeAlloc(i_slot, .eight, 8);
    try self.qbeStoreImmL(1, i_slot);

    const cond_label = try self.newLabel("mc_spawn_cond");
    const body_label = try self.newLabel("mc_spawn_body");
    const end_label = try self.newLabel("mc_spawn_end");

    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const cur = try self.newTemp();
    try self.qbeLoadL(cur, i_slot);
    const cmp = try self.newTemp();
    try self.qbeOp2(cmp, .w, "csltl", cur, num_threads_v.text);
    try self.qbeJnz(cmp, body_label, end_label);
    try self.qbeLabel(body_label);
    const handle_ptr = try self.newTemp();
    const worker_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{worker_name});
    try self.qbeCall(.{ .name = handle_ptr, .ty = .l }, "$nox_thread_spawn", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = worker_sym }, .{ .ty = .l, .text = worker_payload_text }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "0" } });
    const slot_off = try self.newTemp();
    try self.qbeOp2Imm(slot_off, .l, "mul", cur, 8);
    const slot_ptr = try self.newTemp();
    try self.qbeOp2(slot_ptr, .l, "add", handles_arr, slot_off);
    try self.qbeStoreL(handle_ptr, slot_ptr);
    const cur2 = try self.newTemp();
    try self.qbeLoadL(cur2, i_slot);
    const next = try self.newTemp();
    try self.qbeOp2Imm(next, .l, "add", cur2, 1);
    try self.qbeStoreL(next, i_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);

    try self.emitListenServeTail(port_v.text, wrapper_name, max_conn_text, null, null, used_fields.headers, shared_budget_text);

    // Faz HH.8: ÇAĞIRANIN KENDİ payı (yukarıdaki `emitFdServeTail`)
    // BİTTİKTEN SONRA, spawn edilen HER worker'ı join et — `max_
    // connections=0` (sınırsız) olduğunda `emitFdServeTail` ZATEN
    // sonsuza dek döndüğünden buraya HİÇ ULAŞILMAZ (davranış DEĞİŞMEZ);
    // SONLU olduğundaysa bu, `$main`in worker'lar HENÜZ KENDİ
    // bağlantılarını kabul ETMEDEN süreç çıkışına izin verdiği GERÇEK
    // yarış durumunu (bkz. yukarıdaki belge notu) KAPATIR.
    const j_slot = try self.newTemp();
    try self.qbeAlloc(j_slot, .eight, 8);
    try self.qbeStoreImmL(1, j_slot);

    const jcond_label = try self.newLabel("mc_join_cond");
    const jbody_label = try self.newLabel("mc_join_body");
    const jend_label = try self.newLabel("mc_join_end");

    try self.qbeJmp(jcond_label);
    try self.qbeLabel(jcond_label);
    const jcur = try self.newTemp();
    try self.qbeLoadL(jcur, j_slot);
    const jcmp = try self.newTemp();
    try self.qbeOp2(jcmp, .w, "csltl", jcur, num_threads_v.text);
    try self.qbeJnz(jcmp, jbody_label, jend_label);
    try self.qbeLabel(jbody_label);
    const jslot_off = try self.newTemp();
    try self.qbeOp2Imm(jslot_off, .l, "mul", jcur, 8);
    const jslot_ptr = try self.newTemp();
    try self.qbeOp2(jslot_ptr, .l, "add", handles_arr, jslot_off);
    const jhandle = try self.newTemp();
    try self.qbeLoadL(jhandle, jslot_ptr);
    try self.qbeCall(null, "$nox_thread_join", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = jhandle } });
    try self.qbeCall(null, "$nox_thread_destroy", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = jhandle } });
    const jcur2 = try self.newTemp();
    try self.qbeLoadL(jcur2, j_slot);
    const jnext = try self.newTemp();
    try self.qbeOp2Imm(jnext, .l, "add", jcur2, 1);
    try self.qbeStoreL(jnext, j_slot);
    try self.qbeJmp(jcond_label);
    try self.qbeLabel(jend_label);
    try self.qbeCall(null, "$nox_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handles_arr }, .{ .ty = .l, .text = handles_bytes } });

    // Faz MN.11.1: TÜM spawn edilen worker'lar YUKARIDAKİ join döngüsüyle
    // KANITLANMIŞ olarak BİTTİĞİNDEN (payload/bütçeyi BİR DAHA HİÇBİR
    // worker OKUMAYACAĞINDAN) paylaşılan bütçe/payload'ı BURADA GÜVENLE
    // serbest bırakabiliriz.
    if (is_bounded) {
        try self.qbeCall(null, "$nox_http_free_bounded_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = worker_payload_text } });
        try self.qbeCall(null, "$nox_http_free_shared_budget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = shared_budget_text } });
    }

    return .{ .text = "0", .qtype = .none };
}

/// `nox_thread_spawn`ın ÇAĞIRDIĞI, `nox.http.serve_multicore` çağrı
/// sitesi başına üretilen bir ÇOCUK İŞ PARÇACIĞI girişi — Faz DD.1
/// (bkz. nox-teknik-spesifikasyon.md §3.60). **Faz MN.11'DEN İTİBAREN**
/// payload ÇIPLAK bir `port` (ya da TLS İçİn `{port, tls_ctx}`) — HER
/// worker BURADA KENDİ BAĞIMSIZ `SO_REUSEPORT` soketini TAZE açar
/// (bkz. `emitListenServeTail`). `genThreadStartWrapper`nin KANITLANMIŞ
/// düşük-seviye şekliyle (`%argp`den `RT_PARAM` + payload YÜKLEMESİ)
/// BİREBİR AYNI iskelet, AMA gövde gerçek bir Nox fonksiyonu
/// ÇAĞIRMAK yerine `emitFdServeTail`i çağırır — bu worker'ın ARKASINDA
/// yazılmış bir Nox `entry` fonksiyonu YOKTUR, TAMAMEN sentezlenir
/// (`genHttpServeWrapper`nin `HandlerFn` sarmalayıcısını
/// sentezlemesiyle AYNI teknik).
pub fn genHttpServeMulticoreWorker(self: *Codegen, spec: HttpServeMulticoreWorkerSpec) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    // Bkz. `Codegen.mod_cache`nin belge notu: slot ADLARI ("%t0", ...)
    // SADECE bir FONKSİYON içinde benzersizdir (`temp_counter` HER
    // fonksiyon BAŞLANGICINDA sıfırlanır, tıpkı BURADA olduğu gibi) —
    // BİR ÖNCEKİ fonksiyondan kalan bir önbellek girdisi, BU fonksiyonda
    // AYNI ADI TAŞIYAN TAMAMEN FARKLI bir slotla YANLIŞLIKLA eşleşebilir
    // (çapraz-fonksiyon çakışması). Bu YÜZDEN HER fonksiyon-benzeri
    // codegen girişinde (`temp_counter`/`label_counter` İLE AYNI
    // noktalarda) TAMAMEN BOŞALTILIR.
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const spec_name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.name});
    try self.qbeFuncHeaderStart(.l, spec_name_sym);
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeLoadL(RT_PARAM, "%argp");
    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // BU worker KENDİ bağımsız `RuntimeState`ine (bkz. `childThreadMain`,
    // `runtime/async_rt/thread_bridge.zig`) sahiptir — `globals_block`u
    // BAŞTA `null`dır, KENDİ taze kopyasını burada ilklendirir (worker'LAR
    // ARASI PAYLAŞIM YOK, bilinçli v1 kapsamı). **Deinit ÇAĞRILMAZ**: bu
    // worker `emitFdServeTail`in accept döngüsünde SONSUZA dek çalışır
    // (`max_connections=0` varsayılanında `ret 0` erişilemez), `rt`nin
    // KENDİSİ de zaten HİÇ deinit edilmiyor.
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_init_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }
    const payload_addr = try self.newTemp();
    try self.qbeOp2Imm(payload_addr, .l, "add", "%argp", 8);

    // Faz MN.11: `spec.tls` İSE `payload_addr`nin İÇERDİĞİ DEĞER ÇIPLAK
    // bir `port` DEĞİL, `nox_http_make_port_tls_payload`nin döndürdüğü
    // bir `PortTlsPayload*`dir (bkz. `genHttpServeMulticoreGeneric`) — bu
    // İŞARETÇİ ÜZERİNDEN İKİ ALAN (`port` @ ofset 0, `tls_ctx` @ ofset 8)
    // AYRICA YÜKLENİR. HER worker BU `port`u `nox_http_server_listen_
    // multicore_worker(_tls)`e (bkz. `emitListenServeTail`) geçirip KENDİ
    // BAĞIMSIZ `SO_REUSEPORT` soketini BURADA TAZE açar — ESKİDEN olduğu
    // gibi ÖNCEDEN hesaplanmış PAYLAŞILAN bir fd'yi SARMAZ.
    //
    // Faz MN.11.1: `spec.bounded` İSE (TLS OLSUN OLMASIN) payload ÜÇÜNCÜ
    // bir şekildedir — `nox_http_make_bounded_payload`nin döndürdüğü bir
    // `MulticoreBoundedPayload*` (`port` @ ofset 0, `tls_ctx` @ ofset 8,
    // `budget` @ ofset 16) — bkz. `SharedServeBudget`nin runtime tarafındaki
    // belge notu.
    var port: []const u8 = undefined;
    var tls_ctx_text: ?[]const u8 = null;
    var shared_budget_text: []const u8 = "0";
    if (spec.bounded) {
        const payload_ptr = try self.newTemp();
        try self.qbeLoadL(payload_ptr, payload_addr);
        const port_t = try self.newTemp();
        try self.qbeLoadL(port_t, payload_ptr);
        const ctx_addr = try self.newTemp();
        try self.qbeOp2Imm(ctx_addr, .l, "add", payload_ptr, 8);
        const ctx_t = try self.newTemp();
        try self.qbeLoadL(ctx_t, ctx_addr);
        const budget_addr = try self.newTemp();
        try self.qbeOp2Imm(budget_addr, .l, "add", payload_ptr, 16);
        const budget_t = try self.newTemp();
        try self.qbeLoadL(budget_t, budget_addr);
        port = port_t;
        if (spec.tls) tls_ctx_text = ctx_t;
        shared_budget_text = budget_t;
    } else if (spec.tls) {
        const payload_ptr = try self.newTemp();
        try self.qbeLoadL(payload_ptr, payload_addr);
        const port_t = try self.newTemp();
        try self.qbeLoadL(port_t, payload_ptr);
        const ctx_addr = try self.newTemp();
        try self.qbeOp2Imm(ctx_addr, .l, "add", payload_ptr, 8);
        const ctx_t = try self.newTemp();
        try self.qbeLoadL(ctx_t, ctx_addr);
        port = port_t;
        tls_ctx_text = ctx_t;
    } else {
        const port_t = try self.newTemp();
        try self.qbeLoadL(port_t, payload_addr);
        port = port_t;
    }

    try self.emitListenServeTail(port, spec.wrapper_name, spec.max_conn_text, tls_ctx_text, spec.ws_wrapper_name, spec.needs_headers, shared_budget_text);

    try self.qbeRet("0");
    try self.qbeFuncEnd();
}

/// `nox_http_serve_raw`nin (bkz. runtime/stdlib_shims/http_server.zig'in
/// `HandlerFn`i, `fn(?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque`)
/// bağlantı başına ÇAĞIRDIĞI, `nox.http.serve` çağrı sitesi başına
/// üretilen C-ABI sarmalayıcı — bkz. `HttpServeWrapperSpec`in belge notu.
/// `%ctx` (`rt`nin KENDİSİ, `genHttpServe`nin `handler_ctx` olarak
/// geçirdiği) ve `%req` (ham istek tutamacı) alır: `req_class`ın (ör.
/// `HttpRequest`) alanlarını ham `nox_http_request_*` erişimcileriyle
/// doldurup bir örnek İNŞA EDER (`genConstructFromValues`), kullanıcının
/// `handler_fn`ini çağırır, dönen `resp_class` (ör. `HttpResponse`)
/// örneğinden `status`/`body`/`headers`i okuyup (`genFieldReadFromValue`)
/// `nox_http_response_new`e geçirir (BU çağrı KENDİ kopyasını
/// tuttuğundan, bkz. `runtime/stdlib_shims/http_server.zig`nin
/// `nox_http_response_new`ı — `body`/`headers`i `gpa.dupe`/`copyHeaders`
/// ile KOPYALAR), SONRA hem istek hem yanıt örneğini TAMAMEN serbest
/// bırakır.
///
/// **Bilinçli v0.1 sınırlaması (`genSpawnWrapper` İLE AYNI gerekçe):**
/// `handler_fn` içinde bir istisna oluşup YAKALANMAZSA, bu BURADA
/// denetlenmez/temizlenmez.
pub fn genHttpServeWrapper(self: *Codegen, spec: HttpServeWrapperSpec) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    // Bkz. `Codegen.mod_cache`nin belge notu: slot ADLARI ("%t0", ...)
    // SADECE bir FONKSİYON içinde benzersizdir (`temp_counter` HER
    // fonksiyon BAŞLANGICINDA sıfırlanır, tıpkı BURADA olduğu gibi) —
    // BİR ÖNCEKİ fonksiyondan kalan bir önbellek girdisi, BU fonksiyonda
    // AYNI ADI TAŞIYAN TAMAMEN FARKLI bir slotla YANLIŞLIKLA eşleşebilir
    // (çapraz-fonksiyon çakışması). Bu YÜZDEN HER fonksiyon-benzeri
    // codegen girişinde (`temp_counter`/`label_counter` İLE AYNI
    // noktalarda) TAMAMEN BOŞALTILIR.
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const spec_name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.name});
    try self.qbeFuncHeaderStart(.l, spec_name_sym);
    try self.qbeFuncParam(.l, "%ctx", true);
    try self.qbeFuncParam(.l, "%req", false);
    try self.qbeFuncHeaderEnd();
    try self.qbeOp1(RT_PARAM, .l, "copy", "%ctx");

    const req_cinfo = self.classes.get(spec.req_class) orelse return error.Unsupported;
    const req_values = try self.allocator.alloc(Value, req_cinfo.fields.items.len);
    for (req_cinfo.fields.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "method")) {
            // Faz HH.4: `handle` bu alanı HİÇ okumuyorsa, pahalı
            // `nox_http_request_method` (retain — bkz. HH.2) YERİNE
            // ucuz, PINNED-refcount'lu boş bir literal üretilir.
            req_values[i] = if (spec.used_fields.method) blk: {
                const t = try self.newTemp();
                try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_http_request_method", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%req" } });
                break :blk .{ .text = t, .qtype = .l, .heap = .str };
            } else try self.emitStringLiteral("");
        } else if (std.mem.eql(u8, f.name, "target")) {
            req_values[i] = if (spec.used_fields.target) blk: {
                const t = try self.newTemp();
                try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_http_request_target", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%req" } });
                break :blk .{ .text = t, .qtype = .l, .heap = .str };
            } else try self.emitStringLiteral("");
        } else if (std.mem.eql(u8, f.name, "body")) {
            req_values[i] = if (spec.used_fields.body) blk: {
                const t = try self.newTemp();
                try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_http_request_body", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%req" } });
                break :blk .{ .text = t, .qtype = .l, .heap = .str };
            } else try self.emitStringLiteral("");
        } else if (std.mem.eql(u8, f.name, "headers")) {
            // Faz HH.4: `handle` `req.headers`e HİÇ dokunmuyorsa,
            // header'ları PARSE EDİP HER birini `retain` eden (bkz.
            // HH.2) `nox_http_request_headers` YERİNE DOĞRUDAN boş bir
            // `nox_dict_new` çağrısı üretilir — O(header sayısı) işi
            // TAMAMEN atlanır.
            const t = try self.newTemp();
            if (spec.used_fields.headers) {
                try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_http_request_headers", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%req" } });
            } else {
                try self.qbeCall(.{ .name = t, .ty = .l }, "$nox_dict_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .w, .text = "1" } });
            }
            req_values[i] = .{ .text = t, .qtype = .l, .heap = .dict, .dict_info = f.info.dict_info };
        } else {
            return error.Unsupported;
        }
    }
    const req_obj = try self.genConstructFromValues(spec.req_class, req_cinfo, req_values, null);
    // `req_values` — `releaseTemporaryArgs`in gerekçesiyle AYNI (bkz.
    // onun belge notu): her biri TAZE bir `nox_http_request_*` çağrısının
    // SONUCUdur (KENDİ releaser'ı yok). `__init__`in `self.x = x` alan
    // ataması heap-yönetimli olanları (str VE Faz FF.3'ten beri dict)
    // ZATEN retain ETTİĞİNDEN (bkz. `genAssign`in `.attribute` dalı),
    // burada BİR KEZ daha serbest bırakmak DENGELER (aksi halde
    // sızarlar) — `isHeapManaged` kontrolü, retain EDİLMEYEN (heap-
    // yönetimli OLMAYAN) alanları burada doğal olarak ELER.
    for (req_values) |v| {
        if (isHeapManaged(v.heap)) {
            try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
        }
    }

    const resp_obj_text = try self.newTemp();
    const handler_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.handler_fn});
    try self.qbeCall(.{ .name = resp_obj_text, .ty = .l }, handler_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = req_obj.text } });
    const resp_obj: Value = .{ .text = resp_obj_text, .qtype = .l, .heap = .class, .class_name = spec.resp_class };

    try self.releaseValueIfSet(req_obj.text, req_obj.heap, req_obj.elem_qtype, req_obj.class_name, req_obj.elem_heap_info, req_obj.dict_info);

    const status = try self.genFieldReadFromValue(resp_obj, "status");
    const body = try self.genFieldReadFromValue(resp_obj, "body");
    const headers = try self.genFieldReadFromValue(resp_obj, "headers");

    const raw_resp = try self.newTemp();
    try self.qbeCall(.{ .name = raw_resp, .ty = .l }, "$nox_http_response_new", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = status.text }, .{ .ty = .l, .text = body.text }, .{ .ty = .l, .text = headers.text } });

    try self.releaseValueIfSet(resp_obj.text, resp_obj.heap, resp_obj.elem_qtype, resp_obj.class_name, resp_obj.elem_heap_info, resp_obj.dict_info);

    try self.qbeRet(raw_resp);
    try self.qbeFuncEnd();
}

/// `nox_http_serve_ws_raw`nin (bkz. `websocket_server.zig`nin `WsHandlerFn`i,
/// `fn(?*anyopaque, ?*anyopaque) callconv(.c) void`) Upgrade edilmiş HER
/// bağlantı İçin ÇAĞIRDIĞI, `nox.http.serve_ws*` çağrı sitesi başına
/// üretilen C-ABI sarmalayıcı — bkz. `HttpServeWsWrapperSpec`in belge
/// notu. `%ctx` (`rt`) VE `%conn` (ham `WsServerConn*`) alır: `conn_class`ın
/// (ör. `WebSocketServerConn`) TEK `handle: ptr` alanını `%conn`DAN
/// DOĞRUDAN doldurup bir örnek İNŞA EDER, kullanıcının `ws_handler_fn`ini
/// (dönüşü `None`, checker TARAFINDAN ZATEN doğrulandı — bkz. `validateWsHandler`)
/// çağırır, örneği serbest bırakır. `genHttpServeWrapper`nin AKSİNE
/// üretilecek/serbest BIRAKILACAK bir yanıt nesnesi YOKTUR (bir WS
/// oturumunun "yanıtı" yoktur).
pub fn genHttpServeWsWrapper(self: *Codegen, spec: types.HttpServeWsWrapperSpec) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const spec_name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.name});
    try self.qbeFuncHeaderStart(.l, spec_name_sym);
    try self.qbeFuncParam(.l, "%ctx", true);
    try self.qbeFuncParam(.l, "%conn", false);
    try self.qbeFuncHeaderEnd();
    try self.qbeOp1(RT_PARAM, .l, "copy", "%ctx");

    const conn_cinfo = self.classes.get(spec.conn_class) orelse return error.Unsupported;
    const conn_values = try self.allocator.alloc(Value, conn_cinfo.fields.items.len);
    for (conn_cinfo.fields.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "handle")) {
            conn_values[i] = .{ .text = "%conn", .qtype = .l, .heap = .none };
        } else {
            return error.Unsupported;
        }
    }
    const conn_obj = try self.genConstructFromValues(spec.conn_class, conn_cinfo, conn_values, null);

    const ws_handler_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.ws_handler_fn});
    try self.qbeCall(null, ws_handler_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = conn_obj.text } });

    try self.releaseValueIfSet(conn_obj.text, conn_obj.heap, conn_obj.elem_qtype, conn_obj.class_name, conn_obj.elem_heap_info, conn_obj.dict_info);

    try self.qbeRet("0");
    try self.qbeFuncEnd();
}

/// Faz "sunucu-tarafı TLS + WebSocket Upgrade" (bkz. plan dosyası §6) —
/// `handle`in (bkz. `genHttpServe`nin AYNI doğrulaması) VE isteğe bağlı
/// olarak `ws_handle`nin ÇÖZÜMLENMESİNİ, `HttpServeWrapperSpec`/
/// `HttpServeWsWrapperSpec` KAYDINI paylaşan yardımcı — `genHttpServe*
/// Generic`nin ÜÇÜ TARAFINDAN da çağrılır.
pub fn registerHttpHandlers(self: *Codegen, handle_name: []const u8, ws_handle_name: ?[]const u8) CodegenError!struct {
    wrapper_name: []const u8,
    ws_wrapper_name: ?[]const u8,
    needs_headers: bool,
} {
    const sig = self.functions.get(handle_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;
    if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
    if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
    const req_class = sig.params[0].class_name.?;
    const resp_class = sig.ret.class_name.?;

    const used_fields = self.computeUsedFieldsFor(handle_name);
    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = used_fields });

    var ws_wrapper_name: ?[]const u8 = null;
    if (ws_handle_name) |wsh| {
        const ws_sig = self.functions.get(wsh) orelse return error.Unsupported;
        if (ws_sig.params.len != 1) return error.Unsupported;
        if (ws_sig.params[0].heap != .class or ws_sig.params[0].class_name == null) return error.Unsupported;
        const conn_class = ws_sig.params[0].class_name.?;
        const name = try std.fmt.allocPrint(self.allocator, "http_serve_ws_wrap_{d}", .{self.http_serve_ws_wrapper_counter});
        self.http_serve_ws_wrapper_counter += 1;
        try self.http_serve_ws_wrappers.append(self.allocator, .{ .name = name, .ws_handler_fn = wsh, .conn_class = conn_class });
        ws_wrapper_name = name;
    }

    return .{ .wrapper_name = wrapper_name, .ws_wrapper_name = ws_wrapper_name, .needs_headers = used_fields.headers };
}

/// `nox.http.serve_tls`/`serve_ws`/`serve_ws_tls` — `genHttpServe`nin
/// PARAMETRİK genellemesi (bkz. plan dosyası §6). Argüman SIRASI
/// checker'ın `tryResolveHttpServeGeneric`sinin AYNI formülüne uyar:
/// `[port, handle, (ws_handle varsa), (cert_path, key_path varsa),
/// (max_connections isteğe bağlı)]`. Var OLAN `genHttpServe`ye (`serve`nin
/// KENDİSİ) DOKUNULMADI — bu, YALNIZCA `_tls`/`_ws`/`_ws_tls` uzantılı 3
/// YENİ isim İçİn kullanılır.
pub fn genHttpServeGeneric(self: *Codegen, c: ast.Call, want_tls: bool, want_ws: bool) CodegenError!Value {
    var idx: usize = 0;
    const port_v0 = try self.genExpr(c.args[idx]);
    try self.checkNoLowlevelEscape(port_v0);
    const port_v = try self.convert(port_v0, .l);
    try self.releaseIfTemporary(c.args[idx], port_v0);
    idx += 1;

    const handle_name = switch (c.args[idx]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    idx += 1;

    var ws_handle_name: ?[]const u8 = null;
    if (want_ws) {
        ws_handle_name = switch (c.args[idx]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        idx += 1;
    }

    var cert_v: Value = undefined;
    var key_v: Value = undefined;
    if (want_tls) {
        const cert_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(cert_v0);
        cert_v = try self.convert(cert_v0, .l);
        try self.releaseIfTemporary(c.args[idx], cert_v0);
        idx += 1;
        const key_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(key_v0);
        key_v = try self.convert(key_v0, .l);
        try self.releaseIfTemporary(c.args[idx], key_v0);
        idx += 1;
    }

    var max_conn_text: []const u8 = "0";
    if (c.args.len > idx) {
        const mc_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(mc_v0);
        const mc_v = try self.convert(mc_v0, .l);
        try self.releaseIfTemporary(c.args[idx], mc_v0);
        max_conn_text = mc_v.text;
        idx += 1;
    }

    const server = try self.newTemp();
    if (want_tls) {
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_listen_tls", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_v.text }, .{ .ty = .l, .text = cert_v.text }, .{ .ty = .l, .text = key_v.text } });
    } else {
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_listen", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_v.text } });
    }

    const handlers = try self.registerHttpHandlers(handle_name, ws_handle_name);
    try self.emitServeAndClose(server, handlers.wrapper_name, max_conn_text, handlers.ws_wrapper_name, handlers.needs_headers, "0");
    return .{ .text = "0", .qtype = .none };
}

/// `nox.http.serve_fd_tls`/`serve_fd_ws`/`serve_fd_ws_tls` — `genHttpServeFd`nin
/// PARAMETRİK genellemesi. `want_tls` İSE `nox_http_server_from_fd_tls`
/// (paylaşılan/dıştan verilen bir bağlam) DEĞİL, `nox_http_server_from_
/// fd_tls_owned`i (cert/key'DEN kendi bağlamını YARATIP SAHİPLENİR)
/// çağırır — `serve_fd*`nin `fd`si ÇAĞIRANIN mülkiyetinde KALDIĞINDAN
/// (bkz. `nox_http_server_from_fd`in belge notu) TLS bağlamının kaynağı
/// BAŞKA bir yerde (multicore'un `nox_http_listen_fd_tls`i GİBİ)
/// PAYLAŞILMAZ, bu ÇAĞRI SİTESİ TARAFINDAN taze YARATILIR.
pub fn genHttpServeFdGeneric(self: *Codegen, c: ast.Call, want_tls: bool, want_ws: bool) CodegenError!Value {
    var idx: usize = 0;
    const fd_v0 = try self.genExpr(c.args[idx]);
    try self.checkNoLowlevelEscape(fd_v0);
    const fd_v = try self.convert(fd_v0, .l);
    try self.releaseIfTemporary(c.args[idx], fd_v0);
    idx += 1;

    const handle_name = switch (c.args[idx]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    idx += 1;

    var ws_handle_name: ?[]const u8 = null;
    if (want_ws) {
        ws_handle_name = switch (c.args[idx]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        idx += 1;
    }

    var cert_v: Value = undefined;
    var key_v: Value = undefined;
    if (want_tls) {
        const cert_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(cert_v0);
        cert_v = try self.convert(cert_v0, .l);
        try self.releaseIfTemporary(c.args[idx], cert_v0);
        idx += 1;
        const key_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(key_v0);
        key_v = try self.convert(key_v0, .l);
        try self.releaseIfTemporary(c.args[idx], key_v0);
        idx += 1;
    }

    var max_conn_text: []const u8 = "0";
    if (c.args.len > idx) {
        const mc_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(mc_v0);
        const mc_v = try self.convert(mc_v0, .l);
        try self.releaseIfTemporary(c.args[idx], mc_v0);
        max_conn_text = mc_v.text;
        idx += 1;
    }

    const handlers = try self.registerHttpHandlers(handle_name, ws_handle_name);

    if (want_tls) {
        const server = try self.newTemp();
        try self.qbeCall(.{ .name = server, .ty = .l }, "$nox_http_server_from_fd_tls_owned", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = fd_v.text }, .{ .ty = .l, .text = cert_v.text }, .{ .ty = .l, .text = key_v.text } });
        try self.emitServeAndClose(server, handlers.wrapper_name, max_conn_text, handlers.ws_wrapper_name, handlers.needs_headers, "0");
    } else {
        try self.emitFdServeTail(fd_v.text, handlers.wrapper_name, max_conn_text, null, handlers.ws_wrapper_name, handlers.needs_headers);
    }
    return .{ .text = "0", .qtype = .none };
}

/// `nox.http.serve_multicore_tls`/`serve_multicore_ws`/`serve_multicore_
/// ws_tls` — `genHttpServeMulticore`nin PARAMETRİK genellemesi. **Faz
/// MN.11'DEN İTİBAREN**: `want_tls` İSE `SSL_CTX*` (`nox_http_build_
/// tls_ctx`) TEK BİR KEZ BURADA İnşa edilir (worker başına TEKRARLANMAZ,
/// OpenSSL'in KENDİ, belgelenmiş iş-parçacığı-güvenliği sözleşmesi
/// SAYESİNDE TÜM worker'lar ARASINDA GERÇEKTEN paylaşılır) VE `{port,
/// tls_ctx}` (`nox_http_make_port_tls_payload`) TEK bir payload OLARAK
/// paketlenip HER worker'a geçirilir — HER worker (bkz. `genHttpServeMulticoreWorker`nin
/// `spec.tls` dalı) BU payload'DAN `port`/`tls_ctx`yi AYRI AYRI ÇIKARIP
/// `nox_http_server_listen_multicore_worker_tls`i (bkz. `emitListenServeTail`)
/// ÇAĞIRARAK KENDİ BAĞIMSIZ `SO_REUSEPORT` soketini TAZE açar (paylaşılan
/// TEK bir fd ARTIK YOK — standalone bir C deneyiyle kanıtlanmış OS-
/// seviyesi thundering-herd maliyetinin düzeltmesi, bkz. proje planı).
/// ÇAĞIRANIN KENDİ payı (aşağıda) İSE `port_v.text`/`tls_ctx_v`yi
/// ZATEN YEREL Zig değişkenleri OLARAK TUTTUĞUNDAN payload'dan HİÇ
/// ÇIKARMAZ. Paylaşılan `SSL_CTX*`, TÜM worker'lar JOIN EDİLDİKTEN
/// SONRA (bkz. `nox_tls_ctx_free`nin belge notu — ERKEN serbest bırakmak
/// bir kullanım-sonrası-serbest-bırakma YARIŞI olurdu) TEK bir yerden
/// serbest bırakılır.
pub fn genHttpServeMulticoreGeneric(self: *Codegen, c: ast.Call, want_tls: bool, want_ws: bool) CodegenError!Value {
    var idx: usize = 0;
    const port_v0 = try self.genExpr(c.args[idx]);
    try self.checkNoLowlevelEscape(port_v0);
    const port_v = try self.convert(port_v0, .l);
    try self.releaseIfTemporary(c.args[idx], port_v0);
    idx += 1;

    const handle_name = switch (c.args[idx]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    idx += 1;

    const num_threads_v0 = try self.genExpr(c.args[idx]);
    try self.checkNoLowlevelEscape(num_threads_v0);
    const num_threads_v = try self.convert(num_threads_v0, .l);
    try self.releaseIfTemporary(c.args[idx], num_threads_v0);
    idx += 1;

    var ws_handle_name: ?[]const u8 = null;
    if (want_ws) {
        ws_handle_name = switch (c.args[idx]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        idx += 1;
    }

    var cert_v: Value = undefined;
    var key_v: Value = undefined;
    if (want_tls) {
        const cert_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(cert_v0);
        cert_v = try self.convert(cert_v0, .l);
        try self.releaseIfTemporary(c.args[idx], cert_v0);
        idx += 1;
        const key_v0 = try self.genExpr(c.args[idx]);
        try self.checkNoLowlevelEscape(key_v0);
        key_v = try self.convert(key_v0, .l);
        try self.releaseIfTemporary(c.args[idx], key_v0);
        idx += 1;
    }

    // Checker ZATEN `.int_lit` olduğunu garanti etti (bkz.
    // `tryResolveHttpServeGeneric`nin belge notu) — `genHttpServeMulticore`nin
    // AYNI derleme-zamanı metin sabiti taktiği.
    var max_conn_text: []const u8 = "0";
    var is_bounded = false;
    if (c.args.len > idx) {
        max_conn_text = try std.fmt.allocPrint(self.allocator, "{d}", .{c.args[idx].int_lit});
        is_bounded = c.args[idx].int_lit > 0;
        idx += 1;
    }

    // Faz MN.11 (bkz. `genHttpServeMulticore`nin AYNI belge notu): TEK
    // paylaşılan bir `fd` ARTIK YOK. `want_tls` İSE `SSL_CTX*` (cert/
    // anahtar dosya ayrıştırması İçEREN PAHALI adım) TEK BİR KEZ BURADA
    // İnşa edilir (`nox_http_build_tls_ctx`) — OpenSSL'in KENDİ, belgelenmiş
    // iş-parçacığı-güvenliği sözleşmesi SAYESİNDE TÜM worker'lar ARASINDA
    // GERÇEKTEN paylaşılır; payload SADECE `{port, tls_ctx}` (`nox_http_
    // make_port_tls_payload`, `FdTlsPayload`İLE AYNI ömür/şekil, SADECE
    // `fd` alanı `port` OLUR). `want_tls` DEĞİLSE payload SADECE `port_v.
    // text`in KENDİSİ (yeni bir tahsis GEREKMEZ).
    //
    // Faz MN.11.1: `is_bounded` İSE (bkz. `genHttpServeMulticore`nin AYNI
    // mekanizması) BUNLARIN İKİSİNİN de YERİNE — TLS olsun olmasın — TEK
    // bir `MulticoreBoundedPayload*` (`nox_http_make_bounded_payload`)
    // KULLANILIR, PAYLAŞILAN bir `SharedServeBudget` İLE BİRLİKTE.
    var tls_ctx_v: []const u8 = undefined;
    var shared_budget_text: []const u8 = "0";
    var payload: []const u8 = port_v.text;
    if (want_tls) {
        tls_ctx_v = try self.newTemp();
        try self.qbeCall(.{ .name = tls_ctx_v, .ty = .l }, "$nox_http_build_tls_ctx", &.{ .{ .ty = .l, .text = cert_v.text }, .{ .ty = .l, .text = key_v.text } });
    }
    if (is_bounded) {
        const budget_v = try self.newTemp();
        try self.qbeCall(.{ .name = budget_v, .ty = .l }, "$nox_http_make_shared_budget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = max_conn_text }, .{ .ty = .l, .text = num_threads_v.text } });
        shared_budget_text = budget_v;
        const bounded_payload = try self.newTemp();
        try self.qbeCall(.{ .name = bounded_payload, .ty = .l }, "$nox_http_make_bounded_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_v.text }, .{ .ty = .l, .text = if (want_tls) tls_ctx_v else "0" }, .{ .ty = .l, .text = budget_v } });
        payload = bounded_payload;
    } else if (want_tls) {
        const port_tls_payload = try self.newTemp();
        try self.qbeCall(.{ .name = port_tls_payload, .ty = .l }, "$nox_http_make_port_tls_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = port_v.text }, .{ .ty = .l, .text = tls_ctx_v } });
        payload = port_tls_payload;
    }

    const handlers = try self.registerHttpHandlers(handle_name, ws_handle_name);

    const worker_name = try std.fmt.allocPrint(self.allocator, "http_serve_mc_worker_{d}", .{self.http_serve_multicore_worker_counter});
    self.http_serve_multicore_worker_counter += 1;
    try self.http_serve_multicore_workers.append(self.allocator, .{ .name = worker_name, .wrapper_name = handlers.wrapper_name, .max_conn_text = max_conn_text, .ws_wrapper_name = handlers.ws_wrapper_name, .tls = want_tls, .needs_headers = handlers.needs_headers, .bounded = is_bounded });

    // Faz MN.7b (bkz. `genHttpServeMulticore`nin AYNI belge notu):
    // `payload` BURADA da (`want_tls` İSE `PortTlsPayload*`, DEĞİLSE
    // ÇIPLAK `port`) `genHttpServeMulticoreWorker`nin `spec.tls`-güdümlü
    // `%argp+8` yorumuyla BİREBİR UYUMLU olduğundan, AYNI ÜRETİLEN worker
    // fonksiyonu DEĞİŞİKLİKSİZ `nox_pool_serve`nin `entry_fn`i OLARAK
    // kullanılabilir.
    if (self.backend == .llvm) {
        const worker_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{worker_name});
        const rc = try self.newTemp();
        try self.qbeCall(.{ .name = rc, .ty = .w }, "$nox_pool_serve", &.{
            .{ .ty = .l, .text = RT_PARAM },
            .{ .ty = .l, .text = num_threads_v.text },
            .{ .ty = .l, .text = worker_sym },
            .{ .ty = .l, .text = payload },
        });
        // Faz MN.11.1 (bkz. `genHttpServeMulticore`nin AYNI belge notu):
        // `$nox_pool_serve` SENKRON döner.
        if (is_bounded) {
            try self.qbeCall(null, "$nox_http_free_bounded_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = payload } });
            try self.qbeCall(null, "$nox_http_free_shared_budget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = shared_budget_text } });
        }
        return .{ .text = "0", .qtype = .none };
    }

    // Faz HH.8 (bkz. `genHttpServeMulticore`nin AYNI belge notu): spawn
    // edilen `ThreadHandle`ları daha SONRA join edebilmek İçin geçici bir
    // dizide TUTULUR.
    const handles_bytes = try self.newTemp();
    try self.qbeOp2Imm(handles_bytes, .l, "mul", num_threads_v.text, 8);
    const handles_arr = try self.newTemp();
    try self.qbeCall(.{ .name = handles_arr, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handles_bytes } });

    const i_slot = try self.newTemp();
    try self.qbeAlloc(i_slot, .eight, 8);
    try self.qbeStoreImmL(1, i_slot);

    const cond_label = try self.newLabel("mc_spawn_cond");
    const body_label = try self.newLabel("mc_spawn_body");
    const end_label = try self.newLabel("mc_spawn_end");

    try self.qbeJmp(cond_label);
    try self.qbeLabel(cond_label);
    const cur = try self.newTemp();
    try self.qbeLoadL(cur, i_slot);
    const cmp = try self.newTemp();
    try self.qbeOp2(cmp, .w, "csltl", cur, num_threads_v.text);
    try self.qbeJnz(cmp, body_label, end_label);
    try self.qbeLabel(body_label);
    const handle_ptr = try self.newTemp();
    const worker_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{worker_name});
    try self.qbeCall(.{ .name = handle_ptr, .ty = .l }, "$nox_thread_spawn", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = worker_sym }, .{ .ty = .l, .text = payload }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "0" } });
    const slot_off = try self.newTemp();
    try self.qbeOp2Imm(slot_off, .l, "mul", cur, 8);
    const slot_ptr = try self.newTemp();
    try self.qbeOp2(slot_ptr, .l, "add", handles_arr, slot_off);
    try self.qbeStoreL(handle_ptr, slot_ptr);
    const cur2 = try self.newTemp();
    try self.qbeLoadL(cur2, i_slot);
    const next = try self.newTemp();
    try self.qbeOp2Imm(next, .l, "add", cur2, 1);
    try self.qbeStoreL(next, i_slot);
    try self.qbeJmp(cond_label);
    try self.qbeLabel(end_label);

    // Faz MN.11: ÇAĞIRANIN KENDİ payı — `port_v.text`/`tls_ctx_v` ZATEN
    // YEREL Zig değişkenleri OLARAK ELİMİZDE (yukarıda hesaplandı), bir
    // heap payload'dan (`FdTlsPayload*`) ÇIKARMAYA GEREK YOK — `emitFdServeTail`
    // YERİNE `emitListenServeTail` (KENDİ BAĞIMSIZ `SO_REUSEPORT` soketini
    // TAZE açar).
    const tls_ctx_text: ?[]const u8 = if (want_tls) tls_ctx_v else null;
    try self.emitListenServeTail(port_v.text, handlers.wrapper_name, max_conn_text, tls_ctx_text, handlers.ws_wrapper_name, handlers.needs_headers, shared_budget_text);

    // Faz HH.8: ÇAĞIRANIN KENDİ payı BİTTİKTEN SONRA, spawn edilen HER
    // worker'ı join et (bkz. `genHttpServeMulticore`nin AYNI gerekçesi).
    const j_slot = try self.newTemp();
    try self.qbeAlloc(j_slot, .eight, 8);
    try self.qbeStoreImmL(1, j_slot);

    const jcond_label = try self.newLabel("mc_join_cond");
    const jbody_label = try self.newLabel("mc_join_body");
    const jend_label = try self.newLabel("mc_join_end");

    try self.qbeJmp(jcond_label);
    try self.qbeLabel(jcond_label);
    const jcur = try self.newTemp();
    try self.qbeLoadL(jcur, j_slot);
    const jcmp = try self.newTemp();
    try self.qbeOp2(jcmp, .w, "csltl", jcur, num_threads_v.text);
    try self.qbeJnz(jcmp, jbody_label, jend_label);
    try self.qbeLabel(jbody_label);
    const jslot_off = try self.newTemp();
    try self.qbeOp2Imm(jslot_off, .l, "mul", jcur, 8);
    const jslot_ptr = try self.newTemp();
    try self.qbeOp2(jslot_ptr, .l, "add", handles_arr, jslot_off);
    const jhandle = try self.newTemp();
    try self.qbeLoadL(jhandle, jslot_ptr);
    try self.qbeCall(null, "$nox_thread_join", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = jhandle } });
    try self.qbeCall(null, "$nox_thread_destroy", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = jhandle } });
    const jcur2 = try self.newTemp();
    try self.qbeLoadL(jcur2, j_slot);
    const jnext = try self.newTemp();
    try self.qbeOp2Imm(jnext, .l, "add", jcur2, 1);
    try self.qbeStoreL(jnext, j_slot);
    try self.qbeJmp(jcond_label);
    try self.qbeLabel(jend_label);
    try self.qbeCall(null, "$nox_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handles_arr }, .{ .ty = .l, .text = handles_bytes } });

    // Faz MN.11.1 (bkz. `genHttpServeMulticore`nin AYNI belge notu):
    // TÜM spawn edilen worker'lar YUKARIDAKİ join döngüsüyle bitti.
    if (is_bounded) {
        try self.qbeCall(null, "$nox_http_free_bounded_payload", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = payload } });
        try self.qbeCall(null, "$nox_http_free_shared_budget", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = shared_budget_text } });
    }

    if (tls_ctx_text) |ctx| {
        try self.qbeCall(null, "$nox_tls_ctx_free", &.{.{ .ty = .l, .text = ctx }});
    }

    return .{ .text = "0", .qtype = .none };
}
