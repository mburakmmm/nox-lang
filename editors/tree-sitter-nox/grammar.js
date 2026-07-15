/**
 * @file Tree-sitter grammar for the Nox programming language
 * @license MIT
 *
 * Nox: Python'a sözdizimsel olarak yakın, zorunlu statik tipli, QBE ile AOT
 * derlenen bir sistem dili (bkz. AGENTS.md/nox-teknik-spesifikasyon.md).
 * Bu gramer, `compiler/lexer/token.zig` + `compiler/lexer/lexer.zig` +
 * `compiler/parser/parser.zig`daki GERÇEK derleyici gramerini KAYNAK olarak
 * alır — kapsam dışı bırakılan bilinçli sadeleştirmeler HER kuralın
 * yanındaki yorumlarda belirtilmiştir. Girinti-duyarlı NEWLINE/INDENT/DEDENT
 * üretimi `src/scanner.c`deki harici tarayıcı tarafından yapılır (bkz. onun
 * belge notu — tree-sitter-python'ın kanıtlanmış algoritmasından uyarlanmış).
 */

/* eslint-disable arrow-parens */
/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  or: 1,
  and: 2,
  not: 3,
  compare: 4,
  add: 5,
  mul: 6,
  unary: 7,
  power: 8,
  postfix: 9,
};

