const encoder = new TextEncoder();
const decoder = new TextDecoder();
const { wasm, memory } = await initWasm();

function jsWrite(ptr, len, isErr) {
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  self.postMessage({
    type: "write",
    text: decoder.decode(bytes),
    isErr,
  });
}

function jsClock() {
  return performance.now() / 1000;
}

async function initWasm() {
  const response = await fetch("zlox.wasm");
  const bytes = await response.arrayBuffer();
  const module = new WebAssembly.Module(bytes);
  const memory = new WebAssembly.Memory({ initial: 32 });
  const instance = new WebAssembly.Instance(module, {
    env: { memory, jsWrite, jsClock },
  });
  return { wasm: instance.exports, memory };
}

function allocateString(string) {
  const bytes = encoder.encode(string);
  const len = bytes.length;

  const ptr = wasm.alloc(len);
  if (ptr === null) throw "Cannot allocate memory.";

  const arr = new Uint8Array(memory.buffer);
  for (let i = 0; i < len; i++) {
    arr[ptr + i] = bytes[i];
  }

  return { ptr, len };
}

self.addEventListener("message", (e) => {
  const source = allocateString(e.data);
  const status = wasm.runSource(source.ptr, source.len);
  self.postMessage({ type: "result", status });
  wasm.free(source.ptr, source.len);
});
