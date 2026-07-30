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
    try self.out.writer.print("    {s} =l call $nox_http_server_listen(l {s}, l {s})\n", .{ server, RT_PARAM, port_v.text });

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = self.computeUsedFieldsFor(handle_name) });

    try self.out.writer.print("    call $nox_http_serve_raw(l {s}, l {s}, l ${s}, l {s}, l {s})\n", .{ RT_PARAM, server, wrapper_name, RT_PARAM, max_conn_text });
    try self.out.writer.print("    call $nox_http_server_close(l {s}, l {s})\n", .{ RT_PARAM, server });
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
pub fn emitServeAndClose(self: *Codegen, server: []const u8, wrapper_name: []const u8, max_conn_text: []const u8, ws_wrapper_name: ?[]const u8) CodegenError!void {
    if (ws_wrapper_name) |wsw| {
        try self.out.writer.print("    call $nox_http_serve_ws_raw(l {s}, l {s}, l ${s}, l {s}, l ${s}, l {s})\n", .{ RT_PARAM, server, wrapper_name, RT_PARAM, wsw, max_conn_text });
    } else {
        try self.out.writer.print("    call $nox_http_serve_raw(l {s}, l {s}, l ${s}, l {s}, l {s})\n", .{ RT_PARAM, server, wrapper_name, RT_PARAM, max_conn_text });
    }
    try self.out.writer.print("    call $nox_http_server_close(l {s}, l {s})\n", .{ RT_PARAM, server });
}

/// Faz "sunucu-tarafı TLS + WS": `tls_ctx_text` (varsa) `nox_http_server_
/// from_fd` YERİNE `nox_http_server_from_fd_tls`i seçer — `null` GEÇİLDİĞİNDE
/// davranış BİREBİR ÖNCEKİYLE AYNIDIR (`genHttpServeFd`nin AYNI çağrısı
/// `null, null` geçer).
pub fn emitFdServeTail(self: *Codegen, fd_text: []const u8, wrapper_name: []const u8, max_conn_text: []const u8, tls_ctx_text: ?[]const u8, ws_wrapper_name: ?[]const u8) CodegenError!void {
    const server = try self.newTemp();
    if (tls_ctx_text) |ctx| {
        try self.out.writer.print("    {s} =l call $nox_http_server_from_fd_tls(l {s}, l {s}, l {s})\n", .{ server, RT_PARAM, fd_text, ctx });
    } else {
        try self.out.writer.print("    {s} =l call $nox_http_server_from_fd(l {s}, l {s})\n", .{ server, RT_PARAM, fd_text });
    }
    try self.emitServeAndClose(server, wrapper_name, max_conn_text, ws_wrapper_name);
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

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = self.computeUsedFieldsFor(handle_name) });

    try self.emitFdServeTail(fd_v.text, wrapper_name, max_conn_text, null, null);
    return .{ .text = "0", .qtype = .none };
}