module.exports = grammar({
  name: 'nox',

  extras: $ => [$.comment, /[ \t\f\r]/, '\n'],

  word: $ => $.identifier,

  externals: $ => [
    $._newline,
    $._indent,
    $._dedent,
    ')',
    ']',
    '}',
  ],

  conflicts: $ => [],

  rules: {
    module: $ => repeat($._statement),

    comment: _$ => token(/#[^\n]*/),

    // ---- Deyimler ----

    _statement: $ => choice($._simple_statement, $._compound_statement),

    _simple_statement: $ => seq(
      choice(
        $.import_statement,
        $.from_import_statement,
        $.var_declaration,
        $.assignment,
        $.return_statement,
        $.raise_statement,
        $.pass_statement,
        $.expression_statement,
      ),
      $._newline,
    ),

    _compound_statement: $ => choice(
      $.if_statement,
      $.while_statement,
      $.for_statement,
      $.function_definition,
      $.extern_function_definition,
      $.class_definition,
      $.protocol_definition,
      $.try_statement,
      $.with_statement,
      $.lowlevel_statement,
    ),

    // `import nox.http` / `import nox.http as h` (bkz. ast.ImportStmt).
    import_statement: $ => seq(
      'import',
      field('name', $.dotted_name),
      optional(seq('as', field('alias', $.identifier))),
    ),

    // `from nox.http import get, post as p` (bkz. ast.FromImportStmt).
    from_import_statement: $ => seq(
      'from',
      field('module', $.dotted_name),
      'import',
      commaSep1($.import_name),
    ),

    import_name: $ => seq(
      field('name', $.identifier),
      optional(seq('as', field('alias', $.identifier))),
    ),

    dotted_name: $ => sep1($.identifier, '.'),

    // `x: int = 1` — Nox'ta TÜM yeni değişkenler ZORUNLU tip anotasyonu
    // taşır (bkz. AGENTS.md §5), tip ÇIKARIMLI bildirim YOK.
    var_declaration: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $._type_expression),
      '=',
      field('value', $._expression),
    ),

    // `x = 1` / `obj.attr = 1` / `xs[0] = 1` — mevcut bir isme/erişimciye
    // yeniden atama (bkz. parser.zig'in parseSimpleStmt'i — hedef tip
    // anotasyonu TAŞIMAZ, bu `var_declaration`dan ayıran şey budur).
    assignment: $ => seq(
      field('target', $._expression),
      '=',
      field('value', $._expression),
    ),

    return_statement: $ => seq('return', optional(field('value', $._expression))),

    raise_statement: $ => seq('raise', field('value', $._expression)),

    pass_statement: _$ => 'pass',

    expression_statement: $ => $._expression,

    if_statement: $ => seq(
      'if', field('condition', $._expression), ':', field('body', $.block),
      repeat($.elif_clause),
      optional($.else_clause),
    ),
    elif_clause: $ => seq('elif', field('condition', $._expression), ':', field('body', $.block)),
    else_clause: $ => seq('else', ':', field('body', $.block)),

    while_statement: $ => seq('while', field('condition', $._expression), ':', field('body', $.block)),

    for_statement: $ => seq(
      'for', field('name', $.identifier), 'in', field('iterable', $._expression), ':', field('body', $.block),
    ),

    // `def name[T](a: int) -> int:` — `[T]` isteğe bağlı generic tip
    // parametreleri (bkz. Faz 10), `async def` async fonksiyon (bkz. Faz 21).
    function_definition: $ => seq(
      optional('async'),
      'def',
      field('name', $.identifier),
      optional(field('type_parameters', $.type_parameters)),
      field('parameters', $.parameters),
      '->',
      field('return_type', $._type_expression),
      ':',
      field('body', $.block),
    ),

    type_parameters: $ => seq('[', commaSep1($.identifier), ']'),

    parameters: $ => seq('(', commaSep($.parameter), ')'),
    parameter: $ => seq(field('name', $.identifier), ':', field('type', $._type_expression)),

    // `extern def name(a: int) -> int from "lib" with_rt` — gövde YOK,
    // native ABI sınırı bildirimi (bkz. AGENTS.md §9.5 — güven sınırı).
    extern_function_definition: $ => seq(
      'extern', 'def',
      field('name', $.identifier),
      field('parameters', $.parameters),
      '->',
      field('return_type', $._type_expression),
      'from',
      field('library', $.string),
      optional('with_rt'),
    ),

    // Sınıf gövdesi YALNIZCA metodlardan oluşur (alanlar `__init__` İÇİNDE
    // `self.x = ...` ile örtük tanımlanır — bkz. parser.zig'in parseClassDef'i).
    class_definition: $ => seq(
      'class', field('name', $.identifier), ':', field('body', $.class_body),
    ),
    class_body: $ => seq($._newline, $._indent, repeat1($.function_definition), $._dedent),

    // Protokol gövdesi de AYNI şekilde yalnızca metod imzalarından oluşur
    // (yapısal/structural tip eşleşmesi — bkz. Faz 11/AGENTS.md §12).
    protocol_definition: $ => seq(
      'protocol', field('name', $.identifier), ':', field('body', $.class_body),
    ),

    try_statement: $ => seq(
      'try', ':', field('body', $.block),
      repeat($.except_clause),
      optional($.finally_clause),
    ),
    except_clause: $ => seq(
      'except', field('type', $.identifier), optional(seq('as', field('name', $.identifier))), ':', field('body', $.block),
    ),
    finally_clause: $ => seq('finally', ':', field('body', $.block)),

    // `with EXPR as NAME:` / `with EXPR:` (bkz. Faz U.5).
    with_statement: $ => seq(
      'with', field('value', $._expression), optional(seq('as', field('name', $.identifier))), ':', field('body', $.block),
    ),

    // `lowlevel:` bloğu — YALNIZCA tahsis stratejisini gevşetir, tip
    // disiplini AYNEN sürer (bkz. AGENTS.md §8, Katman 4).
    lowlevel_statement: $ => seq('lowlevel', ':', field('body', $.block)),

    block: $ => seq($._newline, $._indent, repeat1($._statement), $._dedent),

    // ---- Tip ifadeleri ----

    _type_expression: $ => choice(
      $.none_type,
      $.function_type,
      $.generic_type,
      $.identifier,
    ),

    none_type: _$ => 'None',

    // `(int, int) -> int` — birinci-sınıf fonksiyon/closure tip ifadesi
    // (bkz. Faz U.4.1).
    function_type: $ => seq(
      '(', commaSep($._type_expression), ')', '->', $._type_expression,
    ),

    // `list[T]` / `dict[K, V]` — yerleşik generic tip kurgusu.
    generic_type: $ => seq(
      field('name', $.identifier), '[', commaSep1($._type_expression), ']',
    ),

    // ---- İfadeler ----
    //
    // Öncelik sırası GERÇEK ayrıştırıcıyla (parser.zig'in precedence-climbing
    // zinciriyle) AYNI: or < and < not < karşılaştırma < +/- < */÷ < tekli <
    // üs < postfix (çağrı/öznitelik/indeks).

    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.await_expression,
      $.spawn_expression,
      $._postfix_expression,
    ),

    binary_expression: $ => choice(
      ...[
        ['or', PREC.or],
        ['and', PREC.and],
        ['==', PREC.compare], ['!=', PREC.compare],
        ['<', PREC.compare], ['<=', PREC.compare],
        ['>', PREC.compare], ['>=', PREC.compare],
        ['+', PREC.add], ['-', PREC.add],
        ['*', PREC.mul], ['/', PREC.mul], ['//', PREC.mul], ['%', PREC.mul],
      ].map(([op, p]) => prec.left(p, seq(
        field('left', $._expression),
        field('operator', op),
        field('right', $._expression),
      ))),
      // `**` sağa-birleşimli (bkz. parsePower — üs, kendi tekrarında
      // parseUnary'ye düşer).
      prec.right(PREC.power, seq(
        field('left', $._expression),
        field('operator', '**'),
        field('right', $._expression),
      )),
    ),

    unary_expression: $ => choice(
      prec(PREC.not, seq(field('operator', 'not'), field('operand', $._expression))),
      prec(PREC.unary, seq(field('operator', '-'), field('operand', $._expression))),
    ),

    await_expression: $ => prec(PREC.unary, seq('await', field('operand', $._expression))),
    spawn_expression: $ => prec(PREC.unary, seq('spawn', field('operand', $._expression))),

    _postfix_expression: $ => choice(
      $.call,
      $.attribute,
      $.index,
      $._primary_expression,
    ),

    call: $ => prec(PREC.postfix, seq(
      field('function', $._postfix_expression),
      field('arguments', $.argument_list),
    )),
    argument_list: $ => seq('(', commaSep($._expression), ')'),

    attribute: $ => prec(PREC.postfix, seq(
      field('object', $._postfix_expression), '.', field('attribute', $.identifier),
    )),

    // `xs[i]` / `d[k]` — `Channel[T](cap)`nin AÇIK generic tip argümanlı
    // kurucu çağrısı (bkz. parser.zig'in isGenericConstructName/
    // GenericConstruct notu — dilde YALNIZCA `Channel` için ayrılmış) bu
    // gramerde AYRI bir düğüm türü OLARAK modellenmez; `Channel[T](cap)`
    // basitçe iç içe `call(index(...), args)` olarak ayrıştırılır — bir
    // vurgulayıcı/editör aracı İÇİN yeterli, GERÇEK derleyicinin tip
    // denetimini TEKRARLAMAZ (bkz. bu dosyanın belge notu).
    index: $ => prec(PREC.postfix, seq(
      field('object', $._postfix_expression), '[', field('index', $._expression), ']',
    )),

    _primary_expression: $ => choice(
      $.integer,
      $.float,
      $.true,
      $.false,
      $.none,
      $.string,
      $.identifier,
      $.parenthesized_expression,
      $.list,
      $.dict,
    ),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    // Boş `[]` GEÇERLİDİR (tip çıkarımı checker'da reddedilir — bkz.
    // ast.zig'in list_lit notu), ama boş `{}` GEÇERSİZDİR (parser en az
    // bir çift BEKLER) — bkz. parser.zig'in parsePrimary'si.
    list: $ => seq('[', commaSep($._expression), ']'),
    dict: $ => seq('{', commaSep1($.pair), '}'),
    pair: $ => seq(field('key', $._expression), ':', field('value', $._expression)),

    true: _$ => 'True',
    false: _$ => 'False',
    none: _$ => 'None',

    integer: _$ => token(/\d+/),
    float: _$ => token(/\d+\.\d+/),

    // Tek/çift tırnaklı, çok satırlı OLMAYAN string (bkz. lexer.zig'in
    // KENDİSİ de teknik olarak satır içi `\n`'i özel işlemez, ama pratikte
    // TEK satırlık kullanım BEKLENİR — bu gramer bunu KATI şekilde uygular).
    string: _$ => token(choice(
      seq('"', repeat(choice(/[^"\\\n]/, /\\./)), '"'),
      seq("'", repeat(choice(/[^'\\\n]/, /\\./)), "'"),
    )),

    identifier: _$ => /[A-Za-z_][A-Za-z0-9_]*/,
  },
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return sep1(rule, ',');
}

function sep1(rule, sep) {
  return seq(rule, repeat(seq(sep, rule)));
}
