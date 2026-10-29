//! Em que plataforma o programa foi compilado (decidido em comptime pelo alvo).
const builtin = @import("builtin");

/// verdadeiro no alvo web (`zig build -Dtarget=wasm32-emscripten`)
pub const in_browser = builtin.os.tag == .emscripten;