/// `nox.http.serve_multicore(port, handle, num_threads[,
/// max_connections])` çağrı sitesi codegen'i — Faz DD.1 (bkz. nox-
/// teknik-spesifikasyon.md §3.60). `port` BİR KEZ `nox_http_listen_fd`
/// İLE dinlemeye alınır (ham bir `int` fd, `ServerHandle` YOK),
/// `num_threads - 1` ek `nox.thread` worker'ı (bkz. `genHttpServeMulticoreWorker`)
/// AYNI paylaşılan fd üzerinde `nox_thread_spawn` İLE başlatılır —
/// `genForRange`nin AYNI sayaçlı-döngü şekli (bkz. onun belge notu),
/// TEK fark: döngü değişkeni bir Nox kullanıcı değişkeni DEĞİL, `self.
/// vars`e HİÇ kaydedilmeyen sentetik bir yığın yuvasıdır. ÇAĞIRAN iş
/// parçacığının KENDİSİ Nninci worker OLUR (`emitFdServeTail` İLE,
/// `genHttpServeFd`nin kuyruğuyla AYNI) — bugünkü `nox.http.serve`nin
/// "çağrı sonsuza kadar bloke olur" sözleşmesiyle TUTARLI.
///
/// **`ThreadHandle`lar KENDİ `emitFdServeTail`imizden SONRA join
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
    if (c.args.len == 4) {
        max_conn_text = try std.fmt.allocPrint(self.allocator, "{d}", .{c.args[3].int_lit});
    }

    const fd = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_http_listen_fd(l {s}, l {s})\n", .{ fd, RT_PARAM, port_v.text });

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = self.computeUsedFieldsFor(handle_name) });

    const worker_name = try std.fmt.allocPrint(self.allocator, "http_serve_mc_worker_{d}", .{self.http_serve_multicore_worker_counter});
    self.http_serve_multicore_worker_counter += 1;
    try self.http_serve_multicore_workers.append(self.allocator, .{ .name = worker_name, .wrapper_name = wrapper_name, .max_conn_text = max_conn_text });

    // Faz HH.8 (bkz. nox-teknik-spesifikasyon.md §3.66): spawn edilen
    // `ThreadHandle`ları (yalnızca `num_threads - 1` kadarı KULLANILIR,
    // indeks 0 hiç YAZILMAZ) daha SONRA join edebilmek İçin geçici bir
    // dizide TUTULUR — `num_threads` derleme-zamanı sabiti OLMAYABİLDİĞİNDEN
    // (bkz. yukarıdaki `.int` denetimi, `max_connections`in AKSİNE
    // `.int_lit` ZORUNLU DEĞİL) boyut ÇALIŞMA ZAMANINDA hesaplanır.
    const handles_bytes = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ handles_bytes, num_threads_v.text });
    const handles_arr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {s})\n", .{ handles_arr, RT_PARAM, handles_bytes });

    const i_slot = try self.newTemp();
    try self.out.writer.print("    {s} =l alloc8 8\n", .{i_slot});
    try self.out.writer.print("    storel 1, {s}\n", .{i_slot});

    const cond_label = try self.newLabel("mc_spawn_cond");
    const body_label = try self.newLabel("mc_spawn_body");
    const end_label = try self.newLabel("mc_spawn_end");

    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const cur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur, i_slot });
    const cmp = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, cur, num_threads_v.text });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
    try self.out.writer.print("{s}\n", .{body_label});
    const handle_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_thread_spawn(l {s}, l ${s}, l {s}, w 0, w 0)\n", .{ handle_ptr, RT_PARAM, worker_name, fd });
    const slot_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ slot_off, cur });
    const slot_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ slot_ptr, handles_arr, slot_off });
    try self.out.writer.print("    storel {s}, {s}\n", .{ handle_ptr, slot_ptr });
    const cur2 = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur2, i_slot });
    const next = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ next, cur2 });
    try self.out.writer.print("    storel {s}, {s}\n", .{ next, i_slot });
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{end_label});

    try self.emitFdServeTail(fd, wrapper_name, max_conn_text, null, null);

    // Faz HH.8: ÇAĞIRANIN KENDİ payı (yukarıdaki `emitFdServeTail`)
    // BİTTİKTEN SONRA, spawn edilen HER worker'ı join et — `max_
    // connections=0` (sınırsız) olduğunda `emitFdServeTail` ZATEN
    // sonsuza dek döndüğünden buraya HİÇ ULAŞILMAZ (davranış DEĞİŞMEZ);
    // SONLU olduğundaysa bu, `$main`in worker'lar HENÜZ KENDİ
    // bağlantılarını kabul ETMEDEN süreç çıkışına izin verdiği GERÇEK
    // yarış durumunu (bkz. yukarıdaki belge notu) KAPATIR.
    const j_slot = try self.newTemp();
    try self.out.writer.print("    {s} =l alloc8 8\n", .{j_slot});
    try self.out.writer.print("    storel 1, {s}\n", .{j_slot});

    const jcond_label = try self.newLabel("mc_join_cond");
    const jbody_label = try self.newLabel("mc_join_body");
    const jend_label = try self.newLabel("mc_join_end");

    try self.out.writer.print("    jmp {s}\n", .{jcond_label});
    try self.out.writer.print("{s}\n", .{jcond_label});
    const jcur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ jcur, j_slot });
    const jcmp = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ jcmp, jcur, num_threads_v.text });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ jcmp, jbody_label, jend_label });
    try self.out.writer.print("{s}\n", .{jbody_label});
    const jslot_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ jslot_off, jcur });
    const jslot_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ jslot_ptr, handles_arr, jslot_off });
    const jhandle = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ jhandle, jslot_ptr });
    try self.out.writer.print("    call $nox_thread_join(l {s}, l {s})\n", .{ RT_PARAM, jhandle });
    try self.out.writer.print("    call $nox_thread_destroy(l {s}, l {s})\n", .{ RT_PARAM, jhandle });
    const jcur2 = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ jcur2, j_slot });
    const jnext = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ jnext, jcur2 });
    try self.out.writer.print("    storel {s}, {s}\n", .{ jnext, j_slot });
    try self.out.writer.print("    jmp {s}\n", .{jcond_label});
    try self.out.writer.print("{s}\n", .{jend_label});
    try self.out.writer.print("    call $nox_free(l {s}, l {s}, l {s})\n", .{ RT_PARAM, handles_arr, handles_bytes });

    return .{ .text = "0", .qtype = .none };
}

