var Action = function() {};

Action.prototype = {

    run: function(params) {
        var seen = {};
        var images = [];

        // Extraction trace, surfaced in the app's log sheet. There is no way to
        // attach a debugger to this script on a device, so it has to report on
        // itself when a page yields fewer images than expected.
        var trace = [];
        function note(text) {
            trace.push(text);
        }

        // origin is "dom" for something the page actually renders, or
        // "source" for a URL only found in the markup text. Feed-style sites
        // keep many unrelated images in their payload, so the UI hides the
        // latter unless asked for.
        function addURL(url, width, height, origin) {
            if (!url) { return; }
            url = String(url).trim();
            if (!url || url.indexOf("data:") === 0) { return; }
            try {
                url = new URL(url, document.baseURI).href;
            } catch (e) {
                return;
            }
            if (seen[url]) { return; }
            seen[url] = true;
            images.push({
                url: url,
                width: width || 0,
                height: height || 0,
                origin: origin || "dom"
            });
        }

        // Picks the highest-resolution candidate. Srcset order is not defined by
        // the spec, so compare the w/x descriptors rather than taking the last.
        function bestFromSrcset(srcset) {
            if (!srcset) { return null; }
            var best = null;
            var bestScore = -1;
            var parts = srcset.split(",");
            for (var i = 0; i < parts.length; i++) {
                var bits = parts[i].trim().split(/\s+/);
                var candidate = bits[0];
                if (!candidate) { continue; }
                var score = 1;
                if (bits[1]) {
                    var n = parseFloat(bits[1]);
                    if (!isNaN(n)) {
                        // "2x" density descriptors are far smaller numbers than
                        // "1600w" width ones; normalise so both rank sensibly.
                        score = /x$/.test(bits[1]) ? n * 1000 : n;
                    }
                }
                if (score > bestScore) {
                    bestScore = score;
                    best = candidate;
                }
            }
            return best;
        }

        var LAZY_ATTRS = [
            "data-src", "data-original", "data-lazy-src", "data-lazy",
            "data-image", "data-url", "data-hi-res-src", "data-large-file"
        ];

        function fromLazyAttrs(el) {
            for (var i = 0; i < LAZY_ATTRS.length; i++) {
                var v = el.getAttribute(LAZY_ATTRS[i]);
                if (v) { return v; }
            }
            return null;
        }

        // --- Element scan, run over the document and any shadow roots / same-origin iframes ---

        function scanRoot(root) {
            var imgEls = root.querySelectorAll("img");
            for (var i = 0; i < imgEls.length; i++) {
                var img = imgEls[i];
                var url = img.currentSrc || img.src
                    || bestFromSrcset(img.getAttribute("srcset"))
                    || bestFromSrcset(img.getAttribute("data-srcset"))
                    || fromLazyAttrs(img);
                addURL(url, img.naturalWidth, img.naturalHeight);
                // The srcset may name a larger file than the one Safari picked
                // for this viewport; offer that too.
                addURL(bestFromSrcset(img.getAttribute("srcset")), 0, 0);
            }

            var sourceEls = root.querySelectorAll("picture source, video source, audio source");
            for (var j = 0; j < sourceEls.length; j++) {
                var src = sourceEls[j];
                addURL(bestFromSrcset(src.getAttribute("srcset")) || src.getAttribute("src"), 0, 0);
            }

            // Video poster frames are often the highest-resolution asset on a
            // streaming page, and they live in an attribute, not an <img>.
            var posterEls = root.querySelectorAll("[poster]");
            for (var p = 0; p < posterEls.length; p++) {
                addURL(posterEls[p].getAttribute("poster"), 0, 0);
            }

            var linkEls = root.querySelectorAll(
                "link[rel~='preload'][as='image'], link[rel~='image_src'], link[rel~='apple-touch-icon']"
            );
            for (var l = 0; l < linkEls.length; l++) {
                addURL(linkEls[l].getAttribute("href"), 0, 0);
                addURL(bestFromSrcset(linkEls[l].getAttribute("imagesrcset")), 0, 0);
            }

            // og:image / twitter:image are usually the page's key visual at a
            // higher resolution than anything laid out on screen.
            var metaEls = root.querySelectorAll(
                "meta[property='og:image'], meta[property='og:image:url'], "
                + "meta[property='og:image:secure_url'], meta[name='twitter:image'], "
                + "meta[name='twitter:image:src'], meta[itemprop='image']"
            );
            for (var mt = 0; mt < metaEls.length; mt++) {
                addURL(metaEls[mt].getAttribute("content"), 0, 0);
            }

            var svgUse = root.querySelectorAll("image");
            for (var u = 0; u < svgUse.length; u++) {
                addURL(svgUse[u].getAttribute("href") || svgUse[u].getAttribute("xlink:href"), 0, 0);
            }

            var allEls = root.querySelectorAll("*");
            var bgScanLimit = Math.min(allEls.length, 4000);
            for (var k = 0; k < bgScanLimit; k++) {
                var el = allEls[k];

                if (el.shadowRoot) {
                    try { scanRoot(el.shadowRoot); } catch (e) {}
                }

                var style;
                try {
                    style = getComputedStyle(el);
                } catch (e) {
                    continue;
                }
                var bg = style && style.backgroundImage;
                if (bg && bg.indexOf("url(") !== -1) {
                    var re = /url\(["']?([^"')]+)["']?\)/g;
                    var m;
                    while ((m = re.exec(bg)) !== null) {
                        addURL(m[1], 0, 0);
                    }
                }
            }
        }

        function collectRendered() {
            try { scanRoot(document); } catch (e) {}

            var frames = document.querySelectorAll("iframe, frame");
            for (var f = 0; f < frames.length; f++) {
                try {
                    var doc = frames[f].contentDocument;
                    if (doc) { scanRoot(doc); }
                } catch (e) {
                    // Cross-origin frame: nothing readable, skip.
                }
            }
        }

        collectRendered();
        note("URL: " + document.URL);
        note("img要素 " + document.querySelectorAll("img").length
             + "個 / 初回スキャン " + images.length + "件");

        function collectSource() {
            // --- Raw-source scan ---
            // Single-page apps (Next.js, Nuxt) ship their image URLs inside inline
            // JSON and only turn some of them into elements. Sweeping the markup
            // text finds the full-resolution originals the DOM never references.

            try {
                // Built from a backslash constant rather than written inline: the
                // patterns below are dense with escapes and easy to corrupt.
                var BS = String.fromCharCode(92);

                // Inline JSON escapes its slashes; undo both spellings.
                var html = document.documentElement.innerHTML
                    .split(BS + "u002F").join("/")
                    .split(BS + "u002f").join("/")
                    .split(BS + "/").join("/");

                // Characters a URL cannot contain: whitespace, the three quote
                // styles, brackets and braces.
                var QUOTES = String.fromCharCode(34) + String.fromCharCode(39) + String.fromCharCode(96);
                var CLASS = "[^" + BS + "s" + QUOTES + "<>{}" + BS + "[" + BS + "]]";
                var IMAGE_URL = new RegExp(
                    "https?://" + CLASS + "+?" + BS + ".(?:jpe?g|png|gif|webp|heic|heif|bmp|svg|avif)" +
                    "(?:" + BS + "?" + CLASS + "*)?", "gi");

                var hit;
                var found = 0;
                var beforeSource = images.length;
                while ((hit = IMAGE_URL.exec(html)) !== null && found < 800) {
                    addURL(hit[0], 0, 0, "source");
                    found++;
                }
                note("ソース走査: HTML " + html.length + "文字 / 一致 " + found
                     + "件 / 新規 " + (images.length - beforeSource) + "件");
            } catch (e) {
                note("[ERR] ソース走査に失敗: " + e);
            }

        }

        // --- Carousel advance ---
        // Instagram and similar galleries keep only the visible slide and its
        // immediate neighbours in the DOM, and fetch the rest over the network
        // as you swipe -- they exist nowhere in the markup to be scraped. The
        // preprocessing script may finish asynchronously, so step the carousel
        // forward and let the page load them.

        var finished = false;

        function finish() {
            if (finished) { return; }
            finished = true;
            collectRendered();
            collectSource();
            note("合計 " + images.length + "件");
            params.completionFunction({
                "images": images,
                "pageTitle": document.title || "",
                "pageURL": document.URL || "",
                "trace": trace
            });
        }

        var NEXT_LABEL = /^(next|次へ|次の.{0,6})$/i;

        function findNextControl() {
            var candidates = document.querySelectorAll("[aria-label]");
            var rejected = [];
            for (var i = 0; i < candidates.length; i++) {
                var el = candidates[i];
                var label = (el.getAttribute("aria-label") || "").trim();
                if (!NEXT_LABEL.test(label)) { continue; }
                var role = (el.getAttribute("role") || "").toLowerCase();
                if (el.tagName !== "BUTTON" && role !== "button") {
                    rejected.push(label + "(" + el.tagName + "/role=" + (role || "なし") + ")");
                    continue;
                }
                // Never click a link: "next" on an article or a paginated list
                // navigates away, which would abandon the extraction entirely.
                if (el.tagName === "A" || el.closest("a")) {
                    rejected.push(label + "(リンク内)");
                    continue;
                }
                // offsetParent is null for anything hidden or detached.
                if (!el.offsetParent) {
                    rejected.push(label + "(非表示)");
                    continue;
                }
                return el;
            }
            if (rejected.length) {
                note("「次へ」候補を除外: " + rejected.slice(0, 5).join(", "));
            }
            return null;
        }

        /// Dumps what the page does expose, for when no control matched at all.
        function noteAvailableControls() {
            var labels = [];
            var els = document.querySelectorAll("button, [role='button'], [aria-label]");
            for (var i = 0; i < els.length && labels.length < 25; i++) {
                var el = els[i];
                var label = (el.getAttribute("aria-label") || el.textContent || "").trim();
                if (!label || label.length > 24) { continue; }
                if (labels.indexOf(label) === -1) { labels.push(label); }
            }
            note("ボタン候補 " + els.length + "個: "
                 + (labels.length ? labels.join(" / ") : "ラベルなし"));
        }

        // Kept short: the share sheet is blocked on this script, and WebKit
        // will not let it run indefinitely.
        var MAX_STEPS = 20;
        var STEP_DELAY = 400;
        var deadline = Date.now() + 6500;
        // Compared without the query string: galleries commonly push the
        // slide number into it (Instagram uses ?img_index=N), which is not a
        // navigation and must not abort the walk.
        function pageIdentity() {
            return document.location.origin + document.location.pathname;
        }
        var startIdentity = pageIdentity();
        var steps = 0;
        var idleSteps = 0;

        function step() {
            if (finished) { return; }
            if (steps >= MAX_STEPS || Date.now() > deadline) {
                note("上限に達したため終了 (" + steps + "回送り)");
                finish();
                return;
            }
            var control = findNextControl();
            if (!control) {
                if (steps === 0) {
                    note("「次へ」ボタンが見つからず、カルーセル送りは未実行");
                    noteAvailableControls();
                } else {
                    note("「次へ」ボタンが消えたため終了 (" + steps + "回送り)");
                }
                finish();
                return;
            }

            var before = images.length;
            try {
                control.click();
            } catch (e) {
                finish();
                return;
            }
            steps++;

            setTimeout(function() {
                if (finished) { return; }
                // A click that navigated is a misidentified control; take what
                // was gathered before the page changed under us.
                if (pageIdentity() !== startIdentity) {
                    note("[ERR] クリックでページが遷移したため中断: " + pageIdentity());
                    finish();
                    return;
                }
                collectRendered();
                note("送り" + steps + "回目: +" + (images.length - before) + "件");
                // Two dead steps in a row means the gallery has wrapped around
                // or stopped producing anything new.
                idleSteps = (images.length === before) ? idleSteps + 1 : 0;
                if (idleSteps >= 2) {
                    note("新規が増えなくなったため終了");
                    finish();
                } else {
                    step();
                }
            }, STEP_DELAY);
        }

        // Backstop: the extension would hang forever if completionFunction
        // never ran, so guarantee it does.
        setTimeout(finish, 7500);
        step();
    },

    finalize: function(params) {}
};

var ExtensionPreprocessingJS = new Action();
