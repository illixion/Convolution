/*
 Hypnos - the script that reads videos off YouTube's mobile site

 Ported from web-yt-dlp's player app (`RecommendationFeed.swift`, removed in
 5aae2c7). It only reads the cards the page already shows: the page itself
 does all the fetching, so the account's traffic is what a phone's Safari
 sends. Card ids come from each card's `/watch?v=` link, which is exact;
 titles, channels and lengths come from the card's text, which is why a
 card is sent again whenever its text changes (the length badge arrives
 after the card does).

 It also keeps the page from playing anything. The mobile site plays a
 muted preview of the top card, and a preview can count as a view. Safari's
 autoplay rule already refuses it while nobody has touched the page, which
 is why the app's own script calls go through `evaluateWithoutUserGesture`:
 WebKit treats `evaluateJavaScript` as a tap. The guard here pauses
 whatever starts anyway (measured on macOS 2026-10-16: without the gesture
 the preview stays at 0 s; with one it plays).

 WKWebView runs this in its own content world, so the page can't see it,
 and delivers through a message handler. The private tvOS `UIWebView` has
 neither: there it runs in the page, payloads queue inside the page for
 native code to drain, and `play()` itself refuses, because every script
 call there counts as a tap and HTML5 video is what crashes it.

 Measured against m.youtube.com on 2026-10-16: `ytm-video-with-context-
 renderer` cards whose byline is [channel, views, age]; the page scrolls
 `body`, not the window; an open dialog (the EU cookie consent, for one)
 fixes `body` in place, so nothing loads until someone answers it.
 */

#if HYPNOS_YOUTUBE

import Foundation

enum YouTubePageScript {
    enum Transport {
        /// WKWebView: an isolated content world and a message handler.
        case messageHandler
        /// tvOS `UIWebView`: the page's own world and a queue to drain.
        case pollingQueue
    }

    static let handlerName = "hypnosYouTubePage"

    /// One delivery: cards that are new or changed, plus the page's state.
    struct Payload: Decodable, Sendable {
        struct Card: Decodable, Sendable {
            var id: String
            var title: String
            var channel: String?
            var duration: String?
            var metadata: [String]?
        }

        var cards: [Card]
        /// Whether the page says it is signed in; nil when it didn't say.
        var loggedIn: Bool?
        /// Whether the page still shows its "load more" marker.
        var hasMore: Bool?
        /// Whether a dialog is open over the page, waiting for an answer.
        var dialog: Bool?
    }

