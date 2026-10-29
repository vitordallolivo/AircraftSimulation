//! O modelo do avião do AeroDrive como módulo para quem só quer ler e desenhar o avião (a interface do aerosim
//! em Zig): a leitura do `.json` (`model/aircraft.zig`), os perfis (`model/airfoil.zig`) e o esqueleto com as
//! malhas de cada peça nas cores da GUI (`model/skeleton.zig`). Nada aqui abre janela nem roda física.
pub const aircraft = @import("model/aircraft.zig");
pub const airfoil = @import("model/airfoil.zig");
pub const skeleton = @import("model/skeleton.zig");
pub const vec3 = @import("math/vec3.zig");
