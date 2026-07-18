import Foundation

enum MarginNotesWebScript {
    static let messageHandlerName = "clearanceMarginNotes"

    static let source = #"""
    (() => {
      if (window.clearanceMarginNotes) { return; }

      const article = document.querySelector('article.markdown');
      if (!article) { return; }

      const style = document.createElement('style');
      style.textContent = `
        .clearance-note-anchor {
          background: color-mix(in srgb, #ffd60a 30%, transparent);
          border-bottom: 1px solid color-mix(in srgb, #b88600 65%, transparent);
          border-radius: 2px;
          color: inherit;
          cursor: pointer;
        }
        .clearance-note-anchor[data-clearance-note-active="true"] {
          background: color-mix(in srgb, #ffd60a 52%, transparent);
        }
        .clearance-margin-note {
          position: absolute;
          z-index: 20;
          box-sizing: border-box;
          width: 240px;
          padding: 11px 34px 11px 12px;
          border: 1px solid color-mix(in srgb, var(--surface-border) 88%, transparent);
          border-left: 3px solid #e0a800;
          border-radius: 9px;
          background: color-mix(in srgb, var(--surface) 96%, #fff4bd);
          color: var(--text);
          box-shadow: 0 5px 18px rgba(0, 0, 0, 0.10);
          font: 13px/1.45 -apple-system, BlinkMacSystemFont, sans-serif;
          overflow-wrap: anywhere;
          cursor: default;
        }
        .clearance-margin-note:hover {
          border-color: color-mix(in srgb, #e0a800 55%, var(--surface-border));
        }
        .clearance-margin-note-delete {
          position: absolute;
          top: 5px;
          right: 6px;
          border: 0;
          padding: 3px 5px;
          background: transparent;
          color: var(--muted);
          font: 15px/1 -apple-system, BlinkMacSystemFont, sans-serif;
          cursor: pointer;
        }
        .clearance-add-note {
          position: absolute;
          z-index: 40;
          border: 1px solid color-mix(in srgb, var(--surface-border) 88%, transparent);
          border-radius: 7px;
          padding: 5px 9px;
          background: var(--surface);
          color: var(--text);
          box-shadow: 0 4px 14px rgba(0, 0, 0, 0.14);
          font: 600 12px/1.2 -apple-system, BlinkMacSystemFont, sans-serif;
          cursor: pointer;
        }
        .clearance-note-editor {
          position: absolute;
          z-index: 50;
          box-sizing: border-box;
          width: 260px;
          padding: 10px;
          border: 1px solid color-mix(in srgb, #e0a800 55%, var(--surface-border));
          border-radius: 10px;
          background: var(--surface);
          box-shadow: 0 10px 30px rgba(0, 0, 0, 0.18);
        }
        .clearance-note-editor textarea {
          box-sizing: border-box;
          width: 100%;
          min-height: 80px;
          resize: vertical;
          border: 1px solid var(--surface-border);
          border-radius: 6px;
          padding: 7px;
          background: var(--bg);
          color: var(--text);
          font: 13px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
        }
        .clearance-note-editor-actions {
          display: flex;
          justify-content: flex-end;
          gap: 7px;
          margin-top: 8px;
        }
        .clearance-note-editor-actions button {
          border: 1px solid var(--surface-border);
          border-radius: 6px;
          padding: 4px 9px;
          background: var(--bg);
          color: var(--text);
          font: 12px -apple-system, BlinkMacSystemFont, sans-serif;
          cursor: pointer;
        }
        .clearance-note-editor-actions button[data-primary="true"] {
          border-color: #d19a00;
          background: #e0a800;
          color: #1d1d1f;
          font-weight: 600;
        }
      `;
      document.head.appendChild(style);

      let notes = [];
      let addButton = null;
      let editor = null;
      let pendingSelection = null;

      const post = (payload) => {
        window.webkit?.messageHandlers?.clearanceMarginNotes?.postMessage(payload);
      };

      const textNodes = () => {
        const nodes = [];
        const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            if (!node.nodeValue || !node.nodeValue.length) { return NodeFilter.FILTER_REJECT; }
            if (node.parentElement?.closest('.clearance-margin-note, .clearance-note-editor, .clearance-add-note')) {
              return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        while (walker.nextNode()) { nodes.push(walker.currentNode); }
        return nodes;
      };

      const textMap = () => {
        const entries = [];
        let text = '';
        for (const node of textNodes()) {
          const start = text.length;
          text += node.nodeValue;
          entries.push({ node, start, end: text.length });
        }
        return { text, entries };
      };

      const unwrapAnchors = () => {
        for (const mark of Array.from(article.querySelectorAll('.clearance-note-anchor'))) {
          mark.replaceWith(document.createTextNode(mark.textContent || ''));
        }
        article.normalize();
      };

      const bestMatch = (text, note) => {
        let index = text.indexOf(note.quote);
        let bestIndex = -1;
        let bestScore = -1;
        while (index !== -1) {
          let score = 0;
          if (!note.prefix || text.slice(Math.max(0, index - note.prefix.length), index) === note.prefix) {
            score += 2;
          }
          const end = index + note.quote.length;
          if (!note.suffix || text.slice(end, end + note.suffix.length) === note.suffix) {
            score += 2;
          }
          if (score > bestScore) {
            bestScore = score;
            bestIndex = index;
          }
          index = text.indexOf(note.quote, index + 1);
        }
        return bestIndex;
      };

      const wrapMatch = (entries, start, end, id) => {
        const touched = entries.filter((entry) => entry.end > start && entry.start < end).reverse();
        for (const entry of touched) {
          const localStart = Math.max(0, start - entry.start);
          const localEnd = Math.min(entry.node.nodeValue.length, end - entry.start);
          if (localStart >= localEnd) { continue; }
          const range = document.createRange();
          range.setStart(entry.node, localStart);
          range.setEnd(entry.node, localEnd);
          const mark = document.createElement('mark');
          mark.className = 'clearance-note-anchor';
          mark.dataset.clearanceNoteId = id;
          range.surroundContents(mark);
        }
      };

      const removeNoteElements = () => {
        for (const element of document.querySelectorAll('.clearance-margin-note')) {
          element.remove();
        }
      };

      const positionNotes = () => {
        const documentRect = document.querySelector('.document')?.getBoundingClientRect();
        if (!documentRect) { return; }
        const elements = Array.from(document.querySelectorAll('.clearance-margin-note'));
        const desiredLeft = documentRect.right + window.scrollX + 20;
        const maxLeft = window.scrollX + window.innerWidth - 272;
        const left = Math.max(window.scrollX + 16, Math.min(desiredLeft, maxLeft));
        let nextTop = 16;
        elements.sort((a, b) => Number(a.dataset.anchorTop) - Number(b.dataset.anchorTop));
        for (const element of elements) {
          const desiredTop = Number(element.dataset.anchorTop);
          const top = Math.max(desiredTop, nextTop);
          element.style.left = `${left}px`;
          element.style.top = `${top}px`;
          nextTop = top + element.offsetHeight + 8;
        }
      };

      const closeEditor = () => {
        editor?.remove();
        editor = null;
      };

      const openEditor = ({ top, left, value = '', onSave }) => {
        closeEditor();
        editor = document.createElement('div');
        editor.className = 'clearance-note-editor';
        editor.style.top = `${Math.max(12, top)}px`;
        editor.style.left = `${Math.max(12, Math.min(left, window.scrollX + window.innerWidth - 280))}px`;
        const textarea = document.createElement('textarea');
        textarea.placeholder = 'Add a note…';
        textarea.value = value;
        const actions = document.createElement('div');
        actions.className = 'clearance-note-editor-actions';
        const cancel = document.createElement('button');
        cancel.textContent = 'Cancel';
        cancel.addEventListener('click', closeEditor);
        const save = document.createElement('button');
        save.textContent = 'Save';
        save.dataset.primary = 'true';
        save.addEventListener('click', () => {
          const value = textarea.value.trim();
          if (!value) { return; }
          onSave(value);
          closeEditor();
        });
        actions.append(cancel, save);
        editor.append(textarea, actions);
        document.body.appendChild(editor);
        textarea.focus();
        textarea.setSelectionRange(textarea.value.length, textarea.value.length);
      };

      const render = () => {
        closeEditor();
        addButton?.remove();
        addButton = null;
        removeNoteElements();
        unwrapAnchors();
        for (const note of notes) {
          const map = textMap();
          const start = bestMatch(map.text, note);
          if (start < 0) { continue; }
          wrapMatch(map.entries, start, start + note.quote.length, note.id);
        }

        for (const note of notes) {
          const anchor = article.querySelector(`.clearance-note-anchor[data-clearance-note-id="${CSS.escape(note.id)}"]`);
          if (!anchor) { continue; }
          const bubble = document.createElement('aside');
          bubble.className = 'clearance-margin-note';
          bubble.dataset.clearanceNoteId = note.id;
          bubble.dataset.anchorTop = String(anchor.getBoundingClientRect().top + window.scrollY - 8);
          bubble.textContent = note.text;
          bubble.title = `Selected text: ${note.quote}`;
          const deleteButton = document.createElement('button');
          deleteButton.className = 'clearance-margin-note-delete';
          deleteButton.textContent = '×';
          deleteButton.title = 'Delete Note';
          deleteButton.addEventListener('click', (event) => {
            event.stopPropagation();
            post({ action: 'delete', id: note.id });
          });
          bubble.appendChild(deleteButton);
          bubble.addEventListener('click', () => {
            const rect = bubble.getBoundingClientRect();
            openEditor({
              top: rect.top + window.scrollY,
              left: rect.left + window.scrollX,
              value: note.text,
              onSave: (text) => post({ action: 'update', id: note.id, text })
            });
          });
          bubble.addEventListener('mouseenter', () => {
            for (const element of article.querySelectorAll(`[data-clearance-note-id="${CSS.escape(note.id)}"]`)) {
              element.dataset.clearanceNoteActive = 'true';
            }
          });
          bubble.addEventListener('mouseleave', () => {
            for (const element of article.querySelectorAll(`[data-clearance-note-id="${CSS.escape(note.id)}"]`)) {
              element.removeAttribute('data-clearance-note-active');
            }
          });
          document.body.appendChild(bubble);
        }
        requestAnimationFrame(positionNotes);
      };

      const selectionAnchor = () => {
        const selection = window.getSelection();
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { return null; }
        const range = selection.getRangeAt(0);
        if (!article.contains(range.commonAncestorContainer)) { return null; }
        const quote = selection.toString().trim();
        if (!quote) { return null; }

        const map = textMap();
        let start = -1;
        for (const entry of map.entries) {
          if (entry.node === range.startContainer) {
            start = entry.start + range.startOffset;
            break;
          }
        }
        if (start < 0) {
          start = map.text.indexOf(quote);
        }
        if (start < 0) { return null; }
        const normalizedStart = map.text.indexOf(quote, Math.max(0, start - 2));
        if (normalizedStart >= 0) { start = normalizedStart; }
        return {
          quote,
          prefix: map.text.slice(Math.max(0, start - 48), start),
          suffix: map.text.slice(start + quote.length, start + quote.length + 48),
          rect: range.getBoundingClientRect()
        };
      };

      document.addEventListener('mouseup', () => {
        setTimeout(() => {
          addButton?.remove();
          addButton = null;
          const anchor = selectionAnchor();
          if (!anchor) { return; }
          pendingSelection = anchor;
          addButton = document.createElement('button');
          addButton.className = 'clearance-add-note';
          addButton.textContent = '+ Note';
          addButton.style.top = `${anchor.rect.bottom + window.scrollY + 6}px`;
          addButton.style.left = `${Math.min(anchor.rect.right + window.scrollX, window.scrollX + window.innerWidth - 80)}px`;
          addButton.addEventListener('mousedown', (event) => event.preventDefault());
          addButton.addEventListener('click', () => {
            const selected = pendingSelection;
            if (!selected) { return; }
            addButton?.remove();
            addButton = null;
            openEditor({
              top: selected.rect.bottom + window.scrollY + 8,
              left: selected.rect.right + window.scrollX + 8,
              onSave: (text) => post({
                action: 'create',
                quote: selected.quote,
                prefix: selected.prefix,
                suffix: selected.suffix,
                text
              })
            });
          });
          document.body.appendChild(addButton);
        }, 0);
      });

      document.addEventListener('mousedown', (event) => {
        if (!event.target.closest('.clearance-add-note, .clearance-note-editor, .clearance-margin-note')) {
          closeEditor();
        }
      });
      window.addEventListener('resize', positionNotes);

      window.clearanceMarginNotes = {
        setNotes(value) {
          notes = Array.isArray(value) ? value : [];
          render();
        },
        reposition: positionNotes
      };
    })();
    """#
}
