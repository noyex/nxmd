// Markdown -> HTML, run inside JavaScriptCore (no DOM). The page itself runs no scripts.
(function () {
  var seen = {};

  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // GitHub-style heading ids, so links like [x](#some-heading) work.
  function slugify(text) {
    var base = text
      .toLowerCase()
      .trim()
      .replace(/<[^>]*>/g, '')
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
        var d = token.depth;
        return '<h' + d + ' id="' + escapeHtml(slugify(token.text)) + '">' + inner + '</h' + d + '>\n';
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
        return '<pre><code' + cls + '>' + body + '</code></pre>\n';
      }
    }
  });

  globalThis.nxmdRender = function (md) {
    seen = {};
    md = md
      .replace(/^﻿/, '')
      .replace(/^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)\r?\n/, ''); // YAML front matter
    return marked.parse(md);
  };
})();