/// `nox_thread_spawn`ın ÇAĞIRDIĞI, `nox.http.serve_multicore` çağrı
/// sitesi başına üretilen bir ÇOCUK İŞ PARÇACIĞI girişi — Faz DD.1
/// (bkz. nox-teknik-spesifikasyon.md §3.60). `genThreadStartWrapper`nin
/// KANITLANMIŞ düşük-seviye şekliyle (`%argp`den `RT_PARAM` + payload
/// YÜKLEMESİ) BİREBİR AYNI iskelet, AMA gövde gerçek bir Nox fonksiyonu
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

    try self.out.writer.print("export function l ${s}(l %argp) {{\n@start\n", .{spec.name});
    try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});
    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // BU worker KENDİ bağımsız `RuntimeState`ine (bkz. `childThreadMain`,
    // `runtime/async_rt/thread_bridge.zig`) sahiptir — `globals_block`u
    // BAŞTA `null`dır, KENDİ taze kopyasını burada ilklendirir (worker'LAR
    // ARASI PAYLAŞIM YOK, bilinçli v1 kapsamı). **Deinit ÇAĞRILMAZ**: bu
    // worker `emitFdServeTail`in accept döngüsünde SONSUZA dek çalışır
    // (`max_connections=0` varsayılanında `ret 0` erişilemez), `rt`nin
    // KENDİSİ de zaten HİÇ deinit edilmiyor.
    if (self.module_globals.count() > 0) {
        try self.out.writer.print("    call $nox_init_globals(l {s})\n", .{RT_PARAM});
    }
    const payload_addr = try self.newTemp();
    try self.out.writer.print("    {s} =l add %argp, 8\n", .{payload_addr});

    // Faz "sunucu-tarafı TLS": `spec.tls` İSE `payload_addr`nin İÇERDİĞİ
    // DEĞER ÇIPLAK bir `fd` DEĞİL, `nox_http_listen_fd_tls`nin döndürdüğü
    // bir `FdTlsPayload*`dir (bkz. `genHttpServeMulticoreCore`) — bu
    // İŞARETÇİ ÜZERİNDEN İKİ ALAN (`fd` @ ofset 0, `tls_ctx` @ ofset 8)
    // AYRICA YÜKLENİR.
    var fd: []const u8 = undefined;
    var tls_ctx_text: ?[]const u8 = null;
    if (spec.tls) {
        const payload_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ payload_ptr, payload_addr });
        const fd_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ fd_t, payload_ptr });
        const ctx_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ ctx_addr, payload_ptr });
        const ctx_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ ctx_t, ctx_addr });
        fd = fd_t;
        tls_ctx_text = ctx_t;
    } else {
        const fd_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ fd_t, payload_addr });
        fd = fd_t;
    }

    try self.emitFdServeTail(fd, spec.wrapper_name, spec.max_conn_text, tls_ctx_text, spec.ws_wrapper_name);

    try self.out.writer.writeAll("    ret 0\n}\n");
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

    try self.out.writer.print("export function l ${s}(l %ctx, l %req) {{\n@start\n", .{spec.name});
    try self.out.writer.print("    {s} =l copy %ctx\n", .{RT_PARAM});

    const req_cinfo = self.classes.get(spec.req_class) orelse return error.Unsupported;
    const req_values = try self.allocator.alloc(Value, req_cinfo.fields.items.len);
    for (req_cinfo.fields.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "method")) {
            // Faz HH.4: `handle` bu alanı HİÇ okumuyorsa, pahalı
            // `nox_http_request_method` (retain — bkz. HH.2) YERİNE
            // ucuz, PINNED-refcount'lu boş bir literal üretilir.
            req_values[i] = if (spec.used_fields.method) blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =l call $nox_http_request_method(l {s}, l %req)\n", .{ t, RT_PARAM });
                break :blk .{ .text = t, .qtype = .l, .heap = .str };
            } else try self.emitStringLiteral("");
        } else if (std.mem.eql(u8, f.name, "target")) {
            req_values[i] = if (spec.used_fields.target) blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =l call $nox_http_request_target(l {s}, l %req)\n", .{ t, RT_PARAM });
                break :blk .{ .text = t, .qtype = .l, .heap = .str };
            } else try self.emitStringLiteral("");
        } else if (std.mem.eql(u8, f.name, "body")) {
            req_values[i] = if (spec.used_fields.body) blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =l call $nox_http_request_body(l {s}, l %req)\n", .{ t, RT_PARAM });
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
                try self.out.writer.print("    {s} =l call $nox_http_request_headers(l {s}, l %req)\n", .{ t, RT_PARAM });
            } else {
                try self.out.writer.print("    {s} =l call $nox_dict_new(l {s}, w 1)\n", .{ t, RT_PARAM });
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
    try self.out.writer.print("    {s} =l call ${s}(l {s}, l {s})\n", .{ resp_obj_text, spec.handler_fn, RT_PARAM, req_obj.text });
    const resp_obj: Value = .{ .text = resp_obj_text, .qtype = .l, .heap = .class, .class_name = spec.resp_class };

    try self.releaseValueIfSet(req_obj.text, req_obj.heap, req_obj.elem_qtype, req_obj.class_name, req_obj.elem_heap_info, req_obj.dict_info);

    const status = try self.genFieldReadFromValue(resp_obj, "status");
    const body = try self.genFieldReadFromValue(resp_obj, "body");
    const headers = try self.genFieldReadFromValue(resp_obj, "headers");

    const raw_resp = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_http_response_new(l {s}, l {s}, l {s}, l {s})\n", .{ raw_resp, RT_PARAM, status.text, body.text, headers.text });

    try self.releaseValueIfSet(resp_obj.text, resp_obj.heap, resp_obj.elem_qtype, resp_obj.class_name, resp_obj.elem_heap_info, resp_obj.dict_info);

    try self.out.writer.print("    ret {s}\n}}\n", .{raw_resp});
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

    try self.out.writer.print("export function l ${s}(l %ctx, l %conn) {{\n@start\n", .{spec.name});
    try self.out.writer.print("    {s} =l copy %ctx\n", .{RT_PARAM});

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

    try self.out.writer.print("    call ${s}(l {s}, l {s})\n", .{ spec.ws_handler_fn, RT_PARAM, conn_obj.text });

    try self.releaseValueIfSet(conn_obj.text, conn_obj.heap, conn_obj.elem_qtype, conn_obj.class_name, conn_obj.elem_heap_info, conn_obj.dict_info);

    try self.out.writer.writeAll("    ret 0\n}\n");
}