    static func source(_ transport: Transport) -> String {
        let deliver = switch transport {
        case .messageHandler:
            """
            const handler = window.webkit?.messageHandlers?.\(handlerName);
              if (!handler) return;
              const deliver = (payload) => handler.postMessage(payload);
            """
        case .pollingQueue:
            """
            const deliver = (payload) => {
                (window.__hypnosQueue = window.__hypnosQueue || []).push(payload);
              };
            """
        }
        return """
        (() => {
          if (window.__hypnosPageReader) return;
          window.__hypnosPageReader = true;
          \(deliver)

          const stop = (event) => {
            if (event.target instanceof HTMLMediaElement) event.target.pause();
          };
          document.addEventListener('play', stop, true);
          document.addEventListener('playing', stop, true);

          const cardSelector = [
            'ytm-video-with-context-renderer',
            'ytm-rich-item-renderer',
            'ytm-compact-video-renderer',
            'ytm-playlist-video-renderer',
            'ytm-media-item'
          ].join(',');
          // Ads sit in the same rich-item slots as videos.
          const adSelector = 'ytm-ad-slot-renderer,ytm-promoted-sparkles-web-renderer,ytm-promoted-video-renderer,ytm-companion-slot';
          const durationPattern = /^(?:\\d+:)?\\d{1,2}:\\d{2}$/;
          const text = (element) => element?.innerText?.trim().replace(/\\s+/g, ' ') || null;

          const extract = (card) => {
            if (card.matches(adSelector) || card.querySelector(adSelector)) return null;
            const link = card.querySelector('a[href*="/watch?"]');
            if (!link) return null;
            const id = new URL(link.getAttribute('href'), location.origin).searchParams.get('v');
            if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return null;

            // The badge, or failing its markup, the line that is only a time.
            // A preview player that never started shows 0:00 over the card.
            const isLength = (s) => s && durationPattern.test(s) && s !== '0:00';
            let duration = Array.from(card.querySelectorAll([
              'ytm-thumbnail-overlay-time-status-renderer',
              '.video-time',
              '.thumbnail-overlay-badge-shape .badge-shape-wiz__text',
              '.yt-badge-shape__text',
              'badge-shape'
            ].join(','))).map(text).find(isLength)
              || (card.innerText || '').split('\\n').map((s) => s.trim()).find(isLength)
              || null;

            let title = text(card.querySelector('.media-item-headline, ytm-media-item h3, h3'))
              || (text(card) || '').split('•')[0] || null;
            // A card read before its badge settled leads with the length.
            const leading = title?.match(/^((?:\\d+:)?\\d{1,2}:\\d{2})\\s+(\\S.*)/);
            if (leading) {
              duration = duration || (isLength(leading[1]) ? leading[1] : null);
              title = leading[2];
            }
            if (!title) return null;

            const byline = Array.from(card.querySelectorAll(
              'ytm-badge-and-byline-renderer:not([data-is-all-badges="true"]) .ytmBadgeAndBylineRendererItemByline'
            )).map(text).filter((s) => s && s !== title);
            let metadata = byline;
            let channel = text(card.querySelector('.media-channel, .ytm-channel-name'));
            if (byline.length) {
              if (!channel) channel = metadata.shift() || null;
            } else {
              const element = card.querySelector('.media-item-metadata, .video-item-byline');
              metadata = element
                ? Array.from(element.querySelectorAll('span'))
                    .filter((e) => e.children.length === 0)
                    .map(text)
                    .filter((s) => s && s !== title && s !== '•' && s !== '·')
                : [];
            }
            metadata = metadata.filter((s) => s !== channel && !durationPattern.test(s));
            return { id, title, channel, duration, metadata: [...new Set(metadata)] };
          };

          // `ytcfg` is the page's, so a content world can't see it; the
          // same flag is in the page's inline config, read once found.
          let scannedLoggedIn = null;
          const loggedIn = () => {
            try {
              const value = window.ytcfg?.get?.('LOGGED_IN');
              if (typeof value === 'boolean') return value;
            } catch (e) {}
            if (scannedLoggedIn === null) {
              for (const script of document.scripts) {
                const match = script.textContent.match(/"LOGGED_IN":(true|false)/);
                if (match) { scannedLoggedIn = match[1] === 'true'; break; }
              }
            }
            return scannedLoggedIn;
          };

          // The last payload sent for each video, so a card goes again only
          // when what it shows has changed.
          const sent = new Map();
          let sentState = null;

          const publish = () => {
            const cards = [];
            const seen = new Set();
            document.querySelectorAll('a[href*="/watch?"]').forEach((link) => {
              const card = link.closest(cardSelector);
              const item = card && extract(card);
              if (!item || seen.has(item.id)) return;
              seen.add(item.id);
              const key = [item.title, item.channel, item.duration, item.metadata.join('|')].join('\\u0001');
              if (sent.get(item.id) === key) return;
              sent.set(item.id, key);
              cards.push(item);
            });
            const state = {
              loggedIn: loggedIn(),
              hasMore: !!document.querySelector('ytm-continuation-item-renderer'),
              dialog: !!document.querySelector('.dialog-scrollable-content, ytm-consent-bump-v2-renderer')
            };
            const stateKey = JSON.stringify(state);
            if (cards.length || stateKey !== sentState) {
              sentState = stateKey;
              deliver({ cards, ...state });
            }
          };

          publish();
          // Lengths and bylines fill in deep inside cards that already exist;
          // a full rescan is a few milliseconds, and 400 ms of quiet batches it.
          let rescan = null;
          new MutationObserver(() => {
            if (rescan) return;
            rescan = setTimeout(() => {
              rescan = null;
              publish();
            }, 400);
          }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
        })();
        """
    }

