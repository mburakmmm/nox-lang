/* Aynı belge/işlem, doğrudan C'den yyjson (üst sınır: Nox binding'inin eklediği yük). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "yyjson.h"

static char *build_doc(int n) {
    size_t cap = (size_t)n * 96 + 16;
    char *buf = malloc(cap);
    size_t len = 0;
    buf[len++] = '[';
    for (int i = 0; i < n; i++) {
        if (i > 0) buf[len++] = ',';
        len += (size_t)snprintf(buf + len, cap - len, "{\"id\":%d,\"name\":\"item-%d\",\"active\":%s,\"score\":%.2f,\"tags\":[\"a\",\"b\"]}", i, i, (i % 3 == 0) ? "false" : "true", i * 0.5 + 0.25);
    }
    buf[len++] = ']';
    buf[len] = 0;
    return buf;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static long walk(const char *text, size_t len) {
    yyjson_doc *doc = yyjson_read(text, len, 0);
    yyjson_val *root = yyjson_doc_get_root(doc);
    long ids = 0, active = 0;
    double score = 0;
    yyjson_arr_iter it;
    yyjson_arr_iter_init(root, &it);
    yyjson_val *item;
    while ((item = yyjson_arr_iter_next(&it))) {
        ids += yyjson_get_sint(yyjson_obj_get(item, "id"));
        if (yyjson_get_bool(yyjson_obj_get(item, "active"))) active++;
        score += yyjson_get_num(yyjson_obj_get(item, "score"));
    }
    yyjson_doc_free(doc);
    return ids + 1000 * active + (long)score;
}

static long roundtrip(const char *text, size_t len) {
    yyjson_doc *doc = yyjson_read(text, len, 0);
    size_t out_len = 0;
    char *out = yyjson_write(doc, 0, &out_len);
    free(out);
    yyjson_doc_free(doc);
    return (long)out_len;
}

int main(void) {
    char *text = build_doc(20000);
    size_t len = strlen(text);
    const int reps = 10;
    long check = 0;
    double t0 = now_ms();
    for (int r = 0; r < reps; r++) check = walk(text, len);
    printf("parse+walk yyjson (C)\t%f\t%ld\n", (now_ms() - t0) / reps, check);
    t0 = now_ms();
    for (int r = 0; r < reps; r++) check = roundtrip(text, len);
    printf("parse+write yyjson (C)\t%f\t%ld\n", (now_ms() - t0) / reps, check);
    free(text);
    return 0;
}
