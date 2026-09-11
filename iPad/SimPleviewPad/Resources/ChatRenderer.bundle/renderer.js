'use strict';
// Capture math before Markdown consumes backslashes or underscores. Code blocks
// remain code because their tokens do not enter this inline tokenizer.
const escapeAttribute = text => text.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
marked.use({extensions: [{name: 'math', level: 'inline',
  start(src) { const n = src.search(/\$|\\[\[(]/); return n < 0 ? undefined : n; },
  tokenizer(src) {
    const m = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$([^$\n]+?)\$)/.exec(src);
    if (m) return {type:'math', raw:m[0], math:m[1] ?? m[2] ?? m[3] ?? m[4], display:m[1] !== undefined || m[2] !== undefined};
  },
  renderer(t) { return `<span data-math="${escapeAttribute(t.math)}" data-display="${t.display}"></span>`; }
}]});
const root = document.getElementById('content');
function renderContent(markdown) {
  // Model output is untrusted. Bound parsing, sanitize before DOM insertion,
  // and independently forbid network/script execution with the document CSP.
  const truncated = markdown.length > 200000;
  root.innerHTML = DOMPurify.sanitize(marked.parse(markdown.slice(0, 200000)), {
    ALLOWED_TAGS: ['p','br','strong','em','del','blockquote','pre','code','ul','ol','li','h1','h2','h3','h4','h5','h6','hr','table','thead','tbody','tr','td','th','a','span'],
    ALLOWED_ATTR: ['href','title','data-math','data-display'],
    // These two inert attributes contain math text, never resource URLs.
    ADD_URI_SAFE_ATTR: ['data-math','data-display'],
    ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false, ALLOWED_URI_REGEXP: /^https?:\/\//i
  });
  let count = 0;
  for (const span of root.querySelectorAll('span[data-math]')) {
    const math = span.getAttribute('data-math');
    const display = span.getAttribute('data-display') === 'true';
    span.removeAttribute('data-math'); span.removeAttribute('data-display');
    if (++count > 1000 || math.length > 10000) { span.textContent = math; continue; }
    // Raw HTML cannot configure KaTeX. URL/HTML commands and expansion bombs
    // are rejected; only trusted library output is inserted after sanitization.
    katex.render(math, span, {displayMode:display, throwOnError:false,
      trust:false, maxExpand:1000, maxSize:20, strict:'ignore'});
  }
  if (truncated) root.append(document.createTextNode('\n显示已截断；完整内容保留在对话记录中。'));
  return Math.min(30000, Math.max(32, document.documentElement.scrollHeight));
}