    /// tvOS `UIWebView` only, run as each page's window is created (before
    /// any of its scripts; see `YouTubePageSession`), in every page the
    /// app's `UIWebView`s load. Two things that page can't do itself:
    ///
    /// - refuse `play()`, as Safari does without a tap. Every script call
    ///   there counts as a tap, and HTML5 video crashes it.
    /// - `IntersectionObserver`. Its own never reports anything coming into
    ///   view (measured in the tvOS 26 simulator: the "load more" marker in
    ///   view after a scroll, from script or UIKit, and still not
    ///   intersecting), and that is all the mobile site's "load more" waits
    ///   for. This one measures with `getBoundingClientRect` on scroll,
    ///   resize and every 250 ms. It ignores clipping by scrolling
    ///   ancestors, which nothing here depends on.
    static let legacyDocumentStart = """
    (() => {
      if (window.__hypnosDocumentStart) return;
      window.__hypnosDocumentStart = true;

      HTMLMediaElement.prototype.play = function () {
        return Promise.reject(new DOMException(
          'The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.',
          'NotAllowedError'));
      };

      const observers = new Set();
      const parseMargin = (margin) => {
        const parts = String(margin || '0px').trim().split(/\\s+/).map((part) => {
          const match = /^(-?\\d*\\.?\\d+)(px|%)?$/.exec(part);
          return match ? { value: parseFloat(match[1]), percent: match[2] === '%' } : { value: 0, percent: false };
        });
        while (parts.length < 4) parts.push(parts[parts.length === 3 ? 1 : parts.length === 2 ? 0 : 0]);
        return parts;
      };
      const expand = (rect, margin) => {
        const px = (part, size) => part.percent ? size * part.value / 100 : part.value;
        const top = rect.top - px(margin[0], rect.height);
        const right = rect.right + px(margin[1], rect.width);
        const bottom = rect.bottom + px(margin[2], rect.height);
        const left = rect.left - px(margin[3], rect.width);
        return { top, right, bottom, left, width: right - left, height: bottom - top, x: left, y: top };
      };

      class HypnosIntersectionObserver {
        constructor(callback, options = {}) {
          this.callback = callback;
          this.root = options.root || null;
          this.rootMargin = options.rootMargin || '0px';
          this.margin = parseMargin(this.rootMargin);
          const threshold = options.threshold ?? 0;
          this.thresholds = (Array.isArray(threshold) ? threshold : [threshold]).slice().sort((a, b) => a - b);
          this.targets = new Map();
        }
        observe(target) {
          if (!(target instanceof Element) || this.targets.has(target)) return;
          this.targets.set(target, null);
          observers.add(this);
          schedule();
        }
        unobserve(target) {
          this.targets.delete(target);
          if (!this.targets.size) observers.delete(this);
        }
        disconnect() {
          this.targets.clear();
          observers.delete(this);
        }
        takeRecords() { return []; }
        check() {
          const viewport = this.root
            ? this.root.getBoundingClientRect()
            : { top: 0, left: 0, right: innerWidth, bottom: innerHeight, width: innerWidth, height: innerHeight, x: 0, y: 0 };
          const rootBounds = expand(viewport, this.margin);
          const entries = [];
          for (const [target, previous] of this.targets) {
            const box = target.getBoundingClientRect();
            const top = Math.max(box.top, rootBounds.top);
            const left = Math.max(box.left, rootBounds.left);
            const bottom = Math.min(box.bottom, rootBounds.bottom);
            const right = Math.min(box.right, rootBounds.right);
            const isIntersecting = target.isConnected && bottom >= top && right >= left;
            const area = box.width * box.height;
            const ratio = isIntersecting ? (area > 0 ? ((right - left) * (bottom - top)) / area : 1) : 0;
            const state = isIntersecting ? this.thresholds.filter((t) => ratio >= t).length : -1;
            if (state === previous) continue;
            this.targets.set(target, state);
            entries.push({
              time: performance.now(),
              target,
              rootBounds,
              boundingClientRect: box,
              intersectionRect: isIntersecting
                ? { top, left, bottom, right, width: right - left, height: bottom - top, x: left, y: top }
                : { top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0, x: 0, y: 0 },
              isIntersecting,
              intersectionRatio: ratio
            });
          }
          if (entries.length) {
            try { this.callback(entries, this); } catch (error) { setTimeout(() => { throw error; }); }
          }
        }
      }

      let pending = false;
      const schedule = () => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => {
          pending = false;
          for (const observer of observers) observer.check();
        });
      };
      addEventListener('scroll', schedule, true);
      addEventListener('resize', schedule);
      setInterval(() => { if (observers.size) schedule(); }, 250);
      window.IntersectionObserver = HypnosIntersectionObserver;
    })();
    """

    /// Polling transport only: returns and clears what has queued, as JSON
    /// (`[]` when nothing has).
    static let drain = "JSON.stringify((window.__hypnosQueue || []).splice(0))"

    /// Brings the page's "load more" marker into view, which is what makes
    /// the page fetch its next batch. Scrolling the window does nothing: the
    /// page scrolls `body`.
    static let loadMore = """
    (() => {
      const markers = document.querySelectorAll('ytm-continuation-item-renderer');
      const marker = markers[markers.length - 1];
      if (marker) marker.scrollIntoView({ block: 'end' });
      return !!marker;
    })();
    """
}

#endif
