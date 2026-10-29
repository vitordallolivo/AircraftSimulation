//! As formas do visual: retângulo com dois cantos cortados (cartões), paralelogramo (abas e botões inclinados) e
//! a faixa zebrada (barra de progresso). Só raylib; os pontos vão no sentido anti-horário da tela.
const rl = @import("raylib");

/// os 6 pontos de um retângulo com o canto de cima à direita e o de baixo à esquerda cortados em `cut` pixels
pub fn cutCornerPoints(rect: rl.Rectangle, cut: f32) [6]rl.Vector2 {
    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;
    return .{
        .{ .x = x, .y = y },
        .{ .x = x, .y = y + h - cut },
        .{ .x = x + cut, .y = y + h },
        .{ .x = x + w, .y = y + h },
        .{ .x = x + w, .y = y + cut },
        .{ .x = x + w - cut, .y = y },
    };
}

/// preenche o retângulo de cantos cortados
pub fn cutCorners(rect: rl.Rectangle, cut: f32, color: rl.Color) void {
    const points = cutCornerPoints(rect, cut);
    rl.drawTriangleFan(&points, color);
}

/// a linha de cima de um cartão de cantos cortados (até o corte, e a diagonal do corte)
pub fn cutCornersTopEdge(rect: rl.Rectangle, cut: f32, thickness: f32, color: rl.Color) void {
    rl.drawRectangleRec(.{ .x = rect.x, .y = rect.y, .width = rect.width - cut, .height = thickness }, color);
    rl.drawLineEx(.{ .x = rect.x + rect.width - cut, .y = rect.y + thickness / 2 }, .{ .x = rect.x + rect.width, .y = rect.y + cut }, thickness, color);
}

/// os 4 pontos de um paralelogramo inclinado para a direita: o lado de cima avança `slant` pixels
pub fn slantedPoints(rect: rl.Rectangle, slant: f32) [4]rl.Vector2 {
    return .{
        .{ .x = rect.x + slant, .y = rect.y },
        .{ .x = rect.x, .y = rect.y + rect.height },
        .{ .x = rect.x + rect.width - slant, .y = rect.y + rect.height },
        .{ .x = rect.x + rect.width, .y = rect.y },
    };
}

/// preenche o paralelogramo (abas ativas, botão Rodar)
pub fn slanted(rect: rl.Rectangle, slant: f32, color: rl.Color) void {
    const points = slantedPoints(rect, slant);
    rl.drawTriangleFan(&points, color);
}

/// faixa zebrada (listras inclinadas de duas cores) até a fração `fill` do retângulo
pub fn hazard(rect: rl.Rectangle, fill: f32, first: rl.Color, second: rl.Color) void {
    rl.drawRectangleRec(rect, second);
    const width = rect.width * @max(0, @min(1, fill));
    if (width <= 0) return;
    rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(@ceil(width)), @intFromFloat(@ceil(rect.height)));
    defer rl.endScissorMode();
    const stripe: f32 = 8;
    var x = rect.x - rect.height;
    while (x < rect.x + width) : (x += stripe * 1.5) {
        slanted(.{ .x = x, .y = rect.y, .width = stripe + rect.height, .height = rect.height }, rect.height, first);
    }
}
