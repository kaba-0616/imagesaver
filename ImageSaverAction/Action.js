var Action = function() {};

Action.prototype = {

    run: function(params) {
        var seen = {};
        var images = [];

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
            while ((hit = IMAGE_URL.exec(html)) !== null && found < 800) {
                addURL(hit[0], 0, 0, "source");
                found++;
            }
        } catch (e) {}

        params.completionFunction({
            "images": images,
            "pageTitle": document.title || "",
            "pageURL": document.URL || ""
        });
    },

    finalize: function(params) {}
};

var ExtensionPreprocessingJS = new Action();
