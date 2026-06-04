"use strict";

async function initWasm() {
  function js_out(ptr, len) {
    const bytes = new Uint8Array(memory.buffer, ptr, len);
    console.log(decoder.decode(bytes));
  }

  const response = await fetch("zlox.wasm");
  const bytes = await response.arrayBuffer();
  const module = new WebAssembly.Module(bytes);
  const memory = new WebAssembly.Memory({
    initial: 20,
    maximum: 200,
  });
  const instance = new WebAssembly.Instance(module, {
    env: { memory, js_out },
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

function run(string) {
  const slice = allocateString(string);
  wasm.runSource(slice.ptr, slice.len);
  wasm.free(slice.ptr, slice.len);
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const { wasm, memory } = await initWasm();

run("hello world!");
