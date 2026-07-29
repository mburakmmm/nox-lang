//! Nox derleyicisi (QBE codegen) VE çalışma zamanı (`noxrt.o`) ARASINDA
//! PAYLAŞILAN ABI/bellek-düzeni sabitleri — P1.2'nin TEK doğruluk kaynağı.
//!
//! **Neden bu dosya var:** `compiler/codegen_qbe/` bu sabitlere göre HAM
//! bayt ofsetleri İÇEREN QBE IR yayınlar (ör. `sub ptr, 8` — ARC refcount
//! başlığına erişim); `runtime/` (AYRI bir Zig modülü, `noxrt.o`ya derlenip
//! HER derlenmiş Nox programına bağlanır) bu AYNI düzenleri, bazı düşük
//! seviye yardımcı fonksiyonlarda (ör. `list[T]`in ham bayt düzenini elle
//! üreten `nox_strings_split_raw`/`buildPtrList`/`nox_dict_keys` gibi)
//! BAĞIMSIZ olarak YENİDEN üretir. İKİ TARAF da AYRI Zig modülleri
//! olduğundan (derleyici `nox_mod`, çalışma zamanı `noxrt_mod` — `build.zig`
//! içinde birbirinden BAĞIMSIZ), ÖNCEDEN bu sayılar HER İKİ tarafta da
//! bağımsız birer literal olarak tekrarlanıyordu — biri değişip DİĞERİ
//! GÜNCELLENMEZSE bellek bozulmasına yol açacak SESSİZ bir sürüklenme
//! riskiydi. Bu dosya, İKİ tarafın da `@import("abi_layout")` İLE
//! erişebileceği ÜÇÜNCÜ, bağımsız bir modül (`build.zig`de HEM `nox_mod`
//! HEM `noxrt_mod`a import olarak verilir) — HİÇBİR ŞEY import ETMEZ (ne
//! `std`, ne AST), yalnızca saf sayısal sabitler taşır.
//!
//! `compiler/codegen_qbe/types.zig` bu sabitleri AYNI adlarla RE-EXPORT
//! eder (15 codegen alt modülünün HİÇBİRİ değişmeden kalsın diye — hepsi
//! zaten `types.X` üzerinden erişiyordu). `runtime/`de `arc.zig`/
//! `cycle_detector.zig`/`stdlib_shims/*.zig`/`collections/dict.zig`
//! doğrudan `@import("abi_layout")` ile tüketir.

// ---- ARC (Katman 2) refcount başlığı ----

/// Her ARC nesnesinin payload'ından (kullanıcı kodunun gördüğü işaretçi)
/// HEMEN ÖNCE taşıdığı görünmez refcount alanının bayt boyutu. Runtime
/// tarafında `runtime/alloc/arc.zig`nin `nox_rc_alloc`/`nox_rc_retain`/
/// `nox_rc_predecrement`/`nox_rc_release`/`nox_rc_free_payload`si VE
/// `runtime/alloc/cycle_detector.zig`nin `refcountOf`u BUNA dayanır;
/// derleyici tarafında codegen'in inline retain/predecrement'i
/// (`ownership.zig`, `sub ptr, 8`) VE string-literal payload ofseti
/// (`expr.zig`nin `emitStringLiteral`ı, `add sym, 8`) BUNA dayanır.
pub const ARC_HEADER_SIZE: usize = 8;

/// Pinned string literal hilesi (1<<30): derleyicinin `.data $strN`
/// bölümündeki her string literalinin refcount alanına yazdığı başlangıç
/// değeri — `nox_rc_predecrement` pratikte HİÇBİR gerçekçi programda bu
/// değere ulaşamaz, bu yüzden statik string literalleri hiçbir zaman
/// serbest bırakılmaya çalışılmaz.
///
/// **Karıştırılmamalı:** `runtime/hpy_bridge/context.zig`nin AYNI sayısal
/// değere sahip KENDİ `PINNED_REFCOUNT`si TAMAMEN ALAKASIZDIR — HPy'nin
/// kendi (CPython singleton'larını taklit eden) `Obj` sistemi, Nox'un ARC
/// düzeniyle HİÇBİR paylaşılan ABI'ye sahip değildir; BİRLEŞTİRİLMEMELİDİR.
pub const PINNED_REFCOUNT: i64 = 1 << 30; // 1073741824

// ---- `str` başlığı: { refcount: i64 @-8 (ARC_HEADER_SIZE), packed: i64 @0, baytlar @8...NUL } ----

