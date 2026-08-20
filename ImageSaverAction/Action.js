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

        /// An <img> the page has created but not yet pointed at a file. A
        /// slide caught in this state is invisible to the scan.
        function countSourcelessImages() {
            var imgs = document.querySelectorAll("img");
            var count = 0;
            for (var i = 0; i < imgs.length; i++) {
                if (!imgs[i].currentSrc && !imgs[i].src) { count++; }
            }
            return count;
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
        var settling = false;
        // Distinct from `finished`, which is set on entry to block re-entrant
        // timers. This one records that the host actually received something,
        // so a failure part-way through finish() can still be recovered from.
        var handedOff = false;

        function handOff() {
            if (handedOff) { return; }
            handedOff = true;
            params.completionFunction({
                "images": images,
                "pageTitle": document.title || "",
                "pageURL": document.URL || "",
                "trace": trace
            });
        }

        /// Ends the walk, but only after giving images requested by the last
        /// step time to arrive. Without this the final slide is regularly lost:
        /// the click lands, the gallery reports no more slides, and the run
        /// ends while its image is still in flight.
        function finishAfterSettle(reason) {
            if (finished || settling) { return; }
            settling = true;
            note(reason);
            setTimeout(function() {
                var before = images.length;
                collectRendered();
                note("最終待機: +" + (images.length - before) + "件");
                finish();
            }, SETTLE_DELAY);
        }

        function finish() {
            if (finished) { return; }
            finished = true;
            collectRendered();
            collectSource();
            note("最終DOM: img " + document.querySelectorAll("img").length
                 + "個 / video " + document.querySelectorAll("video").length
                 + "個 / srcなしimg " + countSourcelessImages() + "個");
            note("合計 " + images.length + "件 / 所要 "
                 + (Date.now() - startedAt) + "ms");
            handOff();
        }

        var NEXT_LABEL = /^(next|次へ|次の.{0,6})$/i;
        var PREV_LABEL = /^(prev|previous|back|前へ|戻る|前の.{0,6})$/i;

        function findNextControl() { return findControl(NEXT_LABEL, null); }

        function findPrevControl() {
            if (!galleryScope) {
                galleryScope = inferScopeFromLargestImage();
                if (galleryScope && !scopeReported) {
                    scopeReported = true;
                    note("送りボタン未検出のため、最大画像の親要素を探索範囲にする ("
                         + galleryScope.tagName + ")");
                }
            }
            if (!galleryScope) {
                if (!scopeReported) {
                    scopeReported = true;
                    note("探索範囲を特定できないため、戻り方向は実行しない");
                }
                return null;
            }
            return findControl(PREV_LABEL, galleryScope);
        }

        function findControl(pattern, scope) {
            var candidates = (scope || document).querySelectorAll("[aria-label]");
            var rejected = [];
            for (var i = 0; i < candidates.length; i++) {
                var el = candidates[i];
                var label = (el.getAttribute("aria-label") || "").trim();
                if (!pattern.test(label)) { continue; }
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
                note("送りボタン候補を除外: " + rejected.slice(0, 5).join(", "));
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

        // Overrunning does not truncate the result -- it discards it, and
        // loadItem hands the extension nil. Earlier budgets of 6.5s looked safe
        // only because runs finished in ~1.4s and never spent them; the failures
        // began exactly when added delays made the walk genuinely long. Keep
        // total runtime near what has actually been observed to work.
        var MAX_STEPS = 25;
        var POLL_INTERVAL = 100;
        var MAX_STEP_WAIT = 500;
        var SETTLE_DELAY = 300;
        // A slow slide should not end the walk: the control disappearing is the
        // reliable signal, so tolerate a few empty steps before giving up.
        var MAX_IDLE_STEPS = 3;
        // React galleries unmount their controls while the slide transitions,
        // so a missing button means "mid-transition" as often as "end of
        // gallery". Re-check before believing it, and leave a gap between
        // clicks so the next one is not swallowed by the animation.
        var MAX_MISSING_CHECKS = 3;
        var MISSING_RECHECK_DELAY = 150;
        var MIN_STEP_GAP = 120;
        var startedAt = Date.now();
        var deadline = startedAt + 1800;

        // Compared without the query string: galleries commonly push the
        // slide number into it (Instagram uses ?img_index=N), which is not a
        // navigation and must not abort the walk.
        function pageIdentity() {
            return document.location.origin + document.location.pathname;
        }
        var startIdentity = pageIdentity();

        // Sharing from the middle of a gallery is normal, so walk forward to
        // the end and then back to the start. Going back re-visits slides that
        // are already collected, so that pass must not stop when nothing new
        // turns up -- only when the control itself disappears.
        var PASSES = [
            { label: "次へ", find: findNextControl, stopWhenIdle: true },
            { label: "前へ", find: findPrevControl, stopWhenIdle: false }
        ];
        var passIndex = 0;
        var steps = 0;
        var idleSteps = 0;
        var missingChecks = 0;

        // Where the gallery's own controls live. The backward pass is confined
        // to it: a page's "back" control is navigation, and clicking that
        // destroys this script along with the page, while the same label inside
        // the gallery is the slide arrow.
        var galleryScope = null;
        var scopeReported = false;

        function containerOf(element) {
            var container = element.closest("article, [role='dialog'], main, section");
            if (container) { return container; }
            var node = element;
            for (var up = 0; up < 6 && node.parentElement; up++) {
                node = node.parentElement;
            }
            return node;
        }

        function rememberScope(control) {
            galleryScope = containerOf(control);
        }

        /// Derives the scope from the artwork instead of the arrows. Sharing
        /// from the last slide means the forward control never appears, and
        /// keying off it left the backward pass with nowhere to look -- exactly
        /// the case the backward pass exists for.
        function inferScopeFromLargestImage() {
            var imgs = document.querySelectorAll("img");
            var best = null;
            var bestArea = 0;
            for (var i = 0; i < imgs.length; i++) {
                var rect = imgs[i].getBoundingClientRect();
                var area = rect.width * rect.height;
                if (area > bestArea) {
                    bestArea = area;
                    best = imgs[i];
                }
            }
            return best ? containerOf(best) : null;
        }

        function endPass(reason) {
            passIndex++;
            if (passIndex < PASSES.length) {
                note(reason + " / " + PASSES[passIndex].label + "へ");
                steps = 0;
                idleSteps = 0;
                missingChecks = 0;
                step();
            } else {
                finishAfterSettle(reason);
            }
        }

        function step() {
            if (finished) { return; }
            var pass = PASSES[passIndex];
            try {
                stepInner(pass);
            } catch (e) {
                note("[ERR] カルーセル送りで例外: " + e);
                finish();
            }
        }

        function stepInner(pass) {
            if (steps >= MAX_STEPS || Date.now() > deadline) {
                endPass("上限に達したため" + pass.label + "終了 (" + steps + "回)");
                return;
            }

            var control = pass.find();
            if (!control) {
                if (missingChecks < MAX_MISSING_CHECKS && Date.now() < deadline) {
                    missingChecks++;
                    setTimeout(step, MISSING_RECHECK_DELAY);
                    return;
                }
                if (steps === 0 && passIndex === 0) {
                    note("「次へ」ボタンが見つからず、カルーセル送りは未実行");
                    noteAvailableControls();
                }
                endPass("「" + pass.label + "」ボタンが "
                        + (missingChecks * MISSING_RECHECK_DELAY)
                        + "ms 待っても現れないため終了 (" + steps + "回送り)");
                return;
            }
            missingChecks = 0;

            var before = images.length;
            try {
                control.click();
            } catch (e) {
                finish();
                return;
            }
            steps++;
            if (passIndex === 0) { rememberScope(control); }
            awaitSlide(pass, before, 0);
        }

        /// Polls until the clicked slide's image shows up, rather than
        /// guessing a fixed load time.
        function awaitSlide(pass, before, waited) {
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
                waited += POLL_INTERVAL;

                if (images.length === before && waited < MAX_STEP_WAIT
                    && Date.now() < deadline) {
                    awaitSlide(pass, before, waited);
                    return;
                }

                note(pass.label + steps + "回目: +" + (images.length - before)
                     + "件 (" + waited + "ms)");

                if (!pass.stopWhenIdle) {
                    setTimeout(step, MIN_STEP_GAP);
                    return;
                }
                // Consecutive dead steps mean the gallery has wrapped around
                // or stopped producing anything new.
                idleSteps = (images.length === before) ? idleSteps + 1 : 0;
                if (idleSteps >= MAX_IDLE_STEPS) {
                    endPass("新規が" + MAX_IDLE_STEPS + "回増えなかったため終了");
                } else {
                    setTimeout(step, MIN_STEP_GAP);
                }
            }, POLL_INTERVAL);
        }

        // Clicking through a page is only worth its risk where the gallery is
        // known to hide its slides from the DOM. Everywhere else this finishes
        // synchronously, which also removes any chance of the result being
        // discarded for running too long.
        var CAROUSEL_HOSTS = ["instagram.com"];

        function hostWalksCarousels() {
            var host = (document.location.hostname || "").toLowerCase();
            for (var i = 0; i < CAROUSEL_HOSTS.length; i++) {
                var allowed = CAROUSEL_HOSTS[i];
                if (host === allowed || host.slice(-(allowed.length + 1)) === "." + allowed) {
                    return true;
                }
            }
            return false;
        }

        // Anything escaping here would leave the host with no result at all,
        // which is indistinguishable from the script never having run.
        try {
            collectRendered();
            note("URL: " + document.URL);
            note("img要素 " + document.querySelectorAll("img").length
                 + "個 / 初回スキャン " + images.length + "件");

            if (!hostWalksCarousels()) {
                note("カルーセル送りの対象サイトではないため実行しない ("
                     + document.location.hostname + ")");
                finish();
            } else {
                // Backstop: the extension would hang forever if
                // completionFunction never ran, so guarantee it does.
                setTimeout(finish, 2500);
                step();
            }
        } catch (e) {
            try { note("[ERR] 抽出スクリプトで例外: " + e); } catch (ignored) {}
            handOff();
        }
    },

    finalize: function(params) {}
};

var ExtensionPreprocessingJS = new Action();
