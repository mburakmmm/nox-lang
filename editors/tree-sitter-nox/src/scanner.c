// Nox harici tarayıcısı — girinti-duyarlı NEWLINE/INDENT/DEDENT üretimi.
//
// Nox'un GERÇEK derleyici lexer'ı (bkz. compiler/lexer/lexer.zig) AYNI
// modeli (Python tokenizer'ı referans alınarak) kullanır: girinti YALNIZCA
// BOŞLUK karakterleriyle (TAB YASAK — derleyici `TabsNotAllowed` hatası
// verir), parantez/köşeli/süslü parantez İÇİNDEYKEN satır sonları ANLAMSIZ
// (NEWLINE/INDENT/DEDENT üretilmez), `\` + satır sonu AÇIK satır devamıdır.
//
// Bu tarayıcı, tree-sitter-python'ın (MIT lisanslı, https://github.com/
// tree-sitter/tree-sitter-python) KANITLANMIŞ NEWLINE/INDENT/DEDENT
// algoritmasından UYARLANMIŞTIR — Nox'un DAHA BASİT olduğu yerler (üçlü-
// tırnaklı/f-string/ham/bytes string YOK, TAB'a izin YOK) BİLİNÇLİ olarak
// BUDANMIŞTIR (bkz. `stdlib/nox/`nin genel "gerçek/kanıtlanmış algoritmayı
// UYARLA, sıfırdan İCAT ETME" ilkesiyle AYNı yaklaşım — `nox.regex`/`nox.json`
// modüllerinin KENDİ belge notlarına bkz.).
//
// `')'`/`']'`/`'}'` harici sembol OLARAK bildirilir (ama ASLA doğrudan
// üretilmez, dahili/normal token eşleştirmesine HER ZAMAN düşülür) —
// TEK amacı, ayrıştırıcı durumunun bir kapanış parantezi BEKLEYİP
// beklemediğini (`within_brackets`) tarayıcıya SIZDIRMAK, böylece
// parantez İÇİNDE bir DEDENT'in YANLIŞLIKLA üretilmesi engellenir.

#include "tree_sitter/parser.h"

#include <stdint.h>
#include <stdlib.h>

enum TokenType {
    NEWLINE,
    INDENT,
    DEDENT,
    CLOSE_PAREN,
    CLOSE_BRACKET,
    CLOSE_BRACE,
};

typedef struct {
    uint16_t *indents;
    uint32_t indents_len;
    uint32_t indents_cap;
} Scanner;

static void indents_push(Scanner *s, uint16_t v) {
    if (s->indents_len == s->indents_cap) {
        s->indents_cap = s->indents_cap == 0 ? 16 : s->indents_cap * 2;
        s->indents = realloc(s->indents, s->indents_cap * sizeof(uint16_t));
    }
    s->indents[s->indents_len++] = v;
}

static uint16_t indents_pop(Scanner *s) {
    return s->indents[--s->indents_len];
}

static uint16_t indents_back(Scanner *s) {
    return s->indents[s->indents_len - 1];
}

static inline void skip(TSLexer *lexer) { lexer->advance(lexer, true); }

void *tree_sitter_nox_external_scanner_create() {
    Scanner *s = calloc(1, sizeof(Scanner));
    indents_push(s, 0);
    return s;
}

void tree_sitter_nox_external_scanner_destroy(void *payload) {
    Scanner *s = (Scanner *)payload;
    free(s->indents);
    free(s);
}

unsigned tree_sitter_nox_external_scanner_serialize(void *payload, char *buffer) {
    Scanner *s = (Scanner *)payload;
    size_t size = 0;
    uint32_t i = 1; // ilk eleman HER ZAMAN 0'dır, seri hale getirmeye gerek yok
    for (; i < s->indents_len && size + 2 < TREE_SITTER_SERIALIZATION_BUFFER_SIZE; i++) {
        buffer[size++] = (char)(s->indents[i] & 0xFF);
        buffer[size++] = (char)((s->indents[i] >> 8) & 0xFF);
    }
    return (unsigned)size;
}

void tree_sitter_nox_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    Scanner *s = (Scanner *)payload;
    s->indents_len = 0;
    indents_push(s, 0);
    size_t size = 0;
    while (size + 1 < length) {
        uint16_t v = (uint16_t)((unsigned char)buffer[size] | ((unsigned char)buffer[size + 1] << 8));
        indents_push(s, v);
        size += 2;
    }
}

bool tree_sitter_nox_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    Scanner *s = (Scanner *)payload;

    bool within_brackets =
        valid_symbols[CLOSE_BRACE] || valid_symbols[CLOSE_PAREN] || valid_symbols[CLOSE_BRACKET];

    lexer->mark_end(lexer);

    bool found_end_of_line = false;
    uint16_t indent_length = 0;
    int32_t first_comment_indent_length = -1;

    for (;;) {
        if (lexer->lookahead == '\n') {
            found_end_of_line = true;
            indent_length = 0;
            skip(lexer);
        } else if (lexer->lookahead == ' ') {
            indent_length++;
            skip(lexer);
        } else if (lexer->lookahead == '\r') {
            indent_length = 0;
            skip(lexer);
        } else if (lexer->lookahead == '\t') {
            // Nox derleyicisi TAB'ı REDDEDER (TabsNotAllowed) — tarayıcı
            // burada KATI davranmaz (yalnızca vurgulama İÇİN), 8 sütunluk
            // bir sekme gibi SAYAR (çoğu editörün varsayımıyla TUTARLI).
            indent_length += 8;
            skip(lexer);
        } else if (lexer->lookahead == '#' &&
                   (valid_symbols[INDENT] || valid_symbols[DEDENT] || valid_symbols[NEWLINE])) {
            if (!found_end_of_line) return false;
            if (first_comment_indent_length == -1) first_comment_indent_length = (int32_t)indent_length;
            while (lexer->lookahead && lexer->lookahead != '\n') skip(lexer);
            skip(lexer);
            indent_length = 0;
        } else if (lexer->lookahead == '\\') {
            // Açık satır devamı — bkz. lexer.zig'in AYNI davranışı.
            skip(lexer);
            if (lexer->lookahead == '\r') skip(lexer);
            if (lexer->lookahead == '\n') {
                skip(lexer);
            } else {
                return false;
            }
        } else if (lexer->eof(lexer)) {
            indent_length = 0;
            found_end_of_line = true;
            break;
        } else {
            break;
        }
    }

    if (found_end_of_line) {
        if (s->indents_len > 0) {
            uint16_t current_indent_length = indents_back(s);

            if (valid_symbols[INDENT] && indent_length > current_indent_length) {
                indents_push(s, indent_length);
                lexer->result_symbol = INDENT;
                return true;
            }

            if ((valid_symbols[DEDENT] || (!valid_symbols[NEWLINE] && !within_brackets)) &&
                indent_length < current_indent_length &&
                first_comment_indent_length < (int32_t)current_indent_length) {
                indents_pop(s);
                lexer->result_symbol = DEDENT;
                return true;
            }
        }

        if (valid_symbols[NEWLINE]) {
            lexer->result_symbol = NEWLINE;
            return true;
        }
    }

    return false;
}
