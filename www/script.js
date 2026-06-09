function js_out(ptr, len) {
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  outputArea.value += decoder.decode(bytes);
}

function js_now() {
  return Date.now();
}

async function initWasm() {
  const response = await fetch("zlox.wasm");
  const bytes = await response.arrayBuffer();
  const module = new WebAssembly.Module(bytes);
  const memory = new WebAssembly.Memory({
    initial: 20,
    maximum: 65536,
  });
  const instance = new WebAssembly.Instance(module, {
    env: { memory, js_out, js_now },
  });
  const wasm = instance.exports;

  return { wasm, memory };
}

function allocateString(string) {
  const source = encoder.encode(string);
  const len = source.length;

  const ptr = wasm.alloc(len);
  if (ptr === null) throw "Cannot allocate memory.";

  const memarr = new Uint8Array(memory.buffer);
  for (let i = 0; i < len; i++) {
    memarr[ptr + i] = source[i];
  }

  return { ptr, len };
}

function run() {
  document.querySelector("#output").value = "";
  const input = document.querySelector("#input").value;
  const source = allocateString(input);
  const result = wasm.runSource(source.ptr, source.len);
  wasm.free(source.ptr, source.len);
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const { wasm, memory } = await initWasm();

const inputArea = document.querySelector("#input");
const highlightPre = document.querySelector("#highlight");
const highlightCode = highlightPre.querySelector("code");
const outputArea = document.querySelector("#output");
const runBtn = document.querySelector("#run");

runBtn.addEventListener("click", run);
inputArea.addEventListener("keydown", (e) => {
  if (e.ctrlKey && e.key === "Enter") run();
});

//------------------------------

function updateHighlight() {
  let text = inputArea.value;

  // 最後の文字が改行だった場合、表示側の高さがズレるのを防ぐための処理
  if (text[text.length - 1] === "\n") {
    text += " ";
  }

  // HTML特殊文字をエスケープした上で、code要素にテキストを挿入
  highlightCode.textContent = text;

  // Prism.js を強制的に再適用してハイライトする
  Prism.highlightElement(highlightCode);
}

// 入力されるたびに同期してハイライトを更新
inputArea.addEventListener("input", updateHighlight);

// スクロール位置を完全に同期させる
inputArea.addEventListener("scroll", () => {
  highlightPre.scrollTop = inputArea.scrollTop;
  highlightPre.scrollLeft = inputArea.scrollLeft;
});

// 初期実行
updateHighlight();
