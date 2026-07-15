; Nox sözdizimi vurgulama sorguları — standart tree-sitter yakalama adları
; kullanır (bkz. https://tree-sitter.github.io/tree-sitter/3-syntax-highlighting.html#highlights),
; Neovim/Helix/Zed gibi editörlerin VARSAYILAN tema eşlemesiyle DOĞRUDAN
; uyumludur.

; ---- Anahtar kelimeler ----

[
  "def"
  "class"
  "protocol"
  "extern"
  "lowlevel"
  "import"
  "from"
  "as"
  "with"
  "with_rt"
] @keyword

[
  "if"
  "elif"
  "else"
  "while"
  "for"
  "in"
] @keyword.control.conditional

"return" @keyword.control.return
"raise" @keyword.control.exception

[
  "try"
  "except"
  "finally"
] @keyword.control.exception

[
  "async"
  "await"
  "spawn"
] @keyword.coroutine

(pass_statement) @keyword

[
  "and"
  "or"
  "not"
] @keyword.operator

; ---- Sabitler ----

(true) @boolean
(false) @boolean
(none) @constant.builtin
(none_type) @type.builtin

; ---- Literaller ----

(integer) @number
(float) @number
(string) @string
(comment) @comment

; ---- Tipler ----

(generic_type name: (identifier) @type)
(parameter type: (identifier) @type)
(var_declaration type: (identifier) @type)
(function_definition return_type: (identifier) @type)
(extern_function_definition return_type: (identifier) @type)
(except_clause type: (identifier) @type)

; ---- Fonksiyon/sınıf/protokol tanımları ----

(function_definition name: (identifier) @function)
(extern_function_definition name: (identifier) @function)
(class_definition name: (identifier) @type)
(protocol_definition name: (identifier) @type)
(parameter name: (identifier) @variable.parameter)
(type_parameters (identifier) @type.parameter)

; ---- Çağrılar / öznitelikler ----

(call function: (identifier) @function.call)
(call function: (attribute attribute: (identifier) @function.method.call))
(attribute attribute: (identifier) @property)

; `self` — Nox'ta gerçek bir anahtar kelime DEĞİL (sıradan bir parametre
; adı), ama Python geleneğiyle TUTARLI olarak İÇYAPISAL olarak vurgulanır.
((identifier) @variable.builtin
  (#eq? @variable.builtin "self"))

; ---- Modül yolları ----

(import_statement name: (dotted_name) @module)
(from_import_statement module: (dotted_name) @module)
(import_name name: (identifier) @function)

; ---- İşleçler ----

[
  "+" "-" "*" "/" "//" "%" "**"
  "==" "!=" "<" "<=" ">" ">="
  "="
  "->"
] @operator

; ---- Ayraçlar ----

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
[":" "," "."] @punctuation.delimiter

; ---- Değişkenler ----

(var_declaration name: (identifier) @variable)
(identifier) @variable
