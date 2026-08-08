//! Faz MN.3a (bkz. proje planı "LLVM-only atomic ARC + tam work-stealing
//! M:N fiber zamanlayıcı") — Chase-Lev lock-free work-stealing deque,
//! Lê/Pop/Cohen/Zappa Nardelli'nin (PPoPP 2013, "Correct and Efficient
//! Work-Stealing for Weak Memory Models") bellek-sıralaması-düzeltilmiş
//! versiyonu. **BAĞIMSIZ, `scheduler.zig`/`bridge.zig`ye SIFIR entegrasyon**
//! — bu modül SADECE algoritmanın kendisini uygular/birim-test eder;
//! gelecekteki bir worker-havuzu fazı (bkz. plan, Faz MN.3b/MN.4) `*Fiber`
//! elemanlarıyla örnekleyip zamanlayıcıya BAĞLAYACAKTIR.
//!
//! **Sahiplik modeli:** `pushBottom`/`popBottom` YALNIZCA deque'nin SAHİBİ
//! (owner) iş parçacığından çağrılabilir (senkronize edilmeden — `bottom`
//! üzerinde YARIŞMA yoktur, SADECE owner yazar). `steal`, HERHANGİ bir
//! SAYIDA farklı "thief" iş parçacığından EŞ ZAMANLI olarak (BİRBİRLERİYLE
//! VE owner'ın `popBottom`ıYLA YARIŞARAK) güvenle çağrılabilir — `top`
//! ÜZERİNDEKİ `compare-and-swap` yarışı KAZANAN TEK bir çağıranın elemanı
//! ALMASINI garanti eder.
//!
//! **Sabit kapasiteli halka tampon (BİLİNÇLİ v1 basitleştirmesi):**
//! orijinal makale dinamik büyüme/küçülmeyi de kapsıyor (eski tamponların
//! GÜVENLİ geri kazanımı İçin hazard-pointer-benzeri bir mekanizma
//! GEREKTİRİR) — bu, algoritmanın gerçek eşzamanlılık-doğruluk riskinin
//! YOĞUNLAŞTIĞI `top`/`bottom` koordinasyonundan AYRI, ORTOGONAL bir
//! mühendislik sorunu. Bu fazın kapsamı BİLİNÇLİ olarak sabit kapasiteye
//! daraltıldı (`pushBottom` doluyken `error.Full` döner) — dinamik büyüme
//! GEREKİRSE AYRI bir fazda eklenebilir.
//!
//! **`std.atomic.Value`nin `fence()` metodu YOK (bu Zig sürümünde, 0.16.0)
//! — ne `@fence` builtin'i NE `std.atomic.fence()` bağımsız fonksiyonu
//! MEVCUT** (doğrulandı — ikisi de derleme hatası verir). Makalenin
//! `popBottom`daki bağımsız `SeqCst` fence'i (ucuz `relaxed` bir store'u
//! `top`un OKUNMASINDAN ÖNCE global olarak GÖRÜNÜR kılmak İçİn) YERİNE,
//! BU İKİ işlemin KENDİSİNİ (`bottom.store`/`top.load`) doğrudan `.seq_cst`
//! YAPARAK AYNI StoreLoad sıralaması garantisi elde edilir — C11/LLVM
//! bellek modelinde `seq_cst` işlemler TEK bir toplam sırada YER ALDIĞINDAN,
//! bu İKİ nokta arasındaki YENİDEN-SIRALAMA YASAKLANIR (fence+relaxed'in
//! sağladığı GARANTİYLE FONKSİYONEL olarak EŞDEĞER — bazı mimarilerde
//! marjinal olarak daha PAHALI olabilir, ama KESİN doğru). `steal`de de
//! AYNI teknik (`top.load(.seq_cst)`/`bottom.load(.seq_cst)`) kullanılır.

const std = @import("std");
const builtin = @import("builtin");