/// Faz "sunucu-tarafı TLS + WebSocket Upgrade" (bkz. plan dosyası §6) —
/// `handle`in (bkz. `genHttpServe`nin AYNI doğrulaması) VE isteğe bağlı
/// olarak `ws_handle`nin ÇÖZÜMLENMESİNİ, `HttpServeWrapperSpec`/
/// `HttpServeWsWrapperSpec` KAYDINI paylaşan yardımcı — `genHttpServe*
/// Generic`nin ÜÇÜ TARAFINDAN da çağrılır.
pub fn registerHttpHandlers(self: *Codegen, handle_name: []const u8, ws_handle_name: ?[]const u8) CodegenError!struct {
    wrapper_name: []const u8,
    ws_wrapper_name: ?[]const u8,
} {
    const sig = self.functions.get(handle_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;
    if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
    if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
    const req_class = sig.params[0].class_name.?;
    const resp_class = sig.ret.class_name.?;

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
    self.http_serve_wrapper_counter += 1;
    try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class, .used_fields = self.computeUsedFieldsFor(handle_name) });

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

    return .{ .wrapper_name = wrapper_name, .ws_wrapper_name = ws_wrapper_name };
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
        try self.out.writer.print("    {s} =l call $nox_http_server_listen_tls(l {s}, l {s}, l {s}, l {s})\n", .{ server, RT_PARAM, port_v.text, cert_v.text, key_v.text });
    } else {
        try self.out.writer.print("    {s} =l call $nox_http_server_listen(l {s}, l {s})\n", .{ server, RT_PARAM, port_v.text });
    }

    const handlers = try self.registerHttpHandlers(handle_name, ws_handle_name);
    try self.emitServeAndClose(server, handlers.wrapper_name, max_conn_text, handlers.ws_wrapper_name);
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
        try self.out.writer.print("    {s} =l call $nox_http_server_from_fd_tls_owned(l {s}, l {s}, l {s}, l {s})\n", .{ server, RT_PARAM, fd_v.text, cert_v.text, key_v.text });
        try self.emitServeAndClose(server, handlers.wrapper_name, max_conn_text, handlers.ws_wrapper_name);
    } else {
        try self.emitFdServeTail(fd_v.text, handlers.wrapper_name, max_conn_text, null, handlers.ws_wrapper_name);
    }
    return .{ .text = "0", .qtype = .none };
}

