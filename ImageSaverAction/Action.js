var Action = function() {};

Action.prototype = {

    run: function(params) {
        var seen = {};
        var images = [];
        var startedAt = Date.now();

        // Discovery order is not page order. Walking a carousel backwards finds
        // slide 8, then 7, then 6 -- so each image carries a sort key, and the
        // backward pass numbers its finds below everything already seen.
        var forwardOrder = 0;
        var backwardBlock = 0;
        var backwardWithinBlock = 0;

        function nextOrder() {
            if (backwardBlock === 0) { return forwardOrder++; }
            return -(backwardBlock * 1000) + (backwardWithinBlock++);
        }

        // Nothing on the device can attach a debugger to this script, so it
        // reports on itself.
        var trace = [];
        function note(text) {
            trace.push(text);
        }

        // origin is "dom" for something the page actually renders, or
        // "source" for a URL only found in the markup text. Feed-style sites
        // keep many unrelated images in their payload, so the UI hides the
        // latter unless asked for.
        // Interface artwork -- spinners, play buttons, placeholders -- served
        // from a host's static-resource path. Content never comes from these,
        // and the files are ordinary PNGs of ordinary size, so nothing else
        // distinguishes them from a picture.
        var UI_ASSET_PATH = /\/rsrc\.php\/|static\.cdninstagram\.com|\/static\.xx\.fbcdn\.net\//i;
        var uiAssetsSkipped = 0;

        // A picture wrapped in a link to some other post belongs to that post,
        // not to this page. Instagram fills the space under a post with them,
        // and they arrive from the same CDN under the same naming as the
        // slides, so nothing about the URL or the size tells them apart --
        // only what they are nested inside. Tagged "other" and hidden unless
        // asked for, because the test is structural and the page could always
        // wrap its own artwork in a link too.

        // A post is reachable at two paths -- /p/<code>/ and, when you arrive
        // from the author's profile, /<user>/p/<code>/ -- so the shortcode is
        // the only thing that identifies it. Comparing leading path segments
        // instead made every post by this author look like the current one.
        var POST_PATH = /(?:^|\/)(?:p|reel|reels|tv)\/([^\/?#]+)/i;

        /// What page a path names. Two paths for the same post agree; anything
        /// below it (/p/<code>/media) agrees too.
        function pageKey(pathname) {
            var post = POST_PATH.exec(String(pathname || ""));
            if (post) { return "post:" + post[1]; }
            var parts = String(pathname || "").split("/");
            var key = "path:";
            var kept = 0;
            for (var i = 0; i < parts.length && kept < 2; i++) {
                if (!parts[i]) { continue; }
                key += "/" + parts[i];
                kept++;
            }
            return key;
        }

        var thisPageKey = pageKey(document.location.pathname);

        /// Only a post's own page has a subject to protect. A profile page is
        /// nothing but thumbnails linking to posts, and the feed is the same,
        /// so there the test would empty the grid instead of tidying it.
        function onPostPermalink() {
            return POST_PATH.test(document.location.pathname);
        }

        /// Confined to the carousel sites: elsewhere a thumbnail that links to
        /// its own page is ordinary gallery markup and wanted.
        function linksElsewhere(el) {
            if (!hostWalksCarousels() || !onPostPermalink()) { return false; }
            var link;
            try { link = el.closest("a[href]"); } catch (e) { return false; }
            if (!link || !link.href) { return false; }
            var target;
            try { target = new URL(link.href, document.baseURI); } catch (e) { return false; }
            if (target.origin !== document.location.origin) { return true; }
            return pageKey(target.pathname) !== thisPageKey;
        }

        function addURL(url, width, height, origin) {
            if (!url) { return; }
            url = String(url).trim();
            if (!url || url.indexOf("data:") === 0) { return; }
            try {
                url = new URL(url, document.baseURI).href;
            } catch (e) {
                return;
            }
            if (UI_ASSET_PATH.test(url)) {
                uiAssetsSkipped++;
                return;
            }
            if (seen[url]) { return; }
            seen[url] = true;
            images.push({
                url: url,
                width: width || 0,
                height: height || 0,
                origin: origin || "dom",
                order: nextOrder()
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

        // Anything drawn in a box smaller than this is an icon, whatever the
        // size of the file behind it.
        var SPRITE_MIN_BOX = 60;
        var spritesSkipped = 0;

        // Which sweep produced each image. Two rounds of guessing went into
        // finding out where unwanted pictures were entering from, so the
        // script now says so outright.
        var bySource = {};

        function credit(label, mark) {
            var added = images.length - mark;
            if (added > 0) { bySource[label] = (bySource[label] || 0) + added; }
        }

        // --- Element scan, run over the document and any shadow roots / same-origin iframes ---

        // `withBackgrounds` drives the expensive part: a getComputedStyle call
        // per element, thousands of them. Advancing a slide never introduces a
        // new CSS background, so the walk skips it and only the first and last
        // sweeps pay for it.
        function scanRoot(root, withBackgrounds) {
            // Before the <img> sweep: the first origin recorded for a URL wins,
            // and a video slide's thumbnail has to be recognised as one rather
            // than counted as a photograph.
            var mark = images.length;

            var videoEls = root.querySelectorAll("video");
            for (var v = 0; v < videoEls.length; v++) {
                var video = videoEls[v];
                addURL(video.getAttribute("poster"), 0, 0, "video");

                // Players commonly lay the thumbnail over the video as a plain
                // <img> rather than using the poster attribute.
                var container = video.parentElement;
                if (container) {
                    var covers = container.querySelectorAll("img");
                    for (var c = 0; c < covers.length; c++) {
                        addURL(covers[c].currentSrc || covers[c].src, 0, 0, "video");
                    }
                }
            }

            credit("動画", mark);
            mark = images.length;

            var imgEls = root.querySelectorAll("img");
            for (var i = 0; i < imgEls.length; i++) {
                var img = imgEls[i];
                var url = img.currentSrc || img.src
                    || bestFromSrcset(img.getAttribute("srcset"))
                    || bestFromSrcset(img.getAttribute("data-srcset"))
                    || fromLazyAttrs(img);
                var imgOrigin = linksElsewhere(img) ? "other" : "dom";
                addURL(url, img.naturalWidth, img.naturalHeight, imgOrigin);
                // The srcset may name a larger file than the one Safari picked
                // for this viewport; offer that too.
                addURL(bestFromSrcset(img.getAttribute("srcset")), 0, 0, imgOrigin);
            }

            credit("img", mark);
            mark = images.length;

            var sourceEls = root.querySelectorAll("picture source, video source, audio source");
            for (var j = 0; j < sourceEls.length; j++) {
                var src = sourceEls[j];
                addURL(bestFromSrcset(src.getAttribute("srcset")) || src.getAttribute("src"), 0, 0);
            }

            credit("source", mark);
            mark = images.length;

            var posterEls = root.querySelectorAll("[poster]");
            for (var p = 0; p < posterEls.length; p++) {
                addURL(posterEls[p].getAttribute("poster"), 0, 0, "video");
            }

            credit("poster", mark);
            mark = images.length;

            var linkEls = root.querySelectorAll(
                "link[rel~='preload'][as='image'], link[rel~='image_src'], link[rel~='apple-touch-icon']"
            );
            // Declared in the head, not laid out on the page. A preload for
            // an image the page really shows has already been claimed by the
            // <img> sweep above, so what is left here is what the page intends
            // to display next -- on Instagram, the thumbnails for a screen the
            // user has not opened. Given the standing of og:image there:
            // named by the markup, not shown by it, hidden unless asked for.
            //
            // Only there, though. Elsewhere the leftover preload is the page's
            // own hero art at full resolution, which is precisely what a
            // single-page app like Lemino keeps out of the DOM and precisely
            // why these links are scanned at all.
            var linkOrigin = hostWalksCarousels() ? "meta" : "dom";
            for (var l = 0; l < linkEls.length; l++) {
                addURL(linkEls[l].getAttribute("href"), 0, 0, linkOrigin);
                addURL(bestFromSrcset(linkEls[l].getAttribute("imagesrcset")), 0, 0, linkOrigin);
            }

            // og:image / twitter:image are the page's key visual, often at a
            // higher resolution than anything laid out on screen -- but a
            // single-page app does not rewrite them as you navigate, so what
            // they name can belong to a different page entirely. Tagged, and
            // hidden unless asked for. This runs after the <img> sweep, so a
            // URL the page really shows keeps its own origin and only the
            // orphan is marked.
            var metaEls = root.querySelectorAll(
                "meta[property='og:image'], meta[property='og:image:url'], "
                + "meta[property='og:image:secure_url'], meta[name='twitter:image'], "
                + "meta[name='twitter:image:src'], meta[itemprop='image']"
            );
            for (var mt = 0; mt < metaEls.length; mt++) {
                addURL(metaEls[mt].getAttribute("content"), 0, 0, "meta");
            }

            credit("link/meta", mark);
            mark = images.length;

            var svgUse = root.querySelectorAll("image");
            for (var u = 0; u < svgUse.length; u++) {
                addURL(svgUse[u].getAttribute("href") || svgUse[u].getAttribute("xlink:href"), 0, 0);
            }

            credit("svg", mark);

            if (!withBackgrounds) { return; }

            mark = images.length;
            var allEls = root.querySelectorAll("*");
            var bgScanLimit = Math.min(allEls.length, 4000);
            for (var k = 0; k < bgScanLimit; k++) {
                var el = allEls[k];

                if (el.shadowRoot) {
                    try { scanRoot(el.shadowRoot, withBackgrounds); } catch (e) {}
                }

                var style;
                try {
                    style = getComputedStyle(el);
                } catch (e) {
                    continue;
                }
                var bg = style && style.backgroundImage;
                if (bg && bg.indexOf("url(") !== -1) {
                    // A sprite sheet is one large file shown through an
                    // icon-sized window, so the element's own box gives it
                    // away. Instagram's carousel arrows use one, and it lands
                    // in the grid as a collage of unrelated icons that no size
                    // threshold can separate from a photograph.
                    var rect = el.getBoundingClientRect();
                    if (rect.width < SPRITE_MIN_BOX && rect.height < SPRITE_MIN_BOX) {
                        spritesSkipped++;
                        continue;
                    }
                    var re = /url\(["']?([^"')]+)["']?\)/g;
                    var m;
                    while ((m = re.exec(bg)) !== null) {
                        addURL(m[1], 0, 0);
                    }
                }
            }

            credit("CSS背景", mark);
        }

        /// Names the files that made it into the grid, so anything unwanted
        /// that survives the filters can be identified from the log alone.
        function noteRenderedFilenames() {
            var names = [];
            var seenNames = {};
            for (var i = 0; i < images.length && names.length < 12; i++) {
                if (images[i].origin !== "dom") { continue; }
                var path = images[i].url.split("?")[0].split("/");
                var name = path.pop();
                if (name.length < 12 || seenNames[name]) { continue; }
                seenNames[name] = true;
                // Instagram's CDN sorts by directory -- t51.2885-19 is a
                // profile picture, t51.2885-15 a post's own media -- so the
                // folder identifies a stray that the filename alone cannot.
                var folder = path.pop() || "";
                names.push(folder + "/" + (name.length > 30 ? name.slice(0, 30) + "…" : name));
            }
            if (names.length) {
                note("ページ内のファイル名(" + names.length + "種): " + names.join(" / "));
            }
        }

        function collectRendered(withBackgrounds) {
            try { scanRoot(document, withBackgrounds); } catch (e) {}

            var frames = document.querySelectorAll("iframe, frame");
            for (var f = 0; f < frames.length; f++) {
                try {
                    var doc = frames[f].contentDocument;
                    if (doc) { scanRoot(doc, withBackgrounds); }
                } catch (e) {
                    // Cross-origin frame: nothing readable, skip.
                }
            }
        }

        // --- Raw-source scan ---
        // Single-page apps ship image URLs inside inline JSON and only turn
        // some of them into elements. Sweeping the markup text finds the
        // full-resolution originals the DOM never references.
        function collectSource() {
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
                note("ソース走査: 一致 " + found + "件 / 新規 "
                     + (images.length - beforeSource) + "件");
            } catch (e) {
                note("[ERR] ソース走査に失敗: " + e);
            }
        }

        // --- Carousel advance -------------------------------------------
        //
        // Instagram keeps only the visible slide and its neighbours in the DOM
        // and the rest is nowhere in the page source, so the slides can only be
        // reached by clicking through. An earlier attempt at this returned
        // nothing at all in half of all runs: the walk has to finish
        // asynchronously, and Safari can freeze the page's timers once the
        // share sheet covers it, so completionFunction never ran.
        //
        // What makes it affordable now is that the image itself is not needed
        // -- only its URL, which React puts in the DOM as soon as it renders
        // the slide. Waiting a frame or two instead of for a download cuts the
        // asynchronous window from ~1.9s to well under one second.

        var STEP_WAIT = 90;
        var MAX_STEPS = 14;
        var BUDGET = 900;
        var BACKSTOP = 1200;
        var NEXT_LABEL = /^(next|次へ|次の.{0,6})$/i;
        var PREV_LABEL = /^(prev|previous|back|前へ|戻る|前の.{0,6})$/i;

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

        function startingSlideIndex() {
            var match = /[?&]img_index=(\d+)/.exec(document.URL);
            return match ? parseInt(match[1], 10) : 1;
        }

        function startingSlide() {
            var match = /[?&]img_index=(\d+)/.exec(document.URL);
            return match ? match[1] + "枚目" : "不明 (1枚目とみなす)";
        }

        // Where the gallery's own controls live. The backward pass is confined
        // to it: a page's "back" control is navigation, and clicking that
        // destroys this script along with the page, while the same label inside
        // the gallery is the slide arrow.
        var galleryScope = null;

        function containerOf(element) {
            var container = element.closest("article, [role='dialog'], main, section");
            if (container) { return container; }
            var node = element;
            for (var up = 0; up < 6 && node.parentElement; up++) {
                node = node.parentElement;
            }
            return node;
        }

        /// Derived from the artwork rather than the arrows: sharing from the
        /// last slide means the forward control never appears, which is exactly
        /// when the backward pass is needed.
        function inferScope() {
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

        function findPrevControl() {
            if (!galleryScope) { galleryScope = inferScope(); }
            if (!galleryScope) { return null; }
            return findControl(PREV_LABEL, galleryScope);
        }

        function findNextControl() {
            var control = findControl(NEXT_LABEL, null);
            if (control && !galleryScope) { galleryScope = containerOf(control); }
            return control;
        }

        function findControl(pattern, scope) {
            var candidates = (scope || document).querySelectorAll("[aria-label]");
            for (var i = 0; i < candidates.length; i++) {
                var el = candidates[i];
                if (!pattern.test((el.getAttribute("aria-label") || "").trim())) { continue; }
                var role = (el.getAttribute("role") || "").toLowerCase();
                if (el.tagName !== "BUTTON" && role !== "button") { continue; }
                // Never click a link: "next" on a paginated page navigates away,
                // which would abandon the extraction entirely.
                if (el.tagName === "A" || el.closest("a")) { continue; }
                if (!el.offsetParent) { continue; }
                return el;
            }
            return null;
        }

        // Compared without the query string: the slide number lives there
        // (?img_index=N) and changing it is not a navigation.
        function pageIdentity() {
            return document.location.origin + document.location.pathname;
        }

        var startIdentity = pageIdentity();
        var handedOff = false;
        var steps = 0;

        // Forward first, then back only when something is actually out of
        // reach. From slide 1 or 2 nothing earlier exists, and the DOM already
        // holds the previous neighbour, so the second pass is pure cost.
        var PASSES = [
            { label: "次へ", find: findNextControl },
            { label: "前へ", find: findPrevControl }
        ];
        var passIndex = 0;
        var needsBackwardPass = startingSlideIndex() >= 3;

        function endPass(reason) {
            passIndex++;
            if (passIndex < PASSES.length && needsBackwardPass) {
                note(reason + " / " + PASSES[passIndex].label + "へ");
                steps = 0;
                backwardBlock = 1;
                backwardWithinBlock = 0;
                step();
            } else {
                handOff(reason);
            }
        }

        function handOff(reason) {
            if (handedOff) { return; }
            handedOff = true;
            collectRendered(true);
            if (reason) { note(reason); }
            collectSource();
            var metaImages = 0;
            for (var mi = 0; mi < images.length; mi++) {
                if (images[mi].origin === "meta") { metaImages++; }
            }
            if (metaImages > 0) {
                note("OGP画像: " + metaImages + "件");
            }

            var videoThumbs = 0;
            for (var vt = 0; vt < images.length; vt++) {
                if (images[vt].origin === "video") { videoThumbs++; }
            }
            if (videoThumbs > 0) {
                note("動画サムネイル: " + videoThumbs + "件");
            }
            if (spritesSkipped > 0) {
                note("アイコン枠の背景画像を除外: " + spritesSkipped + "件");
            }
            if (uiAssetsSkipped > 0) {
                note("UI部品の画像を除外: " + uiAssetsSkipped + "件");
            }

            var otherPosts = 0;
            for (var op = 0; op < images.length; op++) {
                if (images[op].origin === "other") { otherPosts++; }
            }
            if (hostWalksCarousels()) {
                note("別の投稿へのリンク内の画像: "
                     + (onPostPermalink() ? otherPosts + "件"
                                          : "判定なし (投稿ページではないため)"));
            }
            var breakdown = [];
            for (var key in bySource) {
                if (Object.prototype.hasOwnProperty.call(bySource, key)) {
                    breakdown.push(key + " " + bySource[key]);
                }
            }
            if (breakdown.length) {
                note("取得元の内訳: " + breakdown.join(" / "));
            }
            noteRenderedFilenames();
            note("合計 " + images.length + "件 / 所要 " + (Date.now() - startedAt) + "ms");

            images.sort(function(a, b) { return a.order - b.order; });

            params.completionFunction({
                "images": images,
                "pageTitle": document.title || "",
                "pageURL": document.URL || "",
                "trace": trace
            });
        }

        function step() {
            if (handedOff) { return; }
            if (steps >= MAX_STEPS || Date.now() - startedAt > BUDGET) {
                handOff("上限に達したため終了 (" + PASSES[passIndex].label + " "
                        + steps + "回送り)");
                return;
            }

            var pass = PASSES[passIndex];
            var control = pass.find();
            if (!control) {
                endPass(steps === 0
                        ? "「" + pass.label + "」ボタンが無いため送りは未実行"
                        : "「" + pass.label + "」ボタンが消えたため終了 ("
                          + steps + "回送り)");
                return;
            }

            var before = images.length;
            try {
                control.click();
            } catch (e) {
                handOff("[ERR] クリックに失敗: " + e);
                return;
            }
            steps++;
            if (backwardBlock !== 0) {
                // Each step back reaches an earlier slide, so it sorts ahead of
                // the step before it.
                backwardBlock = steps;
                backwardWithinBlock = 0;
            }

            setTimeout(function() {
                if (handedOff) { return; }
                if (pageIdentity() !== startIdentity) {
                    handOff("[ERR] クリックでページが遷移したため中断");
                    return;
                }
                collectRendered(false);
                note(pass.label + steps + "回目: +" + (images.length - before) + "件");
                step();
            }, STEP_WAIT);
        }

        // Anything escaping here would leave the host with no result at all,
        // which is indistinguishable from the script never having run.
        try {
            collectRendered(true);
            note("URL: " + document.URL);
            note("開始スライド: " + startingSlide());
            note("img要素 " + document.querySelectorAll("img").length
                 + "個 / 初回スキャン " + images.length + "件");
            note("戻り方向: " + (needsBackwardPass
                                 ? "実行する (3枚目以降から共有)"
                                 : "不要 (前のスライドは無いか既に取得済み)"));

            if (!hostWalksCarousels()) {
                handOff("カルーセル送りの対象サイトではないため実行しない");
            } else {
                setTimeout(function() { handOff("時間切れ"); }, BACKSTOP);
                step();
            }
        } catch (e) {
            try { note("[ERR] 抽出スクリプトで例外: " + e); } catch (ignored) {}
            handOff(null);
        }
    },

    finalize: function(params) {}
};

var ExtensionPreprocessingJS = new Action();
