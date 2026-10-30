//! As peças comuns das telas do aerosim e do aeroopt em Zig: cores e fontes, formas, widgets, formulário, gráfico
//! e o laço do programa. O aeroopt usa este módulo tirado daqui (`aeroopt/build.zig`).
pub const theme = @import("theme.zig");
pub const widgets = @import("widgets.zig");
pub const form = @import("form.zig");
pub const plot = @import("plot.zig");
pub const numbers = @import("numbers.zig");
pub const app = @import("app.zig");
pub const view3d = @import("view3d.zig");
pub const dialogs = @import("dialogs.zig");
pub const menus = @import("menus.zig");
pub const jobs = @import("jobs.zig");

test {
    _ = numbers;
}