pub fn ChaseLevDeque(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("ChaseLevDeque: capacity bir 2'nin kuvveti olmalı");
        }
    }
    return struct {
        const Self = @This();
        const MASK = capacity - 1;

        buffer: [capacity]T = undefined,
        /// Thief'lerin ÇEKTİĞİ (en eski) uç — CAS-tabanlı, çoklu-çağıran.
        /// **`isize` (İŞARETLİ) — BİLİNÇLİ, KRİTİK bir seçim**: `popBottom`
        /// BOŞ bir deque'de `bottom.load() -% 1` HESAPLAR — `bottom`
        /// İŞARETSİZ (`usize`) OLSAYDI, boş (0) durumda bu SARIP `usize`
        /// MAX'e (DEV bir pozitif sayı) döner, `t <= b` kontrolü YANLIŞLIKLA
        /// "boş DEĞİL" SONUCUNU verip TANIMSIZ (başlatılmamış) `buffer`
        /// içeriğini "eleman" olarak DÖNDÜRÜRDÜ — GERÇEKTEN bu HATAYLA
        /// yazılıp bir test tarafından YAKALANDI (bkz. git geçmişi). İşaretli
        /// tipte AYNI hesap `-1` verir, `0 <= -1` YANLIŞTIR — DOĞRU "boş"
        /// sonucu.
        top: std.atomic.Value(isize) = .init(0),
        /// Owner'ın it/çek YAPTIĞI (en yeni) uç — SADECE owner yazar. AYNI
        /// `isize` gerekçesi (`top`un belge notuna bkz.).
        bottom: std.atomic.Value(isize) = .init(0),

        pub fn init() Self {
            return .{};
        }

        /// `isize` indeksi (negatif OLABİLİR — bkz. `top`un belge notu)
        /// tampon indeksine ÇEVİRİR — bit-kalıbı KORUNARAK `usize`e
        /// `@bitCast` edilir (iki'nin tümleyeni sayesinde DÜŞÜK bitler
        /// işaretten BAĞIMSIZ AYNIDIR), SONRA `MASK`lenir.
        inline fn idx(i: isize) usize {
            return @as(usize, @bitCast(i)) & MASK;
        }

        /// SADECE owner'dan çağrılır. Dolu İSE `error.Full` döner (bu
        /// fazda dinamik büyüme YOK — bkz. modül üstü not).
        pub fn pushBottom(self: *Self, item: T) error{Full}!void {
            const b = self.bottom.load(.monotonic);
            // `top`u `.acquire` OKUMAK, EŞ ZAMANLI bir `steal`in AZ ÖNCE
            // İLERLETTİĞİ `top`u GÖREBİLMEK İçİn GEREKLİ — aksi halde
            // dolu OLMAYAN bir deque yanlışlıkla `error.Full` DÖNEBİLİR
            // (YANLIŞ ama GÜVENLİ yönde bir hata; TERSİ — kapasiteyi
          // AŞAN bir yazma — asla OLAMAZ, ÇÜNKÜ `t` SADECE artabilir).
            const t = self.top.load(.acquire);
            if (b -% t >= @as(isize, @intCast(capacity))) return error.Full;
            self.buffer[idx(b)] = item;
            // `.release`: bu SATIRDAN ÖNCEKİ `buffer` yazması, BUNU
            // `.acquire` OKUYAN bir thief'e (bkz. `steal`) GÖRÜNÜR olmadan
            // ÖNCE asla YENİDEN SIRALANAMAZ.
            self.bottom.store(b +% 1, .release);
        }

        /// SADECE owner'dan çağrılır. Deque BOŞSA ya da owner bir thief'e
        /// KARŞI son elemanı KAYBEDEN tarafta KALIRSA `null` döner.
        pub fn popBottom(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            // Modül üstü nota bkz.: `.seq_cst` BURADA, AŞAĞIDAKİ `top`
            // okumasıyla BİRLİKTE, bağımsız bir fence'in YERİNİ TUTAR.
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);
            if (t <= b) {
                // Boş DEĞİL.
                const item = self.buffer[idx(b)];
                if (t == b) {
                    // TEK eleman kaldı — bir thief'le YARIŞ VAR.
                    if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                        // KAYBETTİK — thief ALDI.
                        self.bottom.store(b +% 1, .monotonic);
                        return null;
                    }
                    self.bottom.store(b +% 1, .monotonic);
                }
                return item;
            } else {
                // Boştu (owner'ın `bottom -= 1`i `top`un ÖNÜNE GEÇTİ) —
                // durumu düzelt.
                self.bottom.store(b +% 1, .monotonic);
                return null;
            }
        }

        /// HERHANGİ bir SAYIDA thief iş parçacığından EŞ ZAMANLI çağrılabilir.
        /// Boşsa ya da BAŞKA bir thief/owner'la YARIŞI KAYBEDERSE `null`
        /// döner (çağıran taraf TEKRAR denemeli ya da başka bir deque'ye
        /// geçmelidir — bu, GERÇEK bir hata DEĞİL, work-stealing'in NORMAL
        /// çekişme durumudur).
        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);
            if (t < b) {
                const item = self.buffer[idx(t)];
                if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                    // KAYBETTİK — owner'ın `popBottom`ı ya da BAŞKA bir
                    // thief AYNI elemanı ALDI.
                    return null;
                }
                return item;
            }
            return null;
        }

        /// SADECE tanısal/test amaçlı — GERÇEK eşzamanlı kodda `size()`in
        /// KENDİSİ ANINDA BAYATLAYABİLİR (owner/thief'ler AYNI ANDA
        /// değiştirebilir), akış kontrolü İçİn KULLANILMAMALIDIR.
        pub fn size(self: *const Self) usize {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            return if (b >= t) @intCast(b -% t) else 0;
        }
    };
}

