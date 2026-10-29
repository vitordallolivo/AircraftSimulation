// Ponte JS do AeroDrive no navegador (o emcc liga com --js-library). Cada função aqui é uma
// `extern fn` de src/sys/browser.zig. Os caminhos chegam como (ponteiro, tamanho) em UTF-8.
//
// Arquivos: o sistema de arquivos do emscripten (FS). A pasta /aerodrive está montada no IDBFS
// (a página monta e carrega antes do main, em shell.html); depois de cada gravação ali dentro,
// um FS.syncfs leva as mudanças ao IndexedDB. /data/aircraft são os exemplos do pacote (.data).
//
// Página: o seletor de arquivo, o download, o toque e a volta à tela inicial ficam em
// Module.aerodrivePage (shell.html); aqui só se chama.

addToLibrary({
  $aerodrive: {
    // texto UTF-8 da memória do wasm
    text: (pointer, length) => UTF8ToString(pointer, length),

    // grava no IndexedDB pouco depois da última mudança (várias gravações seguidas = uma sincronização)
    persistTimer: null,
    persist: (path) => {
      if (!path.startsWith('/aerodrive/')) return;
      clearTimeout(aerodrive.persistTimer);
      aerodrive.persistTimer = setTimeout(() => {
        aerodrive.persistTimer = null;
        FS.syncfs(false, (error) => { if (error) console.error('AeroDrive: não consegui gravar no IndexedDB', error); });
      }, 250);
    },

    isFolder: (path) => {
      try { return FS.isDir(FS.stat(path).mode); } catch (error) { return false; }
    },

    removeTree: (path) => {
      if (aerodrive.isFolder(path)) {
        for (const name of FS.readdir(path)) {
          if (name !== '.' && name !== '..') aerodrive.removeTree(path + '/' + name);
        }
        FS.rmdir(path);
      } else {
        FS.unlink(path);
      }
    },
  },

  // O Zig passa @returnAddress() a cada alocação (std.mem.Allocator), e no emscripten isso vira
  // emscripten_return_address, que monta um rastro da pilha do JS (new Error().stack) a cada chamada:
  // abrir o menu Aeronave levava 4 s só nisso. O endereço só serve para rastros de depuração, que o
  // navegador não mostra; 0 é o "desconhecido" que o Zig já aceita.
  emscripten_return_address__deps: [],
  emscripten_return_address: (level) => 0,

  aerodrive_file_size__deps: ['$aerodrive', '$FS'],
  aerodrive_file_size: (path, pathLength) => {
    try {
      const status = FS.stat(aerodrive.text(path, pathLength));
      return FS.isDir(status.mode) ? -1 : status.size;
    } catch (error) {
      return -1;
    }
  },

  aerodrive_file_read__deps: ['$aerodrive', '$FS'],
  aerodrive_file_read: (path, pathLength, out, outLength) => {
    try {
      const bytes = FS.readFile(aerodrive.text(path, pathLength));
      if (bytes.length !== outLength) return 0;
      HEAPU8.set(bytes, out);
      return 1;
    } catch (error) {
      return 0;
    }
  },

  aerodrive_file_write__deps: ['$aerodrive', '$FS', '$PATH'],
  aerodrive_file_write: (path, pathLength, data, dataLength) => {
    const filePath = aerodrive.text(path, pathLength);
    try {
      FS.mkdirTree(PATH.dirname(filePath));
      FS.writeFile(filePath, HEAPU8.slice(data, data + dataLength));
      aerodrive.persist(filePath);
      return 1;
    } catch (error) {
      console.error('AeroDrive: não consegui gravar', filePath, error);
      return 0;
    }
  },

  // um nome por linha, pastas terminadas em "/"; devolve o tamanho do texto (copia se couber) ou -1
  aerodrive_folder_list__deps: ['$aerodrive', '$FS'],
  aerodrive_folder_list: (path, pathLength, out, outCapacity) => {
    const folder = aerodrive.text(path, pathLength);
    if (!aerodrive.isFolder(folder)) return -1;
    const lines = [];
    for (const name of FS.readdir(folder)) {
      if (name === '.' || name === '..' || name.includes('\n')) continue;
      lines.push(aerodrive.isFolder(folder + '/' + name) ? name + '/' : name);
    }
    const bytes = new TextEncoder().encode(lines.join('\n'));
    if (bytes.length <= outCapacity) HEAPU8.set(bytes, out);
    return bytes.length;
  },

  aerodrive_path_remove__deps: ['$aerodrive', '$FS'],
  aerodrive_path_remove: (path, pathLength) => {
    const target = aerodrive.text(path, pathLength);
    try {
      aerodrive.removeTree(target);
      aerodrive.persist(target);
      return 1;
    } catch (error) {
      return 0;
    }
  },

  aerodrive_viewport_width: () => window.innerWidth,
  aerodrive_viewport_height: () => window.innerHeight,

  aerodrive_open_file_picker: () => Module.aerodrivePage.openFilePicker(),

  aerodrive_download__deps: ['$aerodrive'],
  aerodrive_download: (name, nameLength, data, dataLength) => {
    Module.aerodrivePage.download(aerodrive.text(name, nameLength), HEAPU8.slice(data, data + dataLength));
  },

  // gatilho do primeiro controle (mapeamento padrão: botão 6 = LT, 7 = RT), 0..1
  aerodrive_gamepad_trigger: (side) => {
    const pad = Array.from(navigator.getGamepads ? navigator.getGamepads() : []).find((candidate) => candidate);
    const button = pad && pad.buttons[side === 1 ? 7 : 6];
    return button ? button.value : 0;
  },

  aerodrive_touch_seen: () => (Module.aerodrivePage.touchSeen ? 1 : 0),

  aerodrive_leave__deps: ['$FS'],
  aerodrive_leave: () => FS.syncfs(false, () => Module.aerodrivePage.leave()),
});
