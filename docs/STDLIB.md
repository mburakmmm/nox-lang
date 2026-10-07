# Nox standart kütüphane başvurusu

Bu dosya `scripts/gen_stdlib_docs.py` ile `stdlib/nox/*.nox`ten ÜRETİLİR (elle düzenlemeyin). Her modül `import nox.<ad>` ile kullanılır;
`nox.core` her programa otomatik dahildir. Ayrıntılar için modülün kaynak dosyasındaki yorumlara bakın.

## İçindekiler

- [`nox.atomic`](#noxatomic)
- [`nox.base64`](#noxbase64)
- [`nox.binary`](#noxbinary)
- [`nox.bits`](#noxbits)
- [`nox.buffer`](#noxbuffer)
- [`nox.collections`](#noxcollections)
- [`nox.console`](#noxconsole)
- [`nox.core`](#noxcore)
- [`nox.crypto`](#noxcrypto)
- [`nox.csv`](#noxcsv)
- [`nox.db`](#noxdb)
- [`nox.fs`](#noxfs)
- [`nox.gzip`](#noxgzip)
- [`nox.http`](#noxhttp)
- [`nox.json`](#noxjson)
- [`nox.jwt`](#noxjwt)
- [`nox.log`](#noxlog)
- [`nox.math`](#noxmath)
- [`nox.mathx`](#noxmathx)
- [`nox.mem`](#noxmem)
- [`nox.mysql`](#noxmysql)
- [`nox.orm`](#noxorm)
- [`nox.os`](#noxos)
- [`nox.path`](#noxpath)
- [`nox.postgres`](#noxpostgres)
- [`nox.process`](#noxprocess)
- [`nox.random`](#noxrandom)
- [`nox.reflect`](#noxreflect)
- [`nox.regex`](#noxregex)
- [`nox.router`](#noxrouter)
- [`nox.sharedmem`](#noxsharedmem)
- [`nox.smtp`](#noxsmtp)
- [`nox.sqlite`](#noxsqlite)
- [`nox.strings`](#noxstrings)
- [`nox.template`](#noxtemplate)
- [`nox.test`](#noxtest)
- [`nox.testmod`](#noxtestmod)
- [`nox.thread`](#noxthread)
- [`nox.time`](#noxtime)
- [`nox.tls`](#noxtls)
- [`nox.toml`](#noxtoml)
- [`nox.url`](#noxurl)
- [`nox.uuid`](#noxuuid)
- [`nox.validate`](#noxvalidate)
- [`nox.websocket`](#noxwebsocket)
- [`nox.yaml`](#noxyaml)

## `nox.atomic`

Aether NOX_LIMITATIONS.md yol haritası, Faz B.1 (bkz. nox-teknik- spesifikasyon.md ilgili bölüm, madde 12'nin SINIRLI/güvenli çözümü): `nox.atomic` — multicore worker'lar (`nox.thread.start`/`serve_mu

- `class AtomicError(Exception)`
- `class AtomicInt`
  - `def load(self: AtomicInt) -> int`
- `class AtomicBool`
  - `def load(self: AtomicBool) -> bool`
- `def new_int(initial: int) -> AtomicInt`
- `def new_bool(initial: bool) -> AtomicBool`
- `def from_int_handle(h: int) -> AtomicInt`
- `def from_bool_handle(h: int) -> AtomicBool`

## `nox.base64`

Aether NOX_LIMITATIONS.md yol haritası, Faz A.1 (bkz. nox-teknik- spesifikasyon.md ilgili bölüm) — `nox.base64`: standart + URL-safe base64 encode/decode.

- `class Base64Error(Exception)`
- `def encode(data: str) -> str` — Standart base64 (RFC 4648 §4) — `+`/`/` alfabesi, `=` dolgulu.
- `def encode_url(data: str) -> str` — URL-safe base64 (RFC 4648 §5) — `-`/`_` alfabesi, dolgu YOK (JWT'nin KENDİ sözleşmesiyle TUTARLI, bkz. `nox.jwt`).
- `def decode(s: str) -> str` — HEM standart HEM URL-safe (HEM dolgulu HEM dolgusuz) girdiyi kabul eder — `_char_value`nin belge notuna bkz.

## `nox.binary`

BinaryReader/BinaryWriter (ELF/PCI/ACPI/ağ paketi/dosya- sistemi GİBİ ikili formatları `ptr_read`/`ptr_write` KULLANMADAN ERGONOMİK ayrıştırmayı/üretmeyi hedefler).

- `class BinaryReader`
  - `def position(self: BinaryReader) -> int`
- `class BinaryWriter`
  - `def position(self: BinaryWriter) -> int`

## `nox.bits`

mask/rotate/endian yardımcıları.

- `def rotl_u8(x: u8, n: int) -> u8`
- `def rotr_u8(x: u8, n: int) -> u8`
- `def rotl_u16(x: u16, n: int) -> u16`
- `def rotr_u16(x: u16, n: int) -> u16`
- `def rotl_u32(x: u32, n: int) -> u32`
- `def rotr_u32(x: u32, n: int) -> u32`
- `def rotl_u64(x: u64, n: int) -> u64`
- `def rotr_u64(x: u64, n: int) -> u64`
- `def swap16(x: u16) -> u16` — Bayt sırasını TERSİNE çevirir (endian SWAP) — `to_be_*`/`from_be_*`nin (AŞAĞIDA) temel yapı taşı.
- `def swap32(x: u32) -> u32`
- `def swap64(x: u64) -> u64`
- `def to_le16(x: u16) -> u16` — Little-endian <-> yerel dönüşüm — Nox'un ŞU ANKİ TÜM hedefleri (amd64/arm64/riscv64, bkz. v2.0 madde 8'in `--target` desteği) KÜÇÜK- UÇLU (little-endian) OLDUĞUNDAN bunlar BUGÜN birer NO-OP'tur — AMA 
- `def from_le16(x: u16) -> u16`
- `def to_le32(x: u32) -> u32`
- `def from_le32(x: u32) -> u32`
- `def to_le64(x: u64) -> u64`
- `def from_le64(x: u64) -> u64`
- `def to_be16(x: u16) -> u16` — Big-endian <-> yerel dönüşüm — KÜÇÜK-uçlu hedeflerde `swap_*` İLE AYNI.
- `def from_be16(x: u16) -> u16`
- `def to_be32(x: u32) -> u32`
- `def from_be32(x: u32) -> u32`
- `def to_be64(x: u64) -> u64`
- `def from_be64(x: u64) -> u64`
- `def mask(n: int) -> int` — `(1 << n) - 1` — alt `n` bitin TAMAMI 1 olan bir maske (ör. `mask(3)` == `0b111` == 7).
- `def test_bit(x: int, pos: int) -> bool`
- `def set_bit(x: int, pos: int) -> int`
- `def clear_bit(x: int, pos: int) -> int`
- `def toggle_bit(x: int, pos: int) -> int`

## `nox.buffer`

sahip OLUNAN (owned) bayt arabelleği.

- `class Span`
  - `def len(self: Span) -> int`
- `class Buffer`
  - `def len(self: Buffer) -> int`

## `nox.collections`

genel amaçlı veri yapıları (Stack/Queue/Deque/Set/ Counter/OrderedDict/LRUCache/Heap/PriorityQueue), TAMAMEN saf Nox (extern def YOK) — `class Foo[T, ...]:` (Faz P2.1, ARİTE-GENEL generic sınıflar) üz

- `class Stack[T]` — Stack[T] — LIFO, dogrudan list[T] uzerinde.
  - `def push(self: Stack, v: T) -> None`
- `class Queue[T]` — Queue[T] — FIFO, klasik "iki-yigin" hilesiyle amortize O(1) (bkz. modul basligi).
  - `def push(self: Queue, v: T) -> None`
- `class Deque[T]` — Deque[T] — her iki ucta da amortize O(1), Queue'nun IKI-YONLU hali: `front`/`back` iki liste, biri bosaldiginda DIGERININ TAMAMI (ters sirada) aktarilir.
  - `def push_front(self: Deque, v: T) -> None`
- `class Set[T]` — Set[T] — dogrusal tarama (bkz. modul basligi), HERHANGI bir T icin dogru (siniflar DAHIL).
  - `def contains(self: Set, v: T) -> bool`
- `class Counter[T]` — Counter[T] — paralel anahtar/sayac listeleri, dogrusal tarama.
  - `def add(self: Counter, v: T) -> None`
- `class OrderedDict[K, V]` — OrderedDict[K, V] — paralel anahtar/deger listeleri, ekleme SIRASINI dogal olarak korur (dogrusal tarama, `dict`in K/V kisitindan BAGIMSIZ herhangi bir K/V icin calisir).
  - `def contains(self: OrderedDict, k: K) -> bool`
- `class LRUCache[K, V]` — LRUCache[K, V] — OrderedDict'in AYNI dogrusal-tarama deseni + sabit `capacity`.
  - `def contains(self: LRUCache, k: K) -> bool`
- `class Heap[T]` — Heap[T] — ikili min-heap (index aritmetigi), T yalnizca `<` destekleyen tiplerle (int/float/str) somutlastirilabilir (bkz. modul basligi — EK bir kisit kodu YOK, dilin operator tip kontrolu yeterli).
  - `def size(self: Heap) -> int`
- `class PriorityQueue[T]` — PriorityQueue[T] — Heap'ten BAGIMSIZ, ayri bir `priority: int` alanina gore siralanir — T KEYFI olabilir (siniflar DAHIL) cunku T uzerinde HIC karsilastirma yapilmaz.
  - `def size(self: PriorityQueue) -> int`

## `nox.console`

v4 Faz B (bkz. nox-teknik-spesifikasyon.md §3.2xx) — `nox.console`: `nox.log` İLE AYNI seviyeli ("[DEBUG]"/"[INFO]"/"[WARN]"/"[ERROR]") konsol günlükleme biçimi, AMA ZAMAN DAMGASI YOK — BU YÜZDEN `nox

- `def format(level: str, message: str) -> str`
- `def debug(message: str) -> None`
- `def info(message: str) -> None`
- `def warn(message: str) -> None`
- `def error(message: str) -> None`

## `nox.core`

Çekirdek yerleşikler — HİÇBİR `import` GEREKMEDEN her programa otomatik birleştirilir (bkz. `compiler/module_loader.zig`'in `resolveImports`ı, stdlib fazı §E).

- `class Exception` — Faz OO.3 (bkz. nox-teknik-spesifikasyon.md §3.84): TÜM `raise` edilebilir sınıfların ORTAK taban sınıfı — `except Exception:` İLE programdaki HERHANGİ bir istisnayı (hangi modülden gelirse gelsin) tek
- `class ValueError(Exception)`
- `class IndexError(Exception)`
- `class KeyError(Exception)` — Güvenlik bulgusu H-2 (bkz. güvenlik raporu) — `d[key]`nin eksik bir anahtarda SESSİZCE `0`/null DÖNDÜRDÜĞÜ (Python'un `KeyError`ı YOK denen v1 kararı) GERÇEKTE bir null-pointer çökmesiydi: dönen değer
- `class HPyError(Exception)` — Faz 18 (bkz. plan dosyası "HPy köprüsünü Nox'un istisna mekanizmasına entegre etme"): `hpy_call`/`hpy_open`/`hpy_call_on`/vb.nin (bkz. runtime/foreign_bridge.zig'in `setHpyError`/`nox_hpy_take_error`s
- `class CancelledError(Exception)` — Faz SC.2 (bkz. nox-teknik-spesifikasyon.md, "Task[T].cancel()"): `t.
- `class JsonValue` — Stdlib fazı §L (`nox.json`, bkz. nox-teknik-spesifikasyon.md) — `JsonValue` ve onun fabrika fonksiyonu BİLİNÇLİ OLARAK burada, `stdlib/nox/json.nox` YERİNE, ÇEKİRDEKTE tanımlanır: `runtime/stdlib_shim
- `def nox_json_make_json_value(kind: int, b: bool, n: float, s: str, arr: list[JsonValue], keys: list[str], vals: list[JsonValue]) -> JsonValue`
- `def input() -> str` — v1 kapsamı: Python'ın `input(prompt)`inin AKSİNE argümansızdır — bir `prompt` isteyen çağıran taraf ÖNCE `print(prompt)` çağırabilir.
- `def abs[T](x: T) -> T`
- `def min[T](a: T, b: T) -> T` — v1 kapsamı: yalnızca İKİ argüman (Nox'ta fonksiyon overload'u/değişken sayıda argüman YOK, Python'ın iterable-alan `min(xs)` formu desteklenmez).
- `def max[T](a: T, b: T) -> T`
- `def round(x: float) -> int` — v1 kapsamı: yalnızca `float -> int` (Python'ın `ndigits` parametresi YOK).
- `def sum(xs: list[int]) -> int` — v1 kapsamı: `sum`/`sum_float` AYRI adlarla (Nox'ta dönüş-tipine göre overload YOK — `total = 0` ile `total = 0.0` FARKLI somut başlangıç qtype'ları gerektirdiğinden TEK bir generic `sum[T]` yazılamaz)
- `def sum_float(xs: list[float]) -> float`
- `def sorted[T](xs: list[T]) -> list[T]` — v1.150.0 (list tam API): `sorted(xs)` yeni, sıralanmış bir liste döner (orijinal değişmez; `sort()` gibi yalnızca list[int]/list[float]/list[str] için).
- `def reversed[T](xs: list[T]) -> list[T]`
- `def enumerate[T](xs: list[T]) -> list[tuple[int, T]]`
- `def zip[A, B](a: list[A], b: list[B]) -> list[tuple[A, B]]`

## `nox.crypto`

Stdlib fazı V.3 — nox.crypto: SHA-256 (asgari kapsam).

- `class CryptoError(Exception)` — v3 sertleştirme yol haritası, madde 10 (bkz. nox-teknik-spesifikasyon.md ilgili bölüm, stdlib/API denetimi): `nox.crypto`, benzer TÜM I/O-benzeri stdlib modüllerinin (`nox.fs`/`nox.json`/`nox.sqlite`/
- `def sha256(data: str) -> str`
- `def sha1(data: str) -> str` — GÜVENLİK UYARISI (bulgu M-4, bkz. güvenlik raporu, 20 Temmuz 2026): SHA-1, 2017'den beri (SHAttered) PRATİK çakışma saldırılarına AÇIKTIR — bütünlük/imza DOĞRULAMASI İçin KULLANILMAMALIDIR (yalnızca E
- `def sha512(data: str) -> str`
- `def hmac_sha256(key: str, data: str) -> str` — `key` İLE `data`nın HMAC-SHA256'sı (küçük harf hex, 64 karakter) — `sha256`nin AKSİNE bir paylaşılan GİZLİ anahtar gerektirir, bu YÜZDEN mesaj bütünlüğü/kimlik DOĞRULAMASI İçin GÜVENLİDİR (saldırgan a
- `def constant_time_eq(a: str, b: str) -> bool` — İKİ dizeyi ZAMAN-SABİT (constant-time) karşılaştırır — bir belirteç/ parola-özeti/HMAC doğrulaması yaparken `==` YERİNE BUNU kullanın: `==` ilk FARKLI bayta rastlayınca DURDUĞUNDAN, bir saldırgan yanı
- `def secure_random_hex(n_bytes: int) -> str`
- `def argon2_hash(password: str) -> str`
- `def argon2_verify(hash: str, password: str) -> bool` — `argon2_hash`nin ürettiği bir hash'e karşı bir parolayı doğrular.
- `def bcrypt_hash(password: str) -> str`
- `def bcrypt_verify(hash: str, password: str) -> bool`
- `def scrypt_hash(password: str) -> str`
- `def scrypt_verify(hash: str, password: str) -> bool`

## `nox.csv`

RFC 4180 uyumlu CSV ayrıştırma/yazma.

- `class CsvError(Exception)`
- `def parse(text: str) -> list[list[str]]` — `text`i satır/sütunlara ayırır — HER satır `list[str]`, tüm satırlar `list[list[str]]`.
- `def parse_dicts(text: str) -> list[dict[str, str]]` — İLK satırı başlık olarak kullanıp SONRAKİ HER satırı `dict[str,str]`e çevirir (eksik sütunlar İçİn `""`) — pratik kullanım İçİn bir kolaylık katmanı.
- `def dump_row(fields: list[str]) -> str` — v3 sertleştirme yol haritası, madde 10 (bkz. nox-teknik-spesifikasyon.md ilgili bölüm, stdlib/API denetimi): `write`/`write_row` (v1.110.4'e kadarki isimler) `dump`/`dump_row` OLARAK YENİDEN ADLANDIRI
- `def dump(rows: list[list[str]]) -> str`
- `def write(rows: list[list[str]]) -> str` — --- KULLANIMDAN KALDIRILMIŞ (deprecated) takma adlar --- v3 sertleştirme yol haritası, madde 10 (bkz. nox-teknik-spesifikasyon.md ilgili bölüm) — `write`/`write_row`, `dump`/`dump_row` OLARAK yeniden 
- `def write_row(fields: list[str]) -> str`

## `nox.db`

Faz NN.4 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması", limitasyon #1'in "ortak Connection tipi yok" kısmı): Nox'ta inheritance YOK ama YAPISAL (duck-typed) `protocol` VAR (bkz. AGENTS.m

- `class Row` — Faz NN.4 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması", limitasyon #1'in "ortak Connection tipi yok" kısmı): Nox'ta inheritance YOK ama YAPISAL (duck-typed) `protocol` VAR (bkz. AGENTS.m
  - `def get_str(self: Row, i: int) -> str`
- `class Statement` — Faz STD.6 (bkz. plan dosyası "nox.orm"): `Row`nun AYNI birleştirme ilkesi — sqlite/postgres/mysql'in ÜÇÜNÜN de `Statement`i YAPISAL olarak BİREBİR AYNIYDI (bind_int/float/str/null(idx,value) + execute
  - `def bind_int(self: Statement, idx: int, value: int) -> None`

## `nox.fs`

Stdlib fazı §J — bkz. nox-teknik-spesifikasyon.md.

- `class FsError(Exception)`
- `def read_to_string(path: str) -> str`
- `def write_string(path: str, content: str) -> None`
- `def append_string(path: str, content: str) -> None` — Faz III.3 — `write_string`nin AKSİNE dosyayı KISALTMAZ, `content`i SONUNA ekler.
- `def exists(path: str) -> bool`
- `def is_file(path: str) -> bool`
- `def is_dir(path: str) -> bool`
- `class FileMetadata` — Faz III.3 — `DateTime`nin (bkz. `stdlib/nox/time.nox`) AYNI Nox-tarafı sınıf inşa deseni: Zig SKALER int'ler döner (`nox_fs_stat_raw` TEK bir `open`+`fstat`+`close` yapıp sonucu ÖNBELLEKLER), Nox SIRA
- `def metadata(path: str) -> FileMetadata`
- `def read_dir(path: str) -> list[str]` — `.`/`..` HARİÇ dizin girdi ADLARI (tam yol DEĞİL — Python'un `os.listdir`/Rust'ın `read_dir`iyle TUTARLI).
- `def copy(src: str, dst: str) -> None`
- `def rename(old: str, new: str) -> None`
- `def remove_file(path: str) -> None`
- `def create_dir(path: str) -> None`

## `nox.gzip`

gzip sıkıştırma/açma.

- `class GzipError(Exception)`
- `def compress_bytes(data: list[int]) -> list[int]` — Keyfi ikili veriyi (`list[int]`, HER eleman 0-255) gzip formatında sıkıştırır.
- `def decompress_bytes(data: list[int]) -> list[int]` — gzip-sıkıştırılmış `list[int]`i ORİJİNAL (keyfi ikili) baytlara açar.
- `def compress(text: str) -> list[int]` — Bir metni gzip formatında sıkıştırıp `list[int]` olarak döner.
- `def decompress(data: list[int]) -> str` — gzip-sıkıştırılmış `list[int]`i AÇIP bir `str`e çevirir — açılan verinin gömülü NUL bayt İçERMEDİĞİ (Nox'un NUL-sonlandırmalı `str` temsili İçİn GÜVENLİ olduğu) DOĞRULANIR, aksi halde `GzipError` fırl

## `nox.http`

- `class HttpError(Exception)`
- `class HttpResponse`
- `class HttpRequest` — stdlib fazı §D.1.6: `nox.http.serve`in `handle` çağrı sitesine geçtiği istek nesnesi — alan SIRASI (method, target, body, headers, peer_addr) codegen'in `genHttpServeWrapper`ının HANGİ `nox_http_reque
- `def listen(port: int) -> int`
- `def listen_v6(port: int, v6_only: bool) -> int`
- `def get(url: str, headers: dict[str, str]) -> HttpResponse`
- `def post(url: str, body: str, headers: dict[str, str]) -> HttpResponse`

## `nox.json`

Stdlib fazı §L — bkz. nox-teknik-spesifikasyon.md.

- `class JsonError(Exception)`
- `def parse(s: str) -> JsonValue`
- `def is_null(v: JsonValue) -> bool`
- `def is_bool(v: JsonValue) -> bool`
- `def is_number(v: JsonValue) -> bool`
- `def is_string(v: JsonValue) -> bool`
- `def is_array(v: JsonValue) -> bool`
- `def is_object(v: JsonValue) -> bool`
- `def as_bool(v: JsonValue) -> bool`
- `def as_number(v: JsonValue) -> float`
- `def as_string(v: JsonValue) -> str`
- `def array_len(v: JsonValue) -> int`
- `def array_get(v: JsonValue, i: int) -> JsonValue`
- `def object_len(v: JsonValue) -> int`
- `def object_key(v: JsonValue, i: int) -> str`
- `def object_value(v: JsonValue, i: int) -> JsonValue`
- `def dump_string(s: str) -> str` — Faz II devamı (bkz. nox-teknik-spesifikasyon.md §3.67, test kapsamı genişletmesi sırasında BULUNAN, GERÇEK bir düzeltme) — ÖNCEKİ sürüm yalnızca `"`/`\`/`\n`i escape ediyordu; bir `\t` (VEYA CR baytı)
- `def dump(v: JsonValue) -> str`
- `def dump_array(v: JsonValue) -> str`
- `def dump_object(v: JsonValue) -> str`
- `def indent_str(indent: int, level: int) -> str` — Faz III.10 (bkz. nox-teknik-spesifikasyon.md §3.69) — `dump_pretty`: `dump`in girintili varyantı, SAF Nox (HİÇ runtime değişikliği GEREKMEDİ, `nox.strings.repeat` — Faz III.2 — İLE girinti dizeleri ür
- `def dump_pretty(v: JsonValue, indent: int) -> str`
- `def dump_pretty_at(v: JsonValue, indent: int, level: int) -> str`
- `def dump_pretty_array(v: JsonValue, indent: int, level: int) -> str`
- `def dump_pretty_object(v: JsonValue, indent: int, level: int) -> str`
- `def decode(s: str) -> JsonValue` — --- KULLANIMDAN KALDIRILMIŞ (deprecated) takma adlar --- v3 sertleştirme yol haritası, madde 10 (bkz. nox-teknik-spesifikasyon.md ilgili bölüm): `decode`/`encode`/`encode_pretty`, `parse`/`dump`/ `dum
- `def encode(v: JsonValue) -> str`
- `def encode_pretty(v: JsonValue, indent: int) -> str`
- `def encode_string(s: str) -> str` — v3 sertleştirme yol haritası, madde 12 (RC + release qualification) — GERÇEK bir üretim hatası burada bulunup düzeltildi: `encode_array`/ `encode_object`/`encode_pretty_at`/`encode_pretty_array`/`enco
- `def encode_array(v: JsonValue) -> str`
- `def encode_object(v: JsonValue) -> str`
- `def encode_pretty_at(v: JsonValue, indent: int, level: int) -> str`
- `def encode_pretty_array(v: JsonValue, indent: int, level: int) -> str`
- `def encode_pretty_object(v: JsonValue, indent: int, level: int) -> str`
- `class JsonWriter` — Aether NOX_LIMITATIONS.md yol haritası, Faz A.4 (bkz. nox-teknik- spesifikasyon.md ilgili bölüm, madde 18): `JsonWriter` — bir HTTP yanıt gövdesi gibi büyük bir JSON belgesini, ÖNCE bir `JsonValue` ağ
  - `def write_key(self: JsonWriter, key: str) -> None`

## `nox.jwt`

Aether NOX_LIMITATIONS.md yol haritası, Faz A.1 (bkz. nox-teknik- spesifikasyon.md ilgili bölüm) — `nox.jwt`: HS256 (HMAC-SHA256) JWT imzalama/doğrulama.

- `class JwtError(Exception)`
- `def sign(payload_json: str, secret: str) -> str` — `payload_json` (ÖNCEDEN `nox.json.dump(...)` İLE serileştirilmiş) İçin bir HS256 JWT ÜRETİR — `<base64url(header)>.<base64url(payload)>.
- `def verify(token: str, secret: str) -> str` — `token`i doğrular (imza + başlığın TAM OLARAK `_header()`e eşit olduğu — bkz. modül-üstü not, "alg confusion" önlemi) VE doğrulanmış payload'ı HAM JSON METNİ olarak döner.

## `nox.log`

Stdlib fazı V.1 — nox.log: basit, seviyeli konsol günlükleme.

- `def format(level: str, message: str) -> str`
- `def debug(message: str) -> None`
- `def info(message: str) -> None`
- `def warn(message: str) -> None`
- `def error(message: str) -> None`

## `nox.math`

Stdlib fazı §I — bkz. nox-teknik-spesifikasyon.md.

- `def ln(x: float) -> float`
- `def pi() -> float` — Nox'ta top-level `const` YOK — sabitler, sıradan (mangle edilen, nitelikli çağrılan) fonksiyonlar olarak sunulur: `nox.math.pi()`/ `nox.math.e()`.
- `def e() -> float`
- `def min(a: float, b: float) -> float`
- `def max(a: float, b: float) -> float`
- `def abs(x: float) -> float`

## `nox.mathx`

v4 Faz B, madde 1 SONRASI semver düzeltmesi (bkz. nox-teknik- spesifikasyon.md ilgili bölüm).

- `def sqrt(x: float) -> float`
- `def pow(x: float, y: float) -> float`
- `def floor(x: float) -> float`
- `def ceil(x: float) -> float`
- `def sin(x: float) -> float`
- `def cos(x: float) -> float`
- `def tan(x: float) -> float`
- `def log(x: float) -> float`
- `def exp(x: float) -> float`
- `def atan2(y: float, x: float) -> float`
- `def ln(x: float) -> float`
- `def pi() -> float` — Nox'ta top-level `const` YOK — sabitler, sıradan (mangle edilen, nitelikli çağrılan) fonksiyonlar olarak sunulur: `nox.mathx.pi()`/ `nox.mathx.e()`.
- `def e() -> float`
- `def min(a: float, b: float) -> float`
- `def max(a: float, b: float) -> float`
- `def abs(x: float) -> float`

## `nox.mem`

sistem-programlama için typed pointer toplu bellek işlemleri (copy/move/set) + volatile okuma/yazma cephesi.

- `def copy[T](dst: ptr[T], src: ptr[T], count: int) -> None`
- `def move[T](dst: ptr[T], src: ptr[T], count: int) -> None` — `copy`den FARKI: `dst`/`src` ÇAKIŞAN (overlapping) bellek bölgelerini GÜVENLE ele alır (C'nin `memcpy` vs `memmove` ayrımıyla AYNI gerekçe).
- `def set[T](dst: ptr[T], value: T, count: int) -> None` — `dst`ten başlayarak `count` ADET `T`-boyutlu yuvaya AYNI `value`yi yazar (C'nin `memset`inin, BAYT-granüler DEĞİL TİP-granüler genellemesi).
- `def read_volatile[T](p: ptr[T]) -> T` — `ptr_read_volatile`/`ptr_write_volatile`nin (v2.0 madde 7) İNCE sarmalayıcıları — derleyici optimizasyonlarının (yeniden sıralama/ elemine etme) ATLAMAMASI GEREKEN bellek-eşlemeli G/Ç (MMIO) gibi eriş
- `def write_volatile[T](p: ptr[T], value: T) -> None`

## `nox.mysql`

libmysqlclient'e (ya da ikili-uyumlu MariaDB connector'üne) `std.DynLib` (dlopen/dlsym, ÇALIŞMA ZAMANINDA, TEMBEL) İLE bağlanan bir MySQL/MariaDB sürücüsü — `nox.sqlite`/`nox.postgres`nin BİREBİR AYNI

- `class MysqlError(Exception)`
- `class Connection`
  - `def prepare(self: Connection, sql: str) -> Statement`
- `def open_url(conn_url: str) -> Connection` — `mysql://[user[:pass]@]host[:port]/db` — port belirtilmemişse `3306` (MySQL'in KENDİ varsayılanı) kullanılır.

## `nox.orm`

Faz STD.6 (bkz. plan dosyası "nox.orm"): kullanıcının 5 maddelik yol haritasının 3.

- `class OrmError(Exception)`
- `class Value` — kind: 0=string, 1=int, 2=float, 3=bool, 4=null
- `def val_str(s: str) -> Value`
- `def val_int(i: int) -> Value`
- `def val_float(f: float) -> Value`
- `def val_bool(b: bool) -> Value`
- `def val_null() -> Value`
- `class Column` — col_kind: 0=INTEGER, 1=TEXT, 2=REAL
- `class Table`
- `def create_table_sql(table: Table) -> str`
- `def create_table(conn: DbConnection, table: Table) -> None`
- `def insert(conn: DbConnection, table: Table, values: dict[str, Value]) -> int` — `values`de BULUNMAYAN sütunlar (ör. otomatik-artan birincil anahtar) ATLANIR — INSERT ifadesine hiç dahil edilmez.
- `def update(conn: DbConnection, table: Table, values: dict[str, Value], where_sql: str, where_params: list[Value]) -> int` — `where_sql`e "?" placeholder'ları YAZILIR, `where_params` bunlara KARŞILIK gelen `Value`leri SIRAYLA taşır (ör. `update(conn, t, vals, "id = ?", [orm.val_int(5)])`) — TAMAMEN PARAMETRELİ, DEĞERLER ASL
- `def delete(conn: DbConnection, table: Table, where_sql: str, where_params: list[Value]) -> int`
- `def select(conn: DbConnection, table: Table, where_sql: str, where_params: list[Value]) -> list[Row]`

## `nox.os`

Stdlib fazı §J — bkz. nox-teknik-spesifikasyon.md.

- `class OsError(Exception)`
- `def arg_count() -> int`
- `def arg(i: int) -> str`
- `def getenv(name: str) -> str`
- `def exit(code: int) -> None`
- `def set_var(name: str, value: str) -> None`
- `def current_dir() -> str`

## `nox.path`

Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — SAF yol string manipülasyonu.

- `class PathError(Exception)`
- `def join(a: str, b: str) -> str`
- `def basename(p: str) -> str`
- `def dirname(p: str) -> str`
- `def extension(p: str) -> str`
- `def is_absolute(p: str) -> bool`
- `def canonicalize(p: str) -> str`
- `def strip_prefix(p: str, prefix: str) -> str`
- `def components(p: str) -> list[str]`

## `nox.postgres`

libpq'ya `std.DynLib` (dlopen/dlsym, ÇALIŞMA ZAMANINDA, TEMBEL) İLE bağlanan bir PostgreSQL sürücüsü — `nox.sqlite`nin BİREBİR AYNI şablonu (bkz. proje belleği "4 yeni stdlib modülü" planı): TÜM postg

- `class PostgresError(Exception)`
- `class Connection`
  - `def prepare(self: Connection, sql: str) -> Statement`
- `def open(conninfo: str) -> Connection`

## `nox.process`

alt süreç (subprocess) çalıştırma.

- `class ProcessError(Exception)`
- `class Output`
  - `def success(self: Output) -> bool`
- `class Command`
  - `def arg(self: Command, v: str) -> Command`

## `nox.random`

Stdlib fazı V.2 — nox.random: basit PRNG sarmalayıcısı.

- `def seed(s: int) -> None`
- `def randint(lo: int, hi: int) -> int` — `lo`/`hi` İKİSİ de DAHİLDİR (Python'un `random.randint`iyle TUTARLI).
- `def random() -> float` — `[0.0, 1.0)` aralığında (Python'un `random.random`ıyla TUTARLI).
- `def normal() -> float` — Standart normal dağılım (ortalama 0, standart sapma 1) — Box-Muller dönüşümü.
- `def exponential(rate: float) -> float` — Üstel dağılım (hız parametresi `rate`, ortalama `1/rate`) — ters-CDF örneklemesi.
- `def shuffle[T](xs: list[T]) -> None` — Fisher-Yates karıştırma — `list[T]` ÜZERİNDE YERİNDE (in-place) çalışır, genel-amaçlı `[T]` fonksiyon generic'i (bkz. `tests/golden/codegen_cases/ generic_functions.nox`) İLE `list[T]`nin MEVCUT indek

## `nox.reflect`

Faz 1 decorator (bkz. nox-teknik-spesifikasyon.md decorator bölümü, "Decorator sözdizimi + metadata-tabanlı metaprogramming" planı): derleyicinin topladığı decorator METADATA'sını (isim, literal argüm

- `def decorator_count() -> int`
- `def decorator_target_name(i: int) -> str` — Decorator'ın UYGULANDIĞI fonksiyonun adı (hata ayıklama/tanılama İçin).
- `def decorator_name(i: int) -> str`
- `def decorator_arg_count(i: int) -> int`
- `def decorator_arg(i: int, j: int) -> str`
- `def decorator_arg_kind(i: int, j: int) -> int` — Aether NOX_LIMITATIONS.md yol haritası, Faz A.6 (bkz. nox-teknik- spesifikasyon.md ilgili bölüm, madde 2): `decorator_arg`in v1'i YALNIZCA string literali kabul ediyordu (ör. `@route.priority(5)` GİBİ
- `def decorator_arg_int(i: int, j: int) -> int`
- `def decorator_arg_bool(i: int, j: int) -> bool`
- `def decorator_arg_list_len(i: int, j: int) -> int`
- `def decorator_arg_list_item(i: int, j: int, k: int) -> str`
- `def decorator_param_count(i: int) -> int` — Aether NOX_LIMITATIONS.md yol haritası, Faz B.5 (madde 3): dekore edilmiş fonksiyonun KENDİ imzası — salt BİLGİ (framework'ler parametre-decorator sarmalayıcıları üretmek İçin).
- `def decorator_param_name(i: int, k: int) -> str`
- `def decorator_param_type(i: int, k: int) -> str`
- `def decorator_return_type(i: int) -> str`
- `def decorator_kind(i: int) -> int` — Aether NOX_LIMITATIONS.md yol haritası, Faz C.1 (madde 1): decorator kaydının NEYE uygulandığı — `0` = üst-düzey fonksiyon, `1` = sınıf (`decorator_target_name` = sınıf adı), `2` = metod (`decorator_t
- `def decorator_owner(i: int) -> str`
- `def class_count() -> int` — Faz C.3 (madde 5): HER (generic olmayan) sınıfın `__init__` parametreleri (`self` HARİÇ) — bir DI container'ın KENDİ wiring mantığını yazabilmesi İçin yeterli ham metadata; Nox'un KENDİSİ bir DI çözüc
- `def class_name(i: int) -> str`
- `def class_init_param_count(i: int) -> int`
- `def class_init_param_name(i: int, k: int) -> str`
- `def class_init_param_type(i: int, k: int) -> str`
- `def class_index(name: str) -> int` — `name` adlı sınıfın `class_*` indeksi, yoksa `-1`.
- `def decorator_is_handler(i: int) -> bool` — `true` İSE `decorator_handler(i)` GÜVENLE çağrılabilir (fonksiyonun imzası TAM OLARAK `(ctx: Context) -> HttpResponse`dir) — `false` İKEN `decorator_handler(i)` ÇAĞRILMAMALIDIR (null bir kapanışa yol 
- `def decorator_handler(i: int) -> (Context) -> HttpResponse` — YALNIZCA `decorator_is_handler(i)` `true` İKEN çağırın — bkz. yukarıdaki not.
- `def router_from_decorators() -> Router` — Framework tüketimi (bkz. plan dosyası §5): `@get`/`@post`/`@put`/`@delete` İLE decore edilmiş, `(Context) -> HttpResponse` imzalı TÜM üst-düzey fonksiyonlardan bir `Router` inşa eder — `Router.add(met

## `nox.regex`

Stdlib fazı V.6 — nox.regex: temel bir regex/desen-eşleştirme alt kümesi.

- `def is_match(pattern: str, text: str) -> bool` — `pattern`in `text` içinde HERHANGİ bir yerde eşleşip eşleşmediğini (`pattern` `^` ile BAŞLIYORSA yalnızca BAŞTAN) döner.
- `def find(pattern: str, text: str) -> int` — İlk eşleşmenin BAŞLADIĞI 0-tabanlı bayt indeksini döner, eşleşme YOKSA `-1`.

## `nox.router`

`nox.http.serve`in ham TEK `handle` geri çağrısının ÜZERİNE saf Nox'ta yazılmış bir yol (path) yönlendirme + ara katman (middleware) katmanı.

- `class Context` — Bir rotanın EŞLEŞTİĞİNDE işleyicisine iletilen ZENGİNLEŞTİRİLMİŞ istek bağlamı — ham `nox.http.HttpRequest`in SABİT alan kümesi path parametreleri TAŞIYAMADIĞINDAN (Nox sınıfları ÇALIŞMA ZAMANINDA yen
  - `def param(self: Context, name: str) -> str`
- `class Route`
  - `def step(ctx: Context) -> HttpResponse`
- `class Router`
  - `def add(self: Router, method: str, pattern: str, handler: (Context) -> HttpResponse) -> None`

## `nox.sharedmem`

Faz NN.6 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması"): GERÇEK, isimli bir paylaşımlı bellek ilkeli — `shm_open`+`mmap(MAP_SHARED)` (macOS/Linux) İLE BAĞIMSIZ (fork EDİLMEMİŞ) `noxc run

- `class SharedMemError(Exception)`
- `class SharedBuffer`
  - `def lock(self: SharedBuffer) -> None`
- `def open(name: str, size: int) -> SharedBuffer` — `name`e (dosya sistemi/`/dev/shm` benzeri bir isim alanına AİT — `noxc run`ın AYRI çalıştırmaları AYNI ismi kullanarak AYNI bölgeyi PAYLAŞIR) `size` baytlık bir paylaşımlı bellek bölgesi AÇAR (yoksa O
- `def unlink(name: str) -> None` — `name`li bölgeyi KALICI olarak SİLER — HİÇBİR process ONU (mmap İLE) AÇIK TUTMUYORSA hemen, TUTUYORSA son `close()` çağrıldığında (POSIX'in KENDİ `shm_unlink` sözleşmesi).

## `nox.smtp`

Faz STD.4 (bkz. plan dosyası "nox.smtp"): SMTP istemcisi.

- `class SmtpError(Exception)`
- `class SmtpClient`
  - `def ehlo(self: SmtpClient, domain: str) -> None`
- `def connect(host: str, port: int, use_tls: bool) -> SmtpClient` — `host`e bağlanır; `use_tls=True` ise bağlantı ANINDA TLS (SMTPS, port 465 tipik); `use_tls=False` ise düz-metin (port 25/587, SONRADAN `.starttls()` ile yükseltilebilir).
- `def send_mail(host: str, port: int, use_tls: bool, use_starttls: bool, ehlo_domain: str, username: str, password: str, from_addr: str, to_addrs: list[str], subject: str, body: str) -> None` — Tek bir e-postayı baştan sona gönderen kolaylık fonksiyonu — connect → ehlo → (starttls) → (auth_login) → send → quit → close.

## `nox.sqlite`

libsqlite3'e `std.DynLib` (dlopen/dlsym, ÇALIŞMA ZAMANINDA, TEMBEL) İLE bağlanan bir SQLite sürücüsü (bkz. plan dosyası "nox.sqlite — libsqlite3'e extern def ile bağlanan bir SQLite sürücüsü").

- `class SqliteError(Exception)`
- `class Connection`
  - `def prepare(self: Connection, sql: str) -> Statement`
- `def open(path: str) -> Connection`

## `nox.strings`

Stdlib fazı §H — bkz. nox-teknik-spesifikasyon.md.

- `def split(s: str, sep: str) -> list[str]`
- `def trim(s: str) -> str`
- `def trim_start(s: str) -> str`
- `def trim_end(s: str) -> str`
- `def upper(s: str) -> str`
- `def lower(s: str) -> str`
- `def replace(s: str, old: str, new: str) -> str`
- `def byte_at(s: str, idx: int) -> int` — Faz EE.1 — `s[i]`nin (bir `str` döner, HER ÇAĞRIDA tahsis eder) alloc-sız eşdeğeri: ham bayt DEĞERİNİ (`int`) döner.
- `def char_from_byte(b: int) -> str` — `byte_at`nin TERSİ — HAM bir bayt DEĞERİNİ (0-255) TEK karakterlik bir `str`e çevirir (ör. `nox.url.percent_decode`nin `%XX`den çözdüğü bayt değerini gerçek karaktere DÖNÜŞTÜRMESİ İçin).
- `def byte_len(s: str) -> int`
- `def join(parts: list[str], sep: str) -> str`
- `def starts_with(s: str, prefix: str) -> bool`
- `def ends_with(s: str, suffix: str) -> bool`
- `def index_of(s: str, needle: str) -> int`
- `def contains(s: str, needle: str) -> bool`
- `def splitn(s: str, sep: str, n: int) -> list[str]` — Faz III.2 — `split`in AKSİNE EN FAZLA `n` parça (SONUNCU parça KALANIN TAMAMI — Rust'ın `str::splitn`iyle TUTARLI).
- `def rsplit(s: str, sep: str) -> list[str]` — `split`in AYNI parçaları, SONDAN başlayarak (Rust'ın `str::rsplit`iyle TUTARLI — AYNI eleman kümesi, TERS sıra).
- `def repeat(s: str, n: int) -> str`
- `def eq_ignore_case(a: str, b: str) -> bool`
- `def pad_left(s: str, width: int, ch: str) -> str` — v3 sertleştirme yol haritası, madde 10 (bkz. nox-teknik-spesifikasyon.md ilgili bölüm, stdlib/API denetimi): `contains` İLE AYNI ilke — SAF Nox'ta kalır (Zig'e taşımaya değecek kadar sık çağrılan/perf
- `def pad_right(s: str, width: int, ch: str) -> str`
- `def zfill(s: str, width: int) -> str` — Python'un `str.zfill`iyle AYNI isim/davranış — `pad_left(s, width, "0")` İçİn KISA yol.

## `nox.template`

saf Nox'ta yazılmış BASİT bir string-değiştirme HTML şablon motoru (bilinçli olarak dar kapsam: `{{ isim }}` değişken yer-tutucuları, KOŞUL/DÖNGÜ YOK — "gerçek" bir Jinja-benzeri motor AYRI, daha büyü

- `class TemplateError(Exception)`
- `def escape_html(s: str) -> str`
- `def render(tmpl: str, context: dict[str, str]) -> str`
- `def render_unescaped(tmpl: str, context: dict[str, str]) -> str`

## `nox.test`

Stdlib fazı §K — bkz. nox-teknik-spesifikasyon.md.

- `class AssertionError(Exception)`
- `def assert_eq_int(actual: int, expected: int, msg: str) -> None`
- `def assert_eq_str(actual: str, expected: str, msg: str) -> None`
- `def assert_eq_float(actual: float, expected: float, msg: str) -> None`
- `def assert_true(cond: bool, msg: str) -> None`
- `class TestSuite`
  - `def check_eq_int(self: TestSuite, case_name: str, actual: int, expected: int) -> None`
- `def write_junit_xml(suite: TestSuite, path: str) -> None` — JUnit-uyumlu bir XML raporu `path`e yazar (bkz. `nox.fs.write_string`, AYNI güven-sınırı uyarısı GEÇERLİDİR — `path` doğrulanmaz).

## `nox.testmod`

- `def double(x: int) -> int`
- `def quadruple(x: int) -> int`
- `class Counter`
  - `def increment(self: Counter) -> int`
- `def make_counter(start: int) -> Counter`

## `nox.thread`

Faz BB (bkz. nox-teknik-spesifikasyon.md §3.47-§3.52): paylaşımsız (shared-nothing), çok çekirdekli iş parçacığı desteği — N BAĞIMSIZ M:1 fiber çalışma zamanının (HER BİRİ KENDİ Scheduler'ı, KENDİ ARC

_Herkese açık tanım yok._

## `nox.time`

Stdlib fazı §K — bkz. nox-teknik-spesifikasyon.md.

- `def now_ms() -> int`
- `def sleep_ms(ms: int) -> None`
- `def pad2(n: int) -> str` — Faz III.7 (bkz. nox-teknik-spesifikasyon.md §3.69) — `to_str`in gerektirdiği 2-haneli sıfır-doldurma (Nox'ta `%02d` gibi bir biçimlendirme ilkeli YOK, bu yüzden SAF string birleştirmeyle elle yapılır)
- `class DateTime` — Stdlib fazı V.4 — `DateTime`: bir epoch-ms değerinin takvim bileşenlerine (`std.time.epoch` ile, bkz. `runtime/stdlib_shims/time.zig`nin belge notu) AYRIŞTIRILMIŞ hâli.
  - `def to_str(self: DateTime) -> str`
- `def from_epoch_ms(ms: int) -> DateTime`
- `def now() -> DateTime`
- `class Duration`
  - `def as_ms(self: Duration) -> int`
- `class Instant` — Bulundu (bkz. proje belleği "v4 pre20 stdlib roadmap"nin §3.219 SONRASI incelemesi): `instant_now()`nin KENDİ `@capability.requires ("clock")` kapısı `Instant(0)` GİBİ DOĞRUDAN bir inşayı HİÇ ENGELLEM
  - `def elapsed_ms(self: Instant) -> int`
- `def instant_now() -> Instant`

## `nox.tls`

Faz NN.5 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması"): ham bir TLS akışı ilkeli.

- `class TlsError(Exception)`
- `class TlsStream`
  - `def write(self: TlsStream, data: str) -> int`
- `def connect(host: str, port: int) -> TlsStream` — `host`e (port üzerinden) TCP+TLS bağlantısı kurar — sistemin CA sertifika deposuna karşı sunucu sertifikasını doğrular (`host` hostname'iyle eşleşmesi DAHİL).

## `nox.toml`

TOML (Tom's Obvious Minimal Language) ayrıştırma.

- `class TomlError(Exception)`
- `class TomlValue` — kind: 0=string, 1=int, 2=float, 3=bool, 4=array, 5=tablo
- `def is_string(v: TomlValue) -> bool`
- `def is_int(v: TomlValue) -> bool`
- `def is_float(v: TomlValue) -> bool`
- `def is_bool(v: TomlValue) -> bool`
- `def is_array(v: TomlValue) -> bool`
- `def is_table(v: TomlValue) -> bool`
- `def parse(text: str) -> TomlValue`
- `def get(root: TomlValue, dotted_path: str) -> TomlValue` — "a.b.c" gibi noktalı bir yolu KÖKTEN itibaren çözer — ARA yolu okumak İçİn `.tbl[...]` zincirlemeye bir kolaylık.
- `def dump(v: TomlValue) -> str` — `v` (KÖK bir tablo — `parse`nin döndürdüğü AYNI şekil) TOML metnine çevrilir.

## `nox.url`

URL ayrıştırma + percent-encoding + sorgu (query string) kodlama/çözme.

- `class UrlError(Exception)`
- `class URL`
- `def parse(s: str) -> URL` — `scheme://[userinfo@]host[:port][/path][?query][#fragment]` — `path` HİÇ yoksa `"/"` varsayılır.
- `def percent_encode(s: str) -> str` — RFC 3986 "unreserved" karakterler (A-Z a-z 0-9 - _ .
- `def percent_decode(s: str) -> str` — `%XX` dizilerini gerçek baytlara çözer (`nox.strings.char_from_byte` İLE) — ardışık `%XX`ler (ör. "é" İçin "%C3%A9") baytları TEK TEK üretir ama string BİRLEŞTİRME saf bayt-ekleme OLDUĞUNDAN (KENDİ ba
- `def query_encode(params: dict[str, str]) -> str`
- `def query_int(q: dict[str, str], key: str) -> int` — Aether NOX_LIMITATIONS.md yol haritası, Faz A.5 (bkz. nox-teknik- spesifikasyon.md ilgili bölüm, madde 17): `dict[str, str]`in KENDİSİ (ör. `URL.query`/`query_decode`in dönüş tipi) bilinçli olarak DEĞ
- `def query_float(q: dict[str, str], key: str) -> float`
- `def query_bool(q: dict[str, str], key: str) -> bool` — `"true"`/`"1"` -> `True`, `"false"`/`"0"` -> `False` — BAŞKA HERHANGİ bir değer (ör. `"yes"`, boş dize, büyük/küçük harf farklı bir yazım) `ValueError` fırlatır (sessizce `False`a DÜŞMEK YERİNE, GERÇE
- `def query_decode(s: str) -> dict[str, str]`
- `def join(base: str, relative: str) -> str` — `relative` ZATEN mutlaksa (`://` içeriyorsa) OLDUĞU GİBİ döner.

## `nox.uuid`

RFC 4122 uyumlu rastgele (v4) UUID üretimi.

- `def uuid4() -> str` — RFC 4122 sürüm 4 (rastgele) UUID — "xxxxxxxx-xxxx-4xxx-yxxx- xxxxxxxxxxxx" biçiminde (y ∈ {8,9,a,b}).
- `def is_valid(s: str) -> bool` — `s`, GEÇERLİ bir UUID METİN gösterimi mi?

## `nox.validate`

`nox.json` üzerine saf Nox'ta yazılmış bir şema doğrulayıcı: bir HTTP istek gövdesi gibi ham JSON metnini/bir `JsonValue`yu bir alan kuralları listesine (isim, beklenen tip, zorunlu mu) karşı doğrular

- `class FieldRule`
- `class Schema` — `require`/`optional`in `kind` parametresi: "string"/"number"/"bool"/ "array"/"object"/"null" (bkz. `_matches_kind`).
  - `def require(self: Schema, name: str, kind: str) -> None`
- `def validate(v: JsonValue, schema: Schema) -> list[str]` — `v`, bir JSON NESNESİ (object) OLMALIDIR — değilse tek bir hatayla erken döner (alan kuralları hiç değerlendirilmez).
- `def validate_json_str(s: str, schema: Schema) -> list[str]` — `s` (ör. bir `HttpRequest.body`) GEÇERSİZ JSON İSE, çökmek/istisna fırlatmak YERİNE bunu da AYNI hata-mesajı listesine tek bir girdi olarak ekler — çağıranın `nox.json.parse`nin (v3 madde 10'a KADAR `

## `nox.websocket`

Faz NN.5 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması"): RFC 6455 WebSocket istemcisi — `ws://`/`wss://` URL'lerine bağlanır (el sıkışma + metin frame gönderme/alma).

- `class WebSocketError(Exception)`
- `class WebSocketClient`
  - `def send_text(self: WebSocketClient, data: str) -> int`
- `class WebSocketServerConn` — Faz "sunucu-tarafı WebSocket Upgrade" — `nox.http.serve_ws*`nin `ws_handle`ına GEÇİRİLEN oturum tutamacı.
  - `def send_text(self: WebSocketServerConn, data: str) -> int`
- `def connect(url: str) -> WebSocketClient` — `ws://host[:port]/path` ya da `wss://host[:port]/path` — port belirtilmemişse `ws` İçin `80`, `wss` İçin `443` kullanılır.

## `nox.yaml`

Faz STD.5 (bkz. plan dosyası "nox.yaml"): daraltılmış bir v1 alt-kümesiyle SAF Nox'ta YAML ayrıştırma.

- `class YamlError(Exception)`
- `class YamlValue` — kind: 0=string, 1=int, 2=float, 3=bool, 4=null, 5=sequence, 6=mapping
- `def is_string(v: YamlValue) -> bool`
- `def is_int(v: YamlValue) -> bool`
- `def is_float(v: YamlValue) -> bool`
- `def is_bool(v: YamlValue) -> bool`
- `def is_null(v: YamlValue) -> bool`
- `def is_sequence(v: YamlValue) -> bool`
- `def is_mapping(v: YamlValue) -> bool`
- `def parse(text: str) -> YamlValue`
- `def get(root: YamlValue, dotted_path: str) -> YamlValue` — "a.b.c" gibi noktali bir yolu, SADECE ESLEME anahtarlari ÜZERİNDEN (nox.toml'un get()'i İLE AYNI ilke — dizi-indeksleme BU yardimcinin KAPSAMI DIŞINDA, `.arr[i]` DOĞRUDAN kullanilmalidir) çözer.
- `def dump(v: YamlValue) -> str` — `v` (KÖK bir mapping YA DA sequence — `parse`nin döndürebileceği İKİ olası kök şekli) YAML metnine çevrilir.

