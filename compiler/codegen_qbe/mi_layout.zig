//! Çoklu kalıtım (`class C(A, B)`, TODO 8.2) için nesne düzeni ve vtable renklendirmesi.
//!
//! `C`, `B` mixin tipinin ALT TİPİDİR: `C` nesnesi `B` tipli bir değişkende AYNI işaretçiyle tutulur ve `B` tipli kod (alan okuması/yazması, metod çağrısı)
//! `B`nin kendi derlenmiş ofsetlerini/vtable slotlarını kullanır. Bu yüzden `B`nin her alanı ve her metodu `C`de de AYNI ofset/slotta olmalıdır. Tekli
//! kalıtımda taban alanları hep önce geldiği için bu kendiliğinden sağlanır; kardeş tabanlar (`A` ve `B`) ise aynı ofsetleri isteyebilir.
//!
//! Çözüm (C++'ın alt-nesne ofsetlerinin yerine, işaretçi kimliğini koruyan): kalıtımla BAĞLANTILI sınıflar kümesinde (bileşen) alan ADI → yuva ve metod ADI →
//! vtable slotu eşlemesi BİLEŞEN GENELİNDE renklendirilir. Aynı ad her sınıfta aynı yuvayı alır (Python'un paylaşılan öznitelik/metod adı anlamı; elmas
//! tabanlar bu yüzden tek kopya paylaşır); bir sınıfın (atalarıyla birlikte) birlikte bulunan adları farklı yuvalara düşer (çakışma grafı, açgözlü renklendirme).
//! Mixin içermeyen bileşenler ESKİ düzeni korur (IR birebir aynı).

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const MiInfo = struct {
    /// Sınıf adı → bileşen no (yalnızca mixin içeren bileşenlerin sınıfları).
    comp_of: std.StringHashMapUnmanaged(usize) = .empty,
    /// "<bileşen>\x00<ad>" → alan yuvası / vtable slotu.
    field_slot: std.StringHashMapUnmanaged(usize) = .empty,
    method_slot: std.StringHashMapUnmanaged(usize) = .empty,
    /// Bileşen başına yuva/slot sayısı.
    field_count: std.ArrayListUnmanaged(usize) = .empty,
    method_count: std.ArrayListUnmanaged(usize) = .empty,

    pub fn fieldSlot(self: *const MiInfo, allocator: std.mem.Allocator, comp: usize, name: []const u8) ?usize {
        const key = std.fmt.allocPrint(allocator, "{d}\x00{s}", .{ comp, name }) catch return null;
        defer allocator.free(key);
        return self.field_slot.get(key);
    }

    pub fn methodSlot(self: *const MiInfo, allocator: std.mem.Allocator, comp: usize, name: []const u8) ?usize {
        const key = std.fmt.allocPrint(allocator, "{d}\x00{s}", .{ comp, name }) catch return null;
        defer allocator.free(key);
        return self.method_slot.get(key);
    }
};

const NameList = std.ArrayListUnmanaged([]const u8);

fn addName(a: std.mem.Allocator, list: *NameList, name: []const u8) !void {
    for (list.items) |e| if (std.mem.eql(u8, e, name)) return;
    try list.append(a, name);
}

/// `__init__` / `__nox_init_*` gövdesindeki üst-düzey `self.<ad> = ...` atamalarının adları (`registerClass`ın `registerInitFields` taramasıyla aynı kural).
fn scanInitFields(a: std.mem.Allocator, f: ast.FuncDef, out: *NameList) !void {
    for (f.body) |stmt| {
        if (stmt.kind != .assign) continue;
        const asg = stmt.kind.assign;
        if (asg.target != .attribute) continue;
        const attr = asg.target.attribute;
        if (attr.obj.* != .identifier or !std.mem.eql(u8, attr.obj.identifier, "self")) continue;
        try addName(a, out, attr.attr);
    }
}

fn color(a: std.mem.Allocator, comp: usize, order: []const []const u8, sets: []const NameList, slot_map: *std.StringHashMapUnmanaged(usize)) !usize {
    // çakışma grafı: bir sınıfın (atalarıyla birlikte) adları ikişer ikişer çakışır
    var adj: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer {
        var it = adj.iterator();
        while (it.next()) |e| e.value_ptr.deinit(a);
        adj.deinit(a);
    }
    for (order) |n| try adj.put(a, n, .empty);
    for (sets) |set| {
        for (set.items) |x| {
            for (set.items) |y| {
                if (std.mem.eql(u8, x, y)) continue;
                try adj.getPtr(x).?.put(a, y, {});
            }
        }
    }
    var max_slot: usize = 0;
    var any = false;
    for (order) |n| {
        var used: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer used.deinit(a);
        var it = adj.get(n).?.keyIterator();
        while (it.next()) |nb| {
            const k = try std.fmt.allocPrint(a, "{d}\x00{s}", .{ comp, nb.* });
            defer a.free(k);
            if (slot_map.get(k)) |c| try used.put(a, c, {});
        }
        var c: usize = 0;
        while (used.contains(c)) c += 1;
        try slot_map.put(a, try std.fmt.allocPrint(a, "{d}\x00{s}", .{ comp, n }), c);
        if (!any or c > max_slot) max_slot = c;
        any = true;
    }
    return if (any) max_slot + 1 else 0;
}