test "tek iş parçacıklı: pushBottom/popBottom LIFO sırası" {
    var d = ChaseLevDeque(i64, 16).init();
    try d.pushBottom(1);
    try d.pushBottom(2);
    try d.pushBottom(3);
    try std.testing.expectEqual(@as(usize, 3), d.size());
    try std.testing.expectEqual(@as(?i64, 3), d.popBottom());
    try std.testing.expectEqual(@as(?i64, 2), d.popBottom());
    try std.testing.expectEqual(@as(?i64, 1), d.popBottom());
    try std.testing.expectEqual(@as(?i64, null), d.popBottom());
}

test "tek iş parçacıklı: steal FIFO sırası (en eskiden alır)" {
    var d = ChaseLevDeque(i64, 16).init();
    try d.pushBottom(1);
    try d.pushBottom(2);
    try d.pushBottom(3);
    try std.testing.expectEqual(@as(?i64, 1), d.steal());
    try std.testing.expectEqual(@as(?i64, 2), d.steal());
    try std.testing.expectEqual(@as(?i64, 3), d.steal());
    try std.testing.expectEqual(@as(?i64, null), d.steal());
}

test "boş deque'de popBottom ve steal null döner" {
    var d = ChaseLevDeque(i64, 8).init();
    try std.testing.expectEqual(@as(?i64, null), d.popBottom());
    try std.testing.expectEqual(@as(?i64, null), d.steal());
}

test "dolu deque'de pushBottom error.Full döner" {
    var d = ChaseLevDeque(i64, 4).init();
    try d.pushBottom(1);
    try d.pushBottom(2);
    try d.pushBottom(3);
    try d.pushBottom(4);
    try std.testing.expectError(error.Full, d.pushBottom(5));
    // Bir eleman ÇIKARILINCA yer AÇILIR.
    try std.testing.expectEqual(@as(?i64, 4), d.popBottom());
    try d.pushBottom(5);
    try std.testing.expectEqual(@as(usize, 4), d.size());
}

