// Markdown -> HTML, run inside JavaScriptCore (no DOM). The page itself runs no scripts.
(function () {
  var seen = {};
  var headings = [];

  // Clicks are handled by the app's own script (CodeCopy.swift), not by the page.
  var COPY_BUTTON =
    '<button class="copy" type="button" title="Copy" aria-label="Copy code">' +
    '<svg class="icon-copy" viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/>' +
    '<path d="M10.5 5.5V3.75c0-.69-.56-1.25-1.25-1.25h-5.5c-.69 0-1.25.56-1.25 1.25v5.5c0 .69.56 1.25 1.25 1.25H5.5"/></svg>' +
    '<svg class="icon-check" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-6.5"/></svg>' +
    '</button>';

  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function plainText(html) {
    return html
      .replace(/<[^>]*>/g, '')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&')
      .trim();
  }

  // GitHub-style heading ids, so links like [x](#some-heading) work.
  function slugify(text) {
    var base = text
      .toLowerCase()
      .trim()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '')
      .replace(/\s+/g, '-');
    var n = seen[base] || 0;
    seen[base] = n + 1;
    return n ? base + '-' + n : base;
  }

  marked.use({
    gfm: true,
    renderer: {
      heading: function (token) {
        var inner = this.parser.parseInline(token.tokens);
        var text = plainText(inner);
        var id = slugify(text);
        var d = token.depth;
        headings.push({ level: d, text: text, id: id });
        return '<h' + d + ' id="' + escapeHtml(id) + '">' + inner + '</h' + d + '>\n';
      },
      code: function (token) {
        var lang = (token.lang || '').trim().split(/\s+/)[0].toLowerCase();
        var body = null;
        if (lang && hljs.getLanguage(lang)) {
          try {
            body = hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value;
          } catch (e) {}
        }
        if (body === null) body = escapeHtml(token.text);
        var cls = lang ? ' class="language-' + escapeHtml(lang) + '"' : '';
        return '<div class="code-block"><pre><code' + cls + '>' + body + '</code></pre>' + COPY_BUTTON + '</div>\n';
      }
    }
  });

  globalThis.nxmdRender = function (md) {
    seen = {};
    headings = [];
    md = md
      .replace(/^﻿/, '')
      .replace(/^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)\r?\n/, ''); // YAML front matter
    var html = marked.parse(md);
    return { html: html, headings: headings };
  };

  globalThis.nxmdSource = function (md) {
    var body = hljs.highlight(md, { language: 'markdown', ignoreIllegals: true }).value;
    return '<pre class="source"><code>' + body + '</code></pre>';
  };
})();
