var Action = function() {};

Action.prototype = {

    run: function(params) {
        var seen = {};
        var images = [];

        function addURL(url, width, height) {
            if (!url) { return; }
            url = url.trim();
            if (url.indexOf("data:") === 0) { return; }
            try {
                url = new URL(url, document.baseURI).href;
            } catch (e) {
                return;
            }
            if (seen[url]) { return; }
            seen[url] = true;
            images.push({ url: url, width: width || 0, height: height || 0 });
        }

        function bestFromSrcset(srcset) {
            if (!srcset) { return null; }
            var candidates = srcset.split(",").map(function(part) {
                return part.trim().split(/\s+/)[0];
            }).filter(Boolean);
            return candidates.length ? candidates[candidates.length - 1] : null;
        }

        var imgEls = document.querySelectorAll("img");
        for (var i = 0; i < imgEls.length; i++) {
            var img = imgEls[i];
            var url = img.currentSrc || img.src || bestFromSrcset(img.getAttribute("srcset"))
                || img.getAttribute("data-src") || img.getAttribute("data-original");
            addURL(url, img.naturalWidth, img.naturalHeight);
        }

        var sourceEls = document.querySelectorAll("picture source, video source");
        for (var j = 0; j < sourceEls.length; j++) {
            var src = sourceEls[j];
            var url2 = bestFromSrcset(src.getAttribute("srcset")) || src.getAttribute("src");
            addURL(url2, 0, 0);
        }

        var allEls = document.querySelectorAll("*");
        var bgScanLimit = Math.min(allEls.length, 4000);
        for (var k = 0; k < bgScanLimit; k++) {
            var style;
            try {
                style = getComputedStyle(allEls[k]);
            } catch (e) {
                continue;
            }
            var bg = style && style.backgroundImage;
            if (bg && bg.indexOf("url(") !== -1) {
                var match = /url\(["']?([^"')]+)["']?\)/.exec(bg);
                if (match && match[1]) {
                    addURL(match[1], 0, 0);
                }
            }
        }

        params.completionFunction({
            "images": images,
            "pageTitle": document.title || "",
            "pageURL": document.URL || ""
        });
    },

    finalize: function(params) {}
};

var ExtensionPreprocessingJS = new Action();