test "tek elemanlı deque: popBottom ve steal AYNI ANDA yarışırsa yalnızca biri kazanır" {
    // Gerçek eşzamanlılık OLMADAN (tek iş parçacıklı), ama `t == b`
    // dalının HER İKİ çağrı SIRASINI da (önce popBottom, önce steal)
    // deterministik olarak DOĞRULAR.
    {
        var d = ChaseLevDeque(i64, 8).init();
        try d.pushBottom(42);
        const popped = d.popBottom();
        const stolen = d.steal();
        try std.testing.expectEqual(@as(?i64, 42), popped);
        try std.testing.expectEqual(@as(?i64, null), stolen);
    }
    {
        var d = ChaseLevDeque(i64, 8).init();
        try d.pushBottom(42);
        const stolen = d.steal();
        const popped = d.popBottom();
        try std.testing.expectEqual(@as(?i64, 42), stolen);
        try std.testing.expectEqual(@as(?i64, null), popped);
    }
}

test "GERÇEK eşzamanlılık: 1 owner + N thief, HER eleman TAM BİR KEZ alınır" {
    const N_ITEMS = 20_000;
    const N_THIEVES = 4;

    const Shared = struct {
        deque: ChaseLevDeque(i64, 1024) = ChaseLevDeque(i64, 1024).init(),
        taken: [N_ITEMS]std.atomic.Value(u8) = @splat(std.atomic.Value(u8).init(0)),
        stop: std.atomic.Value(bool) = .init(false),

        fn markTaken(self: *@This(), value: i64) void {
            const idx: usize = @intCast(value);
            // `fetchAdd` — İKİ farklı ÇAĞIRANIN (owner+thief ya da İKİ
            // thief) AYNI değeri İKİ KEZ "aldığını" SANMASI durumunda
          // (bu asla OLMAMALI — algoritmanın TAM DA kanıtlamaya
            // çalıştığımız GARANTİSİ) testte YAKALANIR (1'den BÜYÜK sayaç).
            const prev = self.taken[idx].fetchAdd(1, .seq_cst);
            std.debug.assert(prev == 0);
        }
    };

    var shared = try std.testing.allocator.create(Shared);
    defer std.testing.allocator.destroy(shared);
    shared.* = .{};

    const Thief = struct {
        fn run(s: *Shared) void {
            while (!s.stop.load(.acquire)) {
                if (s.deque.steal()) |v| s.markTaken(v);
            }
            // Durdurulduktan SONRA da kalan elemanları TEMİZLE (owner
            // itmeyi BİTİRDİ ama HÂLÂ kalan olabilir).
            while (s.deque.steal()) |v| s.markTaken(v);
        }
    };

    var threads: [N_THIEVES]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Thief.run, .{shared});
    }

    // Owner: it VE ARA SIRA kendi çek (popBottom) — İKİSİNİ de AYNI ANDA
    // egzersiz ETMEK İçİn.
    var i: i64 = 0;
    while (i < N_ITEMS) : (i += 1) {
        while (true) {
            shared.deque.pushBottom(i) catch {
                // Dolu — thief'lerin BOŞALTMASI İçİn KISA bir bekleme.
                std.Thread.yield() catch {};
                continue;
            };
            break;
        }
        if (@mod(i, 7) == 0) {
            if (shared.deque.popBottom()) |v| shared.markTaken(v);
        }
    }

    shared.stop.store(true, .release);
    for (&threads) |t| t.join();

    // Owner'IN KENDİSİ de kalanları TEMİZLESİN (thief'ler DURDUKTAN SONRA
    // owner tarafında KALMIŞ olabilir).
    while (shared.deque.popBottom()) |v| shared.markTaken(v);

    var total: usize = 0;
    for (&shared.taken) |*t| total += t.load(.seq_cst);
    try std.testing.expectEqual(@as(usize, N_ITEMS), total);
}
