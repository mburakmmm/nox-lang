//! Nox derleyicisinin dış dünyaya (testler, ileride codegen/typecheck) açtığı
//! tek giriş noktası. `noxc` (main.zig) ile testler aynı sembollere buradan erişir.

pub const token = @import("lexer/token.zig");
pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const ast_dump = @import("parser/ast_dump.zig");
pub const types = @import("typecheck/types.zig");
pub const checker = @import("typecheck/checker.zig");
pub const ownership = @import("ownership/analysis.zig");
pub const codegen = @import("codegen_qbe/codegen.zig");
pub const module_loader = @import("module_loader.zig");
pub const project = @import("project.zig");
pub const test_runner = @import("pkg/test_runner.zig");
pub const fetch = @import("pkg/fetch.zig");
