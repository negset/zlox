const worker = new Worker("worker.js", { type: "module" });
const runBtn = document.querySelector("#run");
const runBtnText = runBtn.textContent;
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
  runBtn.textContent = "Running...";
  outputPre.innerHTML = "";

  return new Promise((resolve) => {
    resolve(worker.postMessage(source));
  });
}

function appendOutput(text, isErr) {
  const span = document.createElement("span");
  span.className = isErr ? "err" : "out";
  span.textContent = text;

  outputPre.appendChild(span);

  requestAnimationFrame(() => {
    outputPre.scrollTop = outputPre.scrollHeight;
  });
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
      busy = false;
      runBtn.disabled = false;
      runBtn.textContent = runBtnText;
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
inputArea.addEventListener("input", () => {
  samples.value = "";
  updateHighlight();
});
inputArea.addEventListener("scroll", () => {
  highlightPre.scrollTop = inputArea.scrollTop;
  highlightPre.scrollLeft = inputArea.scrollLeft;
});

// ref: https://prismjs.com/extending
Prism.languages.lox = {
  "comment": {
    pattern: /\/\/.*/,
    greedy: true,
  },
  "string": {
    pattern: /"[\s\S]*?"/,
    greedy: true,
  },
  "class-name": [
    {
      pattern: /(\bclass\s+\w+\s*<\s*)\w+/,
      lookbehind: true,
    },
    {
      pattern: /(\bclass\s+)\w+/,
      lookbehind: true,
    },
  ],
  "keyword":
    /\b(?:class|else|for|fun|if|print|return|super|this|var|while)\b/,
  "boolean": /\b(?:false|true)\b/,
  "function": /\b\w+(?=\()/,
  "number": /\b\d+(?:\.\d+)?\b/,
  "operator": /[+\-*/!]|[<>]=?|[!=]=|\b(?:and|or)\b/,
  "punctuation": /[{};(),.]/,
  "constant": /\bnil\b/,
};