/// `nox.http.serve_multicore_tls`/`serve_multicore_ws`/`serve_multicore_
/// ws_tls` — `genHttpServeMulticore`nin PARAMETRİK genellemesi.
/// `want_tls` İSE paylaşılan dinleme fd'si `nox_http_listen_fd_tls` İLE
/// (ÇIPLAK bir `int` DEĞİL, bir `FdTlsPayload*` olarak) elde edilir —
/// HER worker (bkz. `genHttpServeMulticoreWorker`nin `spec.tls` dalı) VE
/// ÇAĞIRANIN KENDİ payı (aşağıda, `emitFdServeTail`DEN ÖNCE) bu İŞARETÇİDEN
/// `fd`/`tls_ctx`yi AYRI AYRI ÇIKARIR. Paylaşılan `SSL_CTX*`, TÜM
/// worker'lar JOIN EDİLDİKTEN SONRA (bkz. `nox_tls_ctx_free`nin belge
/// notu — ERKEN serbest bırakmak bir kullanım-sonrası-serbest-bırakma
/// YARIŞI olurdu) TEK bir yerden serbest bırakılır.
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
    if (c.args.len > idx) {
        max_conn_text = try std.fmt.allocPrint(self.allocator, "{d}", .{c.args[idx].int_lit});
        idx += 1;
    }

    const fd = try self.newTemp();
    if (want_tls) {
        try self.out.writer.print("    {s} =l call $nox_http_listen_fd_tls(l {s}, l {s}, l {s}, l {s})\n", .{ fd, RT_PARAM, port_v.text, cert_v.text, key_v.text });
    } else {
        try self.out.writer.print("    {s} =l call $nox_http_listen_fd(l {s}, l {s})\n", .{ fd, RT_PARAM, port_v.text });
    }

    const handlers = try self.registerHttpHandlers(handle_name, ws_handle_name);

    const worker_name = try std.fmt.allocPrint(self.allocator, "http_serve_mc_worker_{d}", .{self.http_serve_multicore_worker_counter});
    self.http_serve_multicore_worker_counter += 1;
    try self.http_serve_multicore_workers.append(self.allocator, .{ .name = worker_name, .wrapper_name = handlers.wrapper_name, .max_conn_text = max_conn_text, .ws_wrapper_name = handlers.ws_wrapper_name, .tls = want_tls });

    // Faz HH.8 (bkz. `genHttpServeMulticore`nin AYNI belge notu): spawn
    // edilen `ThreadHandle`ları daha SONRA join edebilmek İçin geçici bir
    // dizide TUTULUR.
    const handles_bytes = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ handles_bytes, num_threads_v.text });
    const handles_arr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {s})\n", .{ handles_arr, RT_PARAM, handles_bytes });

    const i_slot = try self.newTemp();
    try self.out.writer.print("    {s} =l alloc8 8\n", .{i_slot});
    try self.out.writer.print("    storel 1, {s}\n", .{i_slot});

    const cond_label = try self.newLabel("mc_spawn_cond");
    const body_label = try self.newLabel("mc_spawn_body");
    const end_label = try self.newLabel("mc_spawn_end");

    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{cond_label});
    const cur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur, i_slot });
    const cmp = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, cur, num_threads_v.text });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
    try self.out.writer.print("{s}\n", .{body_label});
    const handle_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l call $nox_thread_spawn(l {s}, l ${s}, l {s}, w 0, w 0)\n", .{ handle_ptr, RT_PARAM, worker_name, fd });
    const slot_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ slot_off, cur });
    const slot_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ slot_ptr, handles_arr, slot_off });
    try self.out.writer.print("    storel {s}, {s}\n", .{ handle_ptr, slot_ptr });
    const cur2 = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur2, i_slot });
    const next = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ next, cur2 });
    try self.out.writer.print("    storel {s}, {s}\n", .{ next, i_slot });
    try self.out.writer.print("    jmp {s}\n", .{cond_label});
    try self.out.writer.print("{s}\n", .{end_label});

    // ÇAĞIRANIN KENDİ payı: `want_tls` İSE `fd` ÇIPLAK bir değer DEĞİL,
    // bir `FdTlsPayload*`dir (bkz. `genHttpServeMulticoreWorker`nin AYNI
    // çıkarma dalı) — `emitFdServeTail`e VERİLMEDEN ÖNCE İKİ alanı AYRI
    // AYRI ÇIKARILIR.
    var fd_text: []const u8 = fd;
    var tls_ctx_text: ?[]const u8 = null;
    if (want_tls) {
        const fd_extracted = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ fd_extracted, fd });
        const ctx_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ ctx_addr, fd });
        const ctx_extracted = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ ctx_extracted, ctx_addr });
        fd_text = fd_extracted;
        tls_ctx_text = ctx_extracted;
    }
    try self.emitFdServeTail(fd_text, handlers.wrapper_name, max_conn_text, tls_ctx_text, handlers.ws_wrapper_name);

    // Faz HH.8: ÇAĞIRANIN KENDİ payı BİTTİKTEN SONRA, spawn edilen HER
    // worker'ı join et (bkz. `genHttpServeMulticore`nin AYNI gerekçesi).
    const j_slot = try self.newTemp();
    try self.out.writer.print("    {s} =l alloc8 8\n", .{j_slot});
    try self.out.writer.print("    storel 1, {s}\n", .{j_slot});

    const jcond_label = try self.newLabel("mc_join_cond");
    const jbody_label = try self.newLabel("mc_join_body");
    const jend_label = try self.newLabel("mc_join_end");

    try self.out.writer.print("    jmp {s}\n", .{jcond_label});
    try self.out.writer.print("{s}\n", .{jcond_label});
    const jcur = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ jcur, j_slot });
    const jcmp = try self.newTemp();
    try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ jcmp, jcur, num_threads_v.text });
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ jcmp, jbody_label, jend_label });
    try self.out.writer.print("{s}\n", .{jbody_label});
    const jslot_off = try self.newTemp();
    try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ jslot_off, jcur });
    const jslot_ptr = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ jslot_ptr, handles_arr, jslot_off });
    const jhandle = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ jhandle, jslot_ptr });
    try self.out.writer.print("    call $nox_thread_join(l {s}, l {s})\n", .{ RT_PARAM, jhandle });
    try self.out.writer.print("    call $nox_thread_destroy(l {s}, l {s})\n", .{ RT_PARAM, jhandle });
    const jcur2 = try self.newTemp();
    try self.out.writer.print("    {s} =l loadl {s}\n", .{ jcur2, j_slot });
    const jnext = try self.newTemp();
    try self.out.writer.print("    {s} =l add {s}, 1\n", .{ jnext, jcur2 });
    try self.out.writer.print("    storel {s}, {s}\n", .{ jnext, j_slot });
    try self.out.writer.print("    jmp {s}\n", .{jcond_label});
    try self.out.writer.print("{s}\n", .{jend_label});
    try self.out.writer.print("    call $nox_free(l {s}, l {s}, l {s})\n", .{ RT_PARAM, handles_arr, handles_bytes });

    if (tls_ctx_text) |ctx| {
        try self.out.writer.print("    call $nox_tls_ctx_free(l {s})\n", .{ctx});
    }

    return .{ .text = "0", .qtype = .none };
}
