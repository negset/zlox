"use strict";

function js_out(ptr, len) {
  console.log(`[JSDEBUG] js_out | ptr: ${ptr}, len: ${len}`);
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  console.log(decoder.decode(bytes));
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
    maximum: 2000,
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

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const { wasm, memory } = await initWasm();

document.querySelector("#run").addEventListener("click", () => {
  const input = document.querySelector("#input").textContent;
  const source = allocateString(input);
  const result = wasm.runSource(source.ptr, source.len);
  console.log(`result: ${result}`);
  wasm.free(source.ptr, source.len);
});
