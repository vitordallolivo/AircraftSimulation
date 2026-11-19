//! Os testes sem janela da interface do aerosim: escalas dos gráficos, exportar, o toque (mouse e dedo) e a leitura
//! do avião da Montagem.
test {
    _ = @import("ui/numbers.zig");
    _ = @import("ui/export.zig");
    _ = @import("ui/pointer.zig");
    _ = @import("ui/phone.zig");
    _ = @import("assembly.zig");
    _ = @import("tabs/config_tab.zig");
}