/// `str`nin KENDİ (ARC refcount başlığından SONRA, `list[T]`nin `len`/`cap`
/// başlığıyla AYNI KATMANLAMA deseni) ek başlığı — TEK bir paketlenmiş
/// `i64`: alt `STR_LENGTH_BITS` bit HAM BAYT uzunluğu, üst 2 bit ascii-
/// durumu (`STR_ASCII_*`). `list[T]`nin AKSİNE (`list_ptr == payload_ptr`,
/// elemanlar `LIST_HEADER_SIZE`den SONRA başlar), `str_ptr` bu paketlenmiş
/// alanın KENDİSİNİ DEĞİL, HEMEN ARDINDAKİ baytları gösterir (`str_ptr =
/// arc_payload_ptr + STR_HEADER_SIZE`) — BU KASITLI: `str_ptr` HÂLÂ
/// GEÇERLİ, NUL-sonlandırılmış bir C bayt dizisine işaret eder, `extern
/// def`/HPy geçişinin "zaten sıfır-sonlandırılmış, dönüşüm YOK" varsayımı
/// KORUNUR. Runtime tarafında `runtime/str.zig`nin TÜM str-üreten
/// fonksiyonları (`nox_str_concat`/`nox_int_to_str`/`nox_str_char_at`/vb.)
/// VE `nox_str_release`/`free_now` (`arc_ptr = str_ptr - STR_HEADER_SIZE`
/// hesaplayıp GENEL `arc.*` fonksiyonlarını BUNUN üzerinde çağırır)
/// BUNA dayanır; derleyici tarafında `expr.zig`nin `emitStringLiteral`ı
/// VE string-literal `.data $strN` yayını (`codegen.zig`) BUNA dayanır.
pub const STR_HEADER_SIZE: usize = 8;

/// Paketlenmiş `str` başlık alanının alt kaç biti HAM BAYT uzunluğuna
/// ayrılmış — kalan üst 2 bit `STR_ASCII_*` durumuna. 61 bit, pratikte
/// ulaşılamayacak kadar büyük bir üst sınır (2^61 bayt) sağlar.
pub const STR_LENGTH_BITS: u6 = 61;
pub const STR_LENGTH_MASK: u64 = (1 << STR_LENGTH_BITS) - 1;
pub const STR_ASCII_SHIFT: u6 = STR_LENGTH_BITS;

/// ASCII-durumu ÜÇ değerli (iki bit): henüz ÇÖZÜMLENMEMİŞ (`UNKNOWN` —
/// yapıcı fonksiyon ascii-liği SIFIR maliyetle BİLEMEDİĞİNDE, ör. keyfi
/// baytlardan `dupeToNoxStr` İLE kopyalama), KESİN ascii, KESİN ascii-
/// DEĞİL. `runtime/str.zig`nin `nox_str_ensure_ascii`si `UNKNOWN`ı BİR
/// KEZ çözüp SONUCU bu alana YAZARAK önbellekler (bkz. onun belge notu —
/// bu yazma ATOMİK OLMAK ZORUNDA DEĞİLDİR, Nox'un ARC nesneleri ASLA
/// gerçek paralel erişime açılmaz, `runtime/alloc/asap.zig`nin
/// `arc_owner_tid` belge notuna bkz.).
pub const STR_ASCII_UNKNOWN: u64 = 0;
pub const STR_ASCII_TRUE: u64 = 1;
pub const STR_ASCII_FALSE: u64 = 2;

/// `runtime/str.zig` VE derleyicinin `emitStringLiteral`ı (derleme
/// ZAMANINDA bir literal İçin) TARAFINDAN PAYLAŞILAN, TEK bir paketleme
/// noktası — iki taraf ayrı ayrı bit-aritmetiği TEKRARLAMAZ.
pub fn packStrHeader(byte_len: u64, ascii_state: u64) i64 {
    return @bitCast((byte_len & STR_LENGTH_MASK) | (ascii_state << STR_ASCII_SHIFT));
}

pub fn unpackStrLength(packed_header: i64) u64 {
    const bits: u64 = @bitCast(packed_header);
    return bits & STR_LENGTH_MASK;
}

pub fn unpackStrAsciiState(packed_header: i64) u64 {
    const bits: u64 = @bitCast(packed_header);
    return bits >> STR_ASCII_SHIFT;
}

// ---- `list[T]` başlığı: { len: i64 @0, cap: i64 @8, elemanlar @16... } ----

/// `list[T]`nin (ARC payload'ının KENDİSİ) başlık bayt boyutu. Runtime
/// tarafında `runtime/stdlib_shims/json.zig`nin `buildPtrList`i,
/// `runtime/stdlib_shims/strings.zig`nin `nox_strings_split_raw`ı/
/// `buildStrList`i, `runtime/stdlib_shims/path.zig`nin
/// `nox_path_components_raw`ı, `runtime/stdlib_shims/fs.zig`nin
/// `nox_fs_read_dir_raw`ı VE `runtime/collections/dict.zig`nin
/// `buildEntryList`i (`nox_dict_keys`/`nox_dict_values`) AYNI düzeni EL
/// İLE ürettiğinden BU SABİTLE TUTARLI kalmalıdır.
pub const LIST_HEADER_SIZE: usize = 16;

