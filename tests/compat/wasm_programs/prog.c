/* Gerçek derleyici (zig cc -> wasm32) çıktısı üzerinde yorumlayıcı doğrulaması. Her işlev bir sağlama toplamı/değer döndürür; sonuçlar Node/V8 ile
 * karşılaştırılır (scripts/wasm_gen_programs.py). Bellek, bulk-memory (memcpy/memset), i64, f64, dolaylı çağrı, kontrol akışı ve compiler-rt çağrıları kullanır. */
typedef unsigned char u8;
typedef unsigned int u32;
typedef long long i64;
typedef unsigned long long u64;

#define EXPORT __attribute__((visibility("default")))

static u32 rng_state = 12345;
static u32 rng(void) {
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state >> 8;
}

EXPORT int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

EXPORT int collatz(int n) {
    int steps = 0;
    u64 x = (u64)n;
    while (x != 1) {
        x = (x & 1) ? 3 * x + 1 : x >> 1;
        steps++;
    }
    return steps;
}

static u8 sieve_buf[200000];
EXPORT int sieve(int n) {
    for (int i = 0; i < n; i++) sieve_buf[i] = 1;
    sieve_buf[0] = sieve_buf[1] = 0;
    for (int i = 2; (i64)i * i < n; i++)
        if (sieve_buf[i])
            for (int j = i * i; j < n; j += i) sieve_buf[j] = 0;
    int c = 0;
    for (int i = 0; i < n; i++) c += sieve_buf[i];
    return c;
}

static int sort_buf[4096];
EXPORT int sort_check(int n) {
    rng_state = 99;
    for (int i = 0; i < n; i++) sort_buf[i] = (int)(rng() % 100000) - 50000;
    for (int i = 1; i < n; i++) {
        int v = sort_buf[i], j = i - 1;
        while (j >= 0 && sort_buf[j] > v) {
            sort_buf[j + 1] = sort_buf[j];
            j--;
        }
        sort_buf[j + 1] = v;
    }
    int sum = 0;
    for (int i = 0; i < n; i++) sum = sum * 31 + sort_buf[i];
    return sum;
}

EXPORT i64 modpow(i64 b, i64 e, i64 m) {
    i64 r = 1;
    b %= m;
    while (e > 0) {
        if (e & 1) r = (__int128)r * b % m;
        b = (__int128)b * b % m;
        e >>= 1;
    }
    return r;
}

EXPORT i64 gcd(i64 a, i64 b) { return b == 0 ? a : gcd(b, a % b); }

EXPORT double mandel(int n) {
    double total = 0;
    for (int py = 0; py < n; py++)
        for (int px = 0; px < n; px++) {
            double x0 = (double)px / n * 3.5 - 2.5, y0 = (double)py / n * 2.0 - 1.0, x = 0, y = 0;
            int it = 0;
            while (x * x + y * y <= 4 && it < 50) {
                double t = x * x - y * y + x0;
                y = 2 * x * y + y0;
                x = t;
                it++;
            }
            total += it;
        }
    return total;
}

static double ma[32 * 32], mb[32 * 32], mc[32 * 32];
EXPORT double matmul(int n) {
    for (int i = 0; i < n * n; i++) {
        ma[i] = (double)(i % 7) * 0.5 + 1;
        mb[i] = (double)(i % 5) - 1.25;
    }
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            double s = 0;
            for (int k = 0; k < n; k++) s += ma[i * n + k] * mb[k * n + j];
            mc[i * n + j] = s;
        }
    double t = 0;
    for (int i = 0; i < n * n; i++) t += mc[i] * (double)(i + 1);
    return t;
}

EXPORT float fsum(int n) {
    float s = 0;
    for (int i = 1; i <= n; i++) s += 1.0f / (float)i;
    return s;
}

static u32 crc_table[256];
EXPORT u32 crc32(int n) {
    for (u32 i = 0; i < 256; i++) {
        u32 c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
    u8 buf[1024];
    rng_state = 7;
    for (int i = 0; i < n && i < 1024; i++) buf[i] = (u8)rng();
    u32 c = 0xFFFFFFFFu;
    for (int i = 0; i < n && i < 1024; i++) c = crc_table[(c ^ buf[i]) & 0xFF] ^ (c >> 8);
    return ~c;
}

static char mem_a[8192], mem_b[8192];
EXPORT int memops(int n) {
    for (int i = 0; i < n; i++) mem_a[i] = (char)(i * 7);
    __builtin_memcpy(mem_b, mem_a, n);
    __builtin_memset(mem_a, 0x5a, n / 2);
    __builtin_memmove(mem_b + 3, mem_b, n - 8);
    int h = 0;
    for (int i = 0; i < n; i++) h = h * 33 + mem_a[i] + 3 * mem_b[i];
    return h;
}

static int op_add(int a, int b) { return a + b; }
static int op_sub(int a, int b) { return a - b; }
static int op_mul(int a, int b) { return a * b; }
static int op_xor(int a, int b) { return a ^ b; }
static int (*const ops[4])(int, int) = {op_add, op_sub, op_mul, op_xor};
EXPORT int dispatch(int op, int a, int b) { return ops[op & 3](a, b); }

EXPORT int divmod(int a, int b) { return (a / b) * 1000 + (a % b); }

EXPORT i64 mul128(i64 a, i64 b) { return (i64)(((__int128)a * b) >> 64); }

EXPORT double mix(int a, double b, float c) { return (double)a * b + (double)c - (double)(int)b; }

EXPORT int bits(u32 x) { return __builtin_popcount(x) * 100 + __builtin_clz(x | 1) * 10 + __builtin_ctz(x | 0x80000000u); }