pub fn compute(a: std.mem.Allocator, class_defs: []const ast.ClassDef, resolved_bases: std.StringHashMapUnmanaged([]const u8)) !MiInfo {
    var info: MiInfo = .{};
    const n = class_defs.len;
    var index_of: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_of.deinit(a);
    for (class_defs, 0..) |cd, i| try index_of.put(a, cd.name, i);

    // ebeveynler (taban + mixinler)
    const parents = try a.alloc(std.ArrayListUnmanaged(usize), n);
    defer {
        for (parents) |*p| p.deinit(a);
        a.free(parents);
    }
    for (parents) |*p| p.* = .empty;
    var uf = try a.alloc(usize, n);
    defer a.free(uf);
    for (uf, 0..) |*u, i| u.* = i;
    var has_mixin = false;
    for (class_defs, 0..) |cd, i| {
        const base = resolved_bases.get(cd.name) orelse cd.base;
        if (base) |b| if (index_of.get(b)) |bi| try parents[i].append(a, bi);
        for (cd.mixins) |m| if (index_of.get(m)) |mi| {
            try parents[i].append(a, mi);
            has_mixin = true;
        };
    }
    if (!has_mixin) return info;
    const find = struct {
        fn f(u: []usize, x: usize) usize {
            var r = x;
            while (u[r] != r) r = u[r];
            var c = x;
            while (u[c] != r) {
                const nx = u[c];
                u[c] = r;
                c = nx;
            }
            return r;
        }
    }.f;
    for (parents, 0..) |p, i| for (p.items) |pi| {
        const ra = find(uf, i);
        const rb = find(uf, pi);
        if (ra != rb) uf[ra] = rb;
    };
    // mixin içeren bileşenleri işaretle
    const comp_has_mixin = try a.alloc(bool, n);
    defer a.free(comp_has_mixin);
    @memset(comp_has_mixin, false);
    for (class_defs, 0..) |cd, i| if (cd.mixins.len > 0) {
        comp_has_mixin[find(uf, i)] = true;
    };
    // bileşen numaraları
    var comp_id: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer comp_id.deinit(a);
    var ncomp: usize = 0;
    for (0..n) |i| {
        const r = find(uf, i);
        if (!comp_has_mixin[r]) continue;
        if (!comp_id.contains(r)) {
            try comp_id.put(a, r, ncomp);
            ncomp += 1;
            try info.field_count.append(a, 0);
            try info.method_count.append(a, 0);
        }
        try info.comp_of.put(a, class_defs[i].name, comp_id.get(r).?);
    }

    // sınıf başına: kendi alan/metod adları
    const own_fields = try a.alloc(NameList, n);
    const own_methods = try a.alloc(NameList, n);
    defer {
        for (own_fields) |*l| l.deinit(a);
        for (own_methods) |*l| l.deinit(a);
        a.free(own_fields);
        a.free(own_methods);
    }
    for (class_defs, 0..) |cd, i| {
        own_fields[i] = .empty;
        own_methods[i] = .empty;
        for (cd.fields) |f| try addName(a, &own_fields[i], f.name);
        for (cd.methods) |m| {
            if (std.mem.eql(u8, m.name, "__init__") or std.mem.startsWith(u8, m.name, "__nox_init_")) {
                try scanInitFields(a, m, &own_fields[i]);
            }
            if (!std.mem.eql(u8, m.name, "__init__")) try addName(a, &own_methods[i], m.name);
        }
    }

    // topolojik sıra (ebeveynler önce) + atalarla birleşik adlar
    const full_fields = try a.alloc(NameList, n);
    const full_methods = try a.alloc(NameList, n);
    defer {
        for (full_fields) |*l| l.deinit(a);
        for (full_methods) |*l| l.deinit(a);
        a.free(full_fields);
        a.free(full_methods);
    }
    for (0..n) |i| {
        full_fields[i] = .empty;
        full_methods[i] = .empty;
    }
    const state = try a.alloc(u8, n); // 0 = yeni, 1 = işleniyor, 2 = bitti
    defer a.free(state);
    @memset(state, 0);
    var topo: std.ArrayListUnmanaged(usize) = .empty;
    defer topo.deinit(a);
    const Visit = struct {
        fn go(aa: std.mem.Allocator, i: usize, st: []u8, ps: []const std.ArrayListUnmanaged(usize), out: *std.ArrayListUnmanaged(usize)) !void {
            if (st[i] != 0) return;
            st[i] = 1;
            for (ps[i].items) |p| try go(aa, p, st, ps, out);
            st[i] = 2;
            try out.append(aa, i);
        }
    };
    for (0..n) |i| if (info.comp_of.contains(class_defs[i].name)) try Visit.go(a, i, state, parents, &topo);
    for (topo.items) |i| {
        for (parents[i].items) |p| {
            for (full_fields[p].items) |nm| try addName(a, &full_fields[i], nm);
            for (full_methods[p].items) |nm| try addName(a, &full_methods[i], nm);
        }
        for (own_fields[i].items) |nm| try addName(a, &full_fields[i], nm);
        for (own_methods[i].items) |nm| try addName(a, &full_methods[i], nm);
    }

    // bileşen başına renklendirme
    var comp: usize = 0;
    while (comp < ncomp) : (comp += 1) {
        var f_order: NameList = .empty;
        var m_order: NameList = .empty;
        defer f_order.deinit(a);
        defer m_order.deinit(a);
        var f_sets: std.ArrayListUnmanaged(NameList) = .empty;
        defer f_sets.deinit(a);
        var m_sets: std.ArrayListUnmanaged(NameList) = .empty;
        defer m_sets.deinit(a);
        for (topo.items) |i| {
            if (info.comp_of.get(class_defs[i].name).? != comp) continue;
            for (full_fields[i].items) |nm| try addName(a, &f_order, nm);
            for (full_methods[i].items) |nm| try addName(a, &m_order, nm);
            try f_sets.append(a, full_fields[i]);
            try m_sets.append(a, full_methods[i]);
        }
        info.field_count.items[comp] = try color(a, comp, f_order.items, f_sets.items, &info.field_slot);
        info.method_count.items[comp] = try color(a, comp, m_order.items, m_sets.items, &info.method_slot);
    }
    return info;
}
