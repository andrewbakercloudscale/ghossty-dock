// Ghostty Dock's file viewer: renders the file named after the # of this
// page's address. Markdown is rendered, source and text files highlighted,
// images shown, Mermaid diagrams drawn. The app serves this page, and the file under /f<path> of
// the same origin, over dockview:// (DockViewer.swift), and calls
// dockReload() when the file changes.

const MARKDOWN = ['md', 'markdown', 'mdown', 'mkd', 'mdx'];
const IMAGES = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'tif', 'tiff', 'heic'];
// Above this a file is shown as plain text: highlighting it takes too long.
const HIGHLIGHT_LIMIT = 1024 * 1024;
const NAMES = { svg: 'xml', sh: 'bash', zsh: 'bash', mm: 'objectivec', m: 'objectivec', h: 'cpp', hpp: 'cpp',
                yml: 'yaml', jsonl: 'json', mjs: 'javascript', cjs: 'javascript', tsx: 'typescript',
                jsx: 'javascript', kt: 'kotlin', rs: 'rust', py: 'python', rb: 'ruby', zig: 'zig',
                tsv: 'plaintext', csv: 'plaintext', txt: 'plaintext', log: 'plaintext' };

const path = decodeURIComponent(location.hash.slice(1));
const name = path.split('/').pop();
const ext = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
const fileURL = p => 'dockview://app/f' + p.split('/').map(encodeURIComponent).join('/');
const doc = document.getElementById('doc');

// What goes wrong here is logged by the app (category "files").
function report(message) {
  try { window.webkit.messageHandlers.viewer.postMessage(String(message)); } catch {}
}
window.addEventListener('error', e => report(`${e.message} (${e.filename}:${e.lineno})`));
window.addEventListener('unhandledrejection', e => report(e.reason));

function escape(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function language(ext) {
  const lang = NAMES[ext] || ext;
  return hljs.getLanguage(lang) ? lang : null;
}

function highlight(text, lang) {
  if (text.length > HIGHLIGHT_LIMIT || !lang || lang === 'plaintext') return escape(text);
  try { return hljs.highlight(text, { language: lang, ignoreIllegals: true }).value; } catch { return escape(text); }
}

// Raw HTML in a file is shown as text, not run: the page can read files.
const md = window.markdownit({ html: false, linkify: true, typographer: false,
  highlight: (code, lang) => {
    if ((lang || '').toLowerCase() === 'mermaid') return `<pre class="mermaid">${escape(code)}</pre>`;
    const l = language((lang || '').toLowerCase());
    return l ? `<pre><code class="hljs language-${l}">${highlight(code, l)}</code></pre>` : '';
  } });

// GitHub's task lists: "- [ ]" and "- [x]".
function tasks(root) {
  for (const li of root.querySelectorAll('li')) {
    const first = li.firstChild?.nodeType === 3 ? li.firstChild
      : li.firstElementChild?.tagName === 'P' ? li.firstElementChild.firstChild : null;
    const m = first?.nodeType === 3 && /^\[([ xX])\]\s/.exec(first.textContent);
    if (!m) continue;
    first.textContent = first.textContent.slice(m[0].length);
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.disabled = true;
    box.checked = m[1] !== ' ';
    first.parentNode.insertBefore(box, first);
    li.classList.add('task');
  }
}

// Mermaid is big: it is loaded only for a file with a diagram. From the
// page's own address, not the file's folder that <base> points at.
let mermaidLoaded;
function loadMermaid() {
  mermaidLoaded ??= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'dockview://app/mermaid.min.js';
    script.onload = () => {
      // Strict: a diagram's labels are text, and its click handlers are off.
      const dark = matchMedia('(prefers-color-scheme: dark)').matches;
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' });
      resolve();
    };
    script.onerror = () => reject(new Error('could not load mermaid.min.js'));
    document.head.append(script);
  });
  return mermaidLoaded;
}

// Each diagram on its own, so one that does not parse keeps its source,
// with why, and the rest are still drawn.
async function diagrams(root) {
  const blocks = [...root.querySelectorAll('pre.mermaid')];
  if (!blocks.length) return;
  try { await loadMermaid(); } catch (e) { report(e.message); return; }
  for (const [i, pre] of blocks.entries()) {
    try {
      // Parsed first: render() left half done by a bad diagram never
      // finishes the next one.
      await mermaid.parse(pre.textContent);
      const { svg } = await mermaid.render(`diagram-${Date.now()}-${i}`, pre.textContent);
      const figure = document.createElement('div');
      figure.className = 'diagram';
      figure.innerHTML = svg;
      pre.replaceWith(figure);
    } catch (e) {
      const note = document.createElement('p');
      note.className = 'note diagram-error';
      note.textContent = `This diagram did not draw: ${String(e.message || e).split('\n')[0]}`;
      pre.after(note);
      report(`diagram ${i + 1} in ${path}: ${e.message || e}`);
    }
  }
}

async function renderMarkdown(text) {
  doc.className = 'md';
  doc.innerHTML = md.render(text);
  tasks(doc);
  await diagrams(doc);
}

function renderCode(text) {
  doc.className = 'code';
  const lines = text.split('\n');
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
  const numbers = lines.map((_, i) => i + 1).join('\n');
  const lang = language(ext);
  doc.innerHTML = `<table><tr><td class="n"><pre>${numbers}</pre></td>` +
    `<td><pre><code class="hljs">${highlight(text, lang)}</code></pre></td></tr></table>`;
}

// Marked when done, diagrams and all (the viewer test waits for it).
async function render() {
  delete doc.dataset.rendered;
  try { await show(); } finally { doc.dataset.rendered = '1'; }
}

async function show() {
  document.title = name;
  if (IMAGES.includes(ext)) {
    doc.className = 'image';
    doc.innerHTML = `<img src="${fileURL(path)}?${Date.now()}" alt="${escape(name)}">`;
    return;
  }
  let text;
  try {
    const res = await fetch(fileURL(path), { cache: 'no-store' });
    if (!res.ok) throw new Error(await res.text() || res.statusText);
    text = await res.text();
  } catch (e) {
    doc.className = '';
    doc.innerHTML = `<p class="note">Could not read ${escape(path)}: ${escape(e.message)}</p>`;
    report(`could not read ${path}: ${e.message}`);
    return;
  }
  if (MARKDOWN.includes(ext)) await renderMarkdown(text); else renderCode(text);
}

// Relative links and images in a file are relative to its folder.
const base = document.createElement('base');
base.href = fileURL(path.slice(0, path.lastIndexOf('/') + 1));
document.head.prepend(base);

window.dockReload = async () => {
  const y = window.scrollY;
  await render();
  window.scrollTo(0, y);
};

render();
