import Foundation

/// The atomic DOM snapshot, evaluated once per observation.
///
/// **One browser call reads the whole screen.** That is the entire point, and it
/// is where `browser-use/jev-ultrafast` measured browser protocol calls dropping
/// from 1,092 to 101 on the same task. Resolving nodes one round trip at a time
/// is what makes a DOM-driven agent slow; a design that re-reads after every
/// mutation pays that cost on every step.
///
/// Embedded as a string rather than a bundled resource deliberately: a resource
/// lookup can fail at runtime on a binary that built fine, and the failure mode
/// is an agent that reports an empty page instead of an error. A string cannot
/// go missing.
///
/// Design adapted from `browser-use/jev-ultrafast` (MIT). See ADR 0010.
enum SnapshotScript {

  /// The stale-target fingerprint, defined once.
  ///
  /// **It used to be written twice** — once here and once inline in
  /// `BiDiExecutor` — and the two never agreed. The snapshot hashed the
  /// computed role and the ARIA name; the executor hashed
  /// `getAttribute('role') || tagName` and `innerText`. For an `<a href>` one
  /// said `link` and the other said `a`, and for any control whose accessible
  /// name is not its text they disagreed outright. Every comparison was
  /// therefore a coin flip, and on Instagram it came up "stale" on a row that
  /// had not moved.
  ///
  /// Identity and geometry only. The element id already says it is the same
  /// node, so text added nothing and made the check brittle on live content: a
  /// conversation row rewrites its own preview and timestamp every few seconds.
  /// What this answers is "did the page move under me" — did it shift, or
  /// become disabled, between the decision and the click.
  static let guardFunction = #"""
    window.__oaRole = window.__oaRole || ((el) => {
      const ROLES = new Set([
        'button','link','checkbox','radio','textbox','combobox','listbox','option',
        'menuitem','menuitemcheckbox','menuitemradio','tab','switch','searchbox','slider',
      ]);
      const explicit = (el.getAttribute('role') || '').toLowerCase();
      if (ROLES.has(explicit)) return explicit;
      switch (el.tagName) {
        case 'BUTTON': return 'button';
        case 'A': return el.hasAttribute('href') ? 'link' : '';
        case 'SELECT': return 'combobox';
        case 'TEXTAREA': return 'textbox';
        case 'SUMMARY': return 'button';
        case 'INPUT': {
          const t = (el.type || 'text').toLowerCase();
          if (t === 'checkbox') return 'checkbox';
          if (t === 'radio') return 'radio';
          if (t === 'search') return 'searchbox';
          if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
          return 'textbox';
        }
        default:
          return el.isContentEditable ? 'textbox' : (explicit || '');
      }
    });

