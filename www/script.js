const worker = new Worker("worker.js", { type: "module" });
const runBtn = document.querySelector("#run");
const samples = document.querySelector("#samples");
const inputArea = document.querySelector("#input");
const highlightPre = document.querySelector("#highlight");
const highlightCode = highlightPre.querySelector("code");
const outputPre = document.querySelector("#output");
let busy = false;

function run(source) {
  if (busy) return;
  busy = true;

  runBtn.disabled = true;
  outputPre.innerHTML = "";

  return new Promise((resolve) => {
    resolve(worker.postMessage(source));
  });
}

function appendOutput(text, isErr) {
  const html = `<span class="${isErr ? "err" : "out"}">${text}</span>`;
  document.querySelector("#output").innerHTML += html;
}

function updateHighlight() {
  let text = inputArea.value;
  if (text[text.length - 1] === "\n") text += " ";

  highlightCode.textContent = text;

  Prism.highlightElement(highlightCode);
}

worker.addEventListener("message", (e) => {
  switch (e.data.type) {
    case "write":
      appendOutput(e.data.text, e.data.isErr);
      break;

    case "result":
      runBtn.disabled = false;
      busy = false;
      break;
  }
});

runBtn.addEventListener("click", () => run(inputArea.value));

samples.addEventListener("change", async () => {
  const response = await fetch(`samples/${samples.value}.lox`);
  const text = await response.text();
  inputArea.value = text;
  updateHighlight();
});

inputArea.addEventListener("keydown", (e) => {
  if (e.ctrlKey && e.key === "Enter") run(inputArea.value);
});
inputArea.addEventListener("input", updateHighlight);
inputArea.addEventListener("scroll", () => {
  highlightPre.scrollTop = inputArea.scrollTop;
  highlightPre.scrollLeft = inputArea.scrollLeft;
});
