# Grammar

A compact grammar of Nox. It is descriptive, not normative — the parser in `compiler/parser/` is the definition — and it omits the lexical
details in [Lexical structure](lexical.md). Notation: `A B` sequence, `A | B` choice, `[A]` optional, `{A}` zero or more, `(…)` grouping,
quoted text is literal, `NEWLINE`, `INDENT`, `DEDENT` come from the lexer.

## Program and statements

```text
program        = { statement } ;
block          = NEWLINE INDENT statement { statement } DEDENT ;

statement      = simple_stmt NEWLINE | compound_stmt ;
simple_stmt    = var_decl | assignment | aug_assignment | tuple_assignment
               | expr
               | "pass" | "break" | "continue"
               | "return" [ expr { "," expr } ]
               | "raise" expr
               | "del" target
               | "assert" expr [ "," expr ]
               | "defer" call
               | import_stmt ;

var_decl       = NAME ":" type "=" expr ;
assignment     = target "=" expr ;
aug_assignment = target aug_op expr ;
aug_op         = "+=" | "-=" | "*=" | "/=" | "//=" | "%=" | "**=" | "&=" | "|=" | "^=" | "<<=" | ">>=" ;
tuple_assignment = target "," target { "," target } "=" expr { "," expr } ;
target         = NAME | target "." NAME | target "[" expr "]" ;

import_stmt    = "import" dotted [ "as" NAME ]
               | "from" dotted "import" import_name { "," import_name } ;
import_name    = NAME [ "as" NAME ] ;
dotted         = NAME { "." NAME } ;

compound_stmt  = if_stmt | while_stmt | for_stmt | try_stmt | with_stmt | lowlevel_stmt
               | func_def | class_def | protocol_def | extern_def ;

if_stmt        = "if" expr ":" block { "elif" expr ":" block } [ "else" ":" block ] ;
while_stmt     = "while" expr ":" block ;
for_stmt       = "for" for_target "in" expr ":" block ;
for_target     = NAME | NAME "," NAME ;
try_stmt       = "try" ":" block { except_clause } [ "finally" ":" block ] ;
except_clause  = "except" [ ( dotted | "(" dotted { "," dotted } ")" ) [ "as" NAME ] ] ":" block ;
with_stmt      = "with" expr [ "as" NAME ] ":" block ;
lowlevel_stmt  = "lowlevel" ":" block ;
```

## Definitions

```text
decorator      = "@" dotted [ "(" [ literal { "," literal } ] ")" ] NEWLINE ;

func_def       = { decorator } [ "async" ] "def" NAME [ type_params ] "(" [ params ] ")" "->" type ":" block ;
type_params    = "[" NAME { "," NAME } "]" ;
params         = param { "," param } ;
param          = "self" [ ":" type ]
               | NAME ":" type [ "=" default ] ;
default        = literal | "-" number | "None" ;

class_def      = { decorator } "class" NAME [ type_params ] [ "(" dotted ")" ] ":" NEWLINE INDENT
                 [ docstring ] { field_decl | func_def | "pass" } DEDENT ;
field_decl     = NAME ":" type NEWLINE ;

protocol_def   = "protocol" NAME ":" NEWLINE INDENT { method_sig } DEDENT ;
method_sig     = "def" NAME "(" [ params ] ")" "->" type ":" NEWLINE INDENT "pass" NEWLINE DEDENT ;

extern_def     = { decorator } "extern" "def" NAME "(" [ params ] ")" "->" type
                 "from" STRING [ "with_rt" ] [ "retains" "(" NAME { "," NAME } ")" ] ;
```

## Types

```text
type           = base_type [ "|" "None" ] ;
base_type      = NAME                                   (* int float bool str None, class, protocol, u8 … *)
               | NAME "[" type { "," type } "]"        (* list[T] dict[K,V] set[T] tuple[A,B] Task[T] Channel[T] ptr[T] Box[int] *)
               | "(" [ type { "," type } ] ")" "->" type  (* function type *)
               | dotted ;                               (* qualified class name: util.Box *)
```

## Expressions

Listed from loosest to tightest binding:

```text
expr           = lambda | conditional ;
lambda         = "lambda" [ NAME { "," NAME } ] ":" expr ;
conditional    = or_expr [ "if" or_expr "else" expr ] ;
or_expr        = and_expr { "or" and_expr } ;
and_expr       = not_expr { "and" not_expr } ;
not_expr       = "not" not_expr | comparison ;
comparison     = bit_or { comp_op bit_or } ;
comp_op        = "==" | "!=" | "<" | "<=" | ">" | ">=" | "in" | "not" "in" | "is" | "is" "not" ;
bit_or         = bit_xor { "|" bit_xor } ;
bit_xor        = bit_and { "^" bit_and } ;
bit_and        = shift { "&" shift } ;
shift          = sum { ( "<<" | ">>" ) sum } ;
sum            = term { ( "+" | "-" ) term } ;
term           = factor { ( "*" | "/" | "//" | "%" ) factor } ;
factor         = ( "-" | "+" | "~" ) factor | power ;
power          = postfix [ "**" factor ] ;
postfix        = atom { "." NAME | "[" subscript "]" | "[" type_args "]" | "(" [ args ] ")" } ;
subscript      = expr | [ expr ] ":" [ expr ] [ ":" [ expr ] ] ;
args           = arg { "," arg } ;
arg            = expr | NAME "=" expr ;

atom           = NAME | NUMBER | STRING | FSTRING | "True" | "False" | "None"
               | "(" expr ")" | tuple | list | dict | set | comprehension
               | "spawn" call | "await" postfix ;
tuple          = "(" expr "," [ expr { "," expr } ] ")" ;
list           = "[" [ expr { "," expr } [ "," ] ] "]" ;
dict           = "{" [ expr ":" expr { "," expr ":" expr } ] "}" ;
set            = "{" expr { "," expr } "}" ;
comprehension  = "[" expr comp_for "]" | "{" expr ":" expr comp_for "}" | "{" expr comp_for "}" ;
comp_for       = ( "for" for_target "in" or_expr { "if" or_expr } )+ ;
```

A generator expression `expr comp_for` is also accepted as the single argument of a call.