    window.__oaGuard = window.__oaGuard || ((el, roleValue) => {
      const r = el.getBoundingClientRect();
      const off = el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true';
      return [roleValue, Math.round(r.left), Math.round(r.top), off ? 1 : 0].join('|');
    });
    """#

  /// Returns a single JSON object. Every field the harness reads is documented
  /// in `BiDiSnapshot`.
  static let source = #"""
    (() => {
      \#(guardFunction)
      const MAX_ACTIONS = 250;      // their cap; ours is Constants.Jev.maxCandidates = 255
      const TEXT_LIMIT  = 6000;

      // Identity survives between snapshots so a target chosen from snapshot N
      // can still be resolved in snapshot N+1 — that is what makes staleness
      // detectable rather than silent.
      if (!window.__openAgent) {
        window.__openAgent = { ids: new WeakMap(), nodes: new Map(), next: 1 };
      }
      const C = window.__openAgent;

      const identity = (el) => {
        let id = C.ids.get(el);
        if (id === undefined) { id = C.next++; C.ids.set(el, id); }
        C.nodes.set(id, el);
        return id;
      };

      // A password or file input is never a target. Typing into one would put a
      // credential in a log, and `risk_credential` is advisory — this is not.
      const safe = (el) => {
        if (el.tagName !== 'INPUT') return true;
        return !['password', 'file', 'hidden'].includes((el.type || '').toLowerCase());
      };

      const visible = (el) => {
        if (!el.isConnected) return false;
        if (el.closest('[aria-hidden="true"],[inert]')) return false;
        const s = getComputedStyle(el);
        if (s.visibility === 'hidden' || s.display === 'none') return false;
        if (parseFloat(s.opacity || '1') === 0) return false;
        return true;
      };

      const textOf = (el) => {
        let out = '';
        for (const n of el.childNodes) {
          if (n.nodeType === 3) out += n.nodeValue;
          else if (n.nodeType === 1 && n.getAttribute('aria-hidden') !== 'true') {
            out += textOf(n);
          }
        }
        return out;
      };

      // **A control can name itself twice.** An icon carries an SVG `<title>`
      // and the link repeats the word in a visually hidden span, so the text
      // content reads `MessagesMessages` — and nothing a person would write
      // matches that. Measured: Instagram's Messages rail item came back at
      // 0.67 selection confidence and stopped the run for a screenshot.
      //
      // Only an exact doubling collapses. `bonbon` would be halved too, and
      // that is the price of a rule this simple: it costs a message preview a
      // syllable, and it wins back every icon-with-hidden-label control on the
      // page.
      const undouble = (s) => {
        const half = s.length / 2;
        return (s.length > 3 && s.length % 2 === 0 && s.slice(0, half) === s.slice(half))
          ? s.slice(0, half)
          : s;
      };

      // Cascading accessible name. Not the full accessible-name algorithm — the
      // common HTML and ARIA cases, in the order that actually resolves real
      // pages. An element nothing can name is dropped rather than guessed at.
      const name = (el) => {
        const byIds = el.getAttribute('aria-labelledby');
        if (byIds) {
          const joined = byIds.split(/\s+/)
            .map((id) => document.getElementById(id))
            .filter(Boolean).map(textOf).join(' ').trim();
          if (joined) return joined;
        }
        const aria = el.getAttribute('aria-label');
        if (aria && aria.trim()) return aria.trim();

        if (el.id) {
          const lab = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
          if (lab && textOf(lab).trim()) return textOf(lab).trim();
        }
        const wrapping = el.closest('label');
        if (wrapping && textOf(wrapping).trim()) return textOf(wrapping).trim();

        if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes((el.type || '').toLowerCase())) {
          if (el.value) return String(el.value).trim();
        }
        if (el.alt && el.alt.trim()) return el.alt.trim();

        const own = undouble(textOf(el).replace(/\s+/g, ' ').trim());
        if (own) return own.slice(0, 200);

        const img = el.querySelector('img[alt]');
        if (img && img.alt.trim()) return img.alt.trim();

        // `aria-placeholder` is how a `contenteditable` composer names itself
        // — there is no `placeholder` attribute on a div. Instagram's message
        // box carries one and nothing else, so it was dropped for having no
        // name, and a conversation offered its emoji, voice, photo and GIF
        // buttons while the thing you type into was absent from the list.
        const t = el.getAttribute('title')
          || el.getAttribute('placeholder')
          || el.getAttribute('aria-placeholder');
        if (t && t.trim()) return t.trim();

        // A text box with no name at all is still the only thing on the page
        // you can type into. Naming it by its role keeps it addressable instead
        // of invisible; a nameless *button* stays dropped, because there is
        // nothing to tell one from another and the denylist has nothing to read.
        const r = window.__oaRole(el);
        if (r === 'textbox' || r === 'searchbox') return r;
        return '';
      };

      const ROLES = new Set([
        'button','link','checkbox','radio','textbox','combobox','listbox','option',
        'menuitem','menuitemcheckbox','menuitemradio','tab','switch','searchbox','slider',
      ]);

      const role = (el) => window.__oaRole(el);

      const kindOf = (el, r) => {
        if (r === 'combobox' && el.tagName === 'SELECT') return 'select';
        if (r === 'textbox' || r === 'searchbox') return 'fill';
        if (el.isContentEditable) return 'fill';
        return 'click';
      };

      const disabled = (el) =>
        el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true';

      // Open shadow roots are pierced. `element-sources.md` specified this before
      // ADR 0010 and it is the one place our reader goes further than the design
      // it is adapted from. Closed roots are unreachable by construction.
      const collect = (root, out) => {
        const SELECTOR =
          'a[href],button,input,textarea,select,summary,[contenteditable],' +
          '[role="button"],[role="link"],[role="checkbox"],[role="radio"],[role="tab"],' +
          '[role="menuitem"],[role="switch"],[role="combobox"],[role="textbox"],[role="option"]';
        for (const el of root.querySelectorAll(SELECTOR)) out.push(el);
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) collect(el.shadowRoot, out);
        }
      };

      const vw = window.innerWidth, vh = window.innerHeight;
      const raw = [];
      collect(document, raw);

      const actions = [];
      const guards = {};
      const seen = new Set();

      for (const el of raw) {
        if (actions.length >= MAX_ACTIONS) break;
        if (seen.has(el)) continue;
        seen.add(el);

        if (!safe(el) || !visible(el)) continue;

        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) continue;
        // In the viewport, not merely in the document. An element below the fold
        // is not actionable without scrolling, and offering it as a candidate
        // invites a click that silently does nothing.
        if (r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) continue;

        const rr = role(el);
        if (!rr) continue;
        const label = name(el);
        if (!label) continue;

        // A gridcell wrapping its own button is the wrapper, not the control.
        if (el.getAttribute('role') === 'gridcell' && el.querySelector('button')) continue;

        const id = identity(el);
        const key = 'e' + id;

        // What `Enter` would actually activate from this field — ADR 0008.
        // A To-field carries no hint that its form submits to `Send`, and the
        // accessibility API cannot compute this at all. The DOM can, so this is
        // the one tier where `pressKey(.enter)` is classifiable rather than
        // conservatively irreversible.
        let submit = '';
        if (kindOf(el, rr) === 'fill') {
          const form = el.closest('form');
          if (form) {
            const btn = form.querySelector(
              'button[type="submit"],input[type="submit"],button:not([type])'
            );
            if (btn) submit = name(btn);
          }
        }

        // Occlusion: whatever is topmost at the element's centre must be the
        // element, or inside it. A control that has been covered by a modal or a
        // cookie banner is refused rather than clicked through.
        const cx = Math.min(Math.max(r.left + r.width / 2, 0), vw - 1);
        const cy = Math.min(Math.max(r.top + r.height / 2, 0), vh - 1);
        const top = document.elementFromPoint(cx, cy);
        const occluded = !(top && (top === el || el.contains(top) || top.contains(el)));

        actions.push({
          id: key,
          role: rr,
          label: label,
          kind: kindOf(el, rr),
          disabled: disabled(el),
          occluded: occluded,
          x: r.left, y: r.top, w: r.width, h: r.height,
          value: (el.value !== undefined && el.type !== 'password') ? String(el.value).slice(0, 120) : '',
          checked: el.getAttribute('aria-checked') || (el.checked === true ? 'true' : ''),
          expanded: el.getAttribute('aria-expanded') || '',
          submit: submit,
        });

        // Guards are how the executor tells "the page changed under me" from
        // "the click missed". Compared immediately before acting.
        // **Identity and geometry, not text.** The guard answers "did the page
        // move under me" — a control that shifted, or became disabled, between
        // the decision and the click. The element id already says it is the
        // same node, so the label added nothing to that and made the check
        // brittle on anything live: an Instagram conversation row rewrites its
        // own preview and timestamp every few seconds, and the click was
        // refused as stale on a row that had not moved a pixel.
        guards[key] = window.__oaGuard(el, rr);
      }

      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let text = '';
      while (walker.nextNode() && text.length < TEXT_LIMIT) {
        const n = walker.currentNode;
        const p = n.parentElement;
        if (!p) continue;
        if (['SCRIPT', 'STYLE', 'TEMPLATE', 'NOSCRIPT'].includes(p.tagName)) continue;
        const v = n.nodeValue.replace(/\s+/g, ' ').trim();
        if (v) text += v + ' ';
      }

      // What the keyboard is pointing at, by element id.
      //
      // **A keystroke goes where focus is, not where a model guessed.** After a
      // `type` step the composer's accessible name IS the text just typed into
      // it — Instagram's is named `Message` while empty and `hiii orumoni`
      // after — so a plan that named the target when it wrote the step can no
      // longer match it, and the run stalls one keypress short of sending.
      // Reported here so `pressKey` can skip selection altogether.
      //
      // Descends through shadow roots: `document.activeElement` stops at the
      // host, and the field the user is typing in is inside it.
      let af = document.activeElement;
      while (af && af.shadowRoot && af.shadowRoot.activeElement) {
        af = af.shadowRoot.activeElement;
      }
      const focusedID = (af && C.ids.get(af) !== undefined) ? 'e' + C.ids.get(af) : '';

      return {
        url: location.href,
        focused: focusedID,
        title: document.title,
        // Where elements are lost, when none survive. Counted only, never
        // content — this is a funnel, not a page dump.
        funnel: {
          all: document.querySelectorAll('*').length,
          anchors: document.querySelectorAll('a[href]').length,
          buttons: document.querySelectorAll('button,[role="button"]').length,
          raw: raw.length,
          ready: document.readyState,
          // **`complete` is what the document says, not what the page is
          // doing.** X reports `readyState: complete` while its timeline is
          // still a spinner, and a step judged there acts on a page the user
          // can see is still arriving — the pointer sets off before the
          // content lands.
          //
          // A busy region is the page saying so in its own accessible markup,
          // which is the same thing a screen reader is told and the same thing
          // a person sees. Counted, so a page with a permanent progress bar
          // costs the settle ceiling rather than the whole task.
          //
          // **On screen, or it is not what anyone means by loading.** X keeps
          // progress bars in the document permanently — the infinite scroll's
          // next-page spinner lives below the fold from the moment the page
          // exists — so counting them all made every page eternally unfinished
          // and cost the settle ceiling twice a step: 44s for two steps.
          busy: Array.prototype.filter.call(
            document.querySelectorAll('[aria-busy="true"],[role="progressbar"]'),
            (el) => {
              const r = el.getBoundingClientRect();
              return r.width > 0 && r.height > 0
                && r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw
                && visible(el);
            }).length,
        },
        viewport: { w: vw, h: vh },
        // Where the content area sits on screen, in CSS pixels.
        //
        // **`getBoundingClientRect()` is viewport-relative, and `Element.bounds`
        // means screen coordinates everywhere else in this system.** The
        // accessibility tier reports screen space, the overlay converts from
        // screen space, and the browser tier was handing over page space in the
        // same field — so the target box was drawn near the corner of the
        // display while the control sat inside the browser window.
        //
        // `mozInnerScreenX/Y` is exact on Gecko, which is what this drives. The
        // fallback splits the window chrome the usual way for anything else.
        screen: {
          x: (window.mozInnerScreenX !== undefined)
            ? window.mozInnerScreenX
            : window.screenX + (window.outerWidth - vw) / 2,
          y: (window.mozInnerScreenY !== undefined)
            ? window.mozInnerScreenY
            : window.screenY + (window.outerHeight - vh),
        },
        scroll: { y: window.scrollY, height: document.documentElement.scrollHeight },
        text: text.slice(0, TEXT_LIMIT),
        actions: actions,
        guards: guards,
        // A cheap fingerprint of what the agent can see. Two snapshots with the
        // same key are the same screen for decision purposes, which is what
        // `unchanged` is asking about.
        page_key: location.href + '#' + actions.length + ':' +
          actions.map((a) => a.id + a.label).join('').length,
      };
    })()
    """#
}
