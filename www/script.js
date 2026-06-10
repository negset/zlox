function js_write(ptr, len, is_err) {
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  const text = decoder.decode(bytes);
  const html = `<span class="${is_err ? "err" : "out"}">${text}</span>`;
  outputPre.innerHTML += html;
}

function js_now() {
  return Date.now();
}

async function initWasm() {
  const response = await fetch("zlox.wasm");
  const bytes = await response.arrayBuffer();
  const module = new WebAssembly.Module(bytes);
  const memory = new WebAssembly.Memory({ initial: 32 });
  const instance = new WebAssembly.Instance(module, {
    env: { memory, js_write, js_now },
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
  outputPre.innerHTML = "";
  const source = allocateString(inputArea.value);
  const result = wasm.runSource(source.ptr, source.len);
  wasm.free(source.ptr, source.len);
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const { wasm, memory } = await initWasm();

const inputArea = document.querySelector("#input");
const highlightPre = document.querySelector("#highlight");
const highlightCode = highlightPre.querySelector("code");
const outputPre = document.querySelector("#output");
const runBtn = document.querySelector("#run");

runBtn.addEventListener("click", run);
inputArea.addEventListener("keydown", (e) => {
  if (e.ctrlKey && e.key === "Enter") run();
});

function updateHighlight() {
  let text = inputArea.value;
  if (text[text.length - 1] === "\n") text += " ";

  highlightCode.textContent = text;

  Prism.highlightElement(highlightCode);
}

inputArea.addEventListener("input", updateHighlight);
inputArea.addEventListener("scroll", () => {
  highlightPre.scrollTop = inputArea.scrollTop;
  highlightPre.scrollLeft = inputArea.scrollLeft;
});

const samples = document.querySelector("#samples");

samples.addEventListener("change", () => {
  console.log(samples.value);
});