// ---- Sınıf örneği düzeni (ARC payload'ından SONRA) ----

/// Sınıf örneğinin (refcount başlığından SONRA) ilk `TAG_SIZE` baytındaki
/// tip etiketi — çalışma zamanında `except ClassName:` eşleştirmesi İçin
/// (bkz. `runtime/alloc/cycle_detector.zig`nin `readTag`ı, derleyici
/// tarafında `exceptions.zig`nin except-dispatch'i).
pub const TAG_SIZE: usize = 8;

/// Her sınıf alanı, GERÇEK genişliğinden (QBE `w`/4 bayt DAHİL) bağımsız
/// olarak TAM 8 bayt yuva kaplar — `registration.zig`nin `registerClass`ı
/// alan ofsetlerini `TAG_SIZE + index * FIELD_SLOT_SIZE` İLE hesaplar.
pub const FIELD_SLOT_SIZE: usize = 8;

/// Faz 7 (tekli kalıtım): kalıtıma KATILAN (taban YA DA türetilen) her
/// sınıfın örneğine `TAG_SIZE`den HEMEN SONRA, alanlardan ÖNCE eklenen
/// EK bir 8 baytlık yuva — bu sınıfın (somut, çalışma-zamanı) vtable veri
/// bloğuna (`$ClassName_vtable`, `layout.zig`) İŞARET EDER. Kalıtıma HİÇ
/// KATILMAYAN (v1 Nox kodunun BÜYÜK ÇOĞUNLUĞU) sınıflar bu yuvaya SAHİP
/// DEĞİLDİR — alanları HÂLÂ doğrudan `TAG_SIZE`den başlar (BİREBİR ÖNCEKİ
/// düzen, SIFIR performans/boyut regresyonu). `TAG_SIZE` İLE
/// KARIŞTIRILMAMALI: TAG HER ZAMAN VARDIR (çalışma-zamanı tip etiketi,
/// `except`/döngü-çözücü İçin), vtable-işaretçisi İSE SADECE kalıtım
/// KULLANILDIĞINDA vardır — İKİSİ AYRI ABI gerçekleridir (`CLOSURE_
/// RELEASE_FN_PTR_OFFSET`in modül-üstü notundaki AYNI "sayısal çakışma
/// ≠ aynı anlam" uyarısı burada da geçerli).
pub const VTABLE_PTR_SIZE: usize = 8;

// ---- Closure heap bloğu: { fn_ptr: l @0, release_fn_ptr: l @8, yakalananlar @16+ } ----

/// Closure heap bloğunun başlık bayt boyutu — `fn_ptr` + `release_fn_ptr`,
/// HER İKİSİ de 8 bayt. Yakalanan değerler bu ofsetten İTİBAREN sırayla
/// yerleştirilir.
pub const CLOSURE_HEADER_SIZE: usize = 16;

/// Closure bloğunun İKİNCİ header alanının (release fonksiyon işaretçisi)
/// ofseti — `ARC_HEADER_SIZE` İLE SAYISAL olarak ÇAKIŞIR ama TAMAMEN AYRI
/// bir ABI gerçeğidir (bir closure'ın İÇ düzeni, refcount başlığı DEĞİL) —
/// bilinçli olarak AYRI adlandırılır ki biri değişirse diğeri SESSİZCE
/// bozulmasın. `runtime/alloc/defer_stack.zig`nin `nox_defer_stack_run_all`ı
/// bu ofseti `header[1]` (bir `[*]?*anyopaque` dizisi üzerinden, dolaylı
/// olarak) okur.
pub const CLOSURE_RELEASE_FN_PTR_OFFSET: usize = 8;

// ---- Döngü-çözücü trace-buffer'ı: { len: i64 @0, çocuk ptr'leri @8... } ----
// (Derleyici tarafı: `layout.zig`nin `genClassTrace`/`genTraceDispatch`si;
// çalışma zamanı tarafı: `cycle_detector.zig`nin `traceChildren`i.) Bu İKİ
// alan da `ARC_HEADER_SIZE` İLE SAYISAL olarak ÇAKIŞIR (ikisi de tek bir
// `i64` yuvası) ama AYRI bir ABI gerçeğidir — sınıf/liste/closure'ın KENDİ
// heap bloğu DEĞİL, `nox_trace_dispatch`in DÖNDÜRDÜĞÜ GEÇİCİ bir arabellek.

/// Trace-buffer'ın uzunluk ön-eki bayt boyutu (kaç çocuk işaretçisi olduğu).
pub const TRACE_BUF_LEN_SIZE: usize = 8;
/// Trace-buffer'daki HER çocuk işaretçi yuvasının bayt boyutu.
pub const TRACE_BUF_SLOT_SIZE: usize = 8;
