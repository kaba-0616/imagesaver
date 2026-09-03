// Runs Action.js against a stand-in DOM so a change can be checked without a
// build. Nothing on the device can attach a debugger to the extension, and a
// round trip through GitHub Actions and AltStore costs the better part of an
// hour, so the cheap checks belong here.
//
//     node tools/dryrun.js
//
// The one it exists for: every value handed to completionFunction has to be a
// string or a finite number. A null cannot cross into a property list, and the
// host answers by failing to read the payload at all -- no images, no clue
// which key did it. Build 63 shipped `rendered: null` and returned nothing on
// every page.

const fs = require("fs"), vm = require("vm"), path = require("path");

const ACTION = path.join(__dirname, "..", "ImageSaverAction", "Action.js");

function El(tag, attrs = {}, opts = {}) {
    return {
        tag, attrs,
        bg: opts.bg || "",
        rect: opts.rect || { width: 200, height: 140 },
        naturalWidth: opts.nw || 0, naturalHeight: opts.nh || 0,
        currentSrc: attrs.src || "", src: attrs.src || "",
        shadowRoot: null,
        // opts.link: the href of an <a> this element is nested inside, for
        // linksElsewhere's el.closest("a[href]") -- there is no real DOM tree
        // here, so the wrapping anchor is faked rather than actually nested.
        getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
        getBoundingClientRect() { return this.rect; },
        closest(sel) { return opts.link && sel === "a[href]" ? { href: opts.link } : null; },
        querySelectorAll() { return []; }
    };
}

/// Enough of a selector engine for the ones Action.js actually asks for:
/// bare tags, "*", [attr], [attr='v'] and [attr~='v'].
function matches(el, sel) {
    sel = sel.trim();
    if (sel === "*") { return true; }
    const parts = sel.split(/\s+/);
    const m = /^([a-z]*)((\[[^\]]*\])*)$/i.exec(parts[parts.length - 1]);
    if (!m) { return false; }
    if (m[1] && m[1] !== el.tag) { return false; }
    for (const c of m[2].match(/\[[^\]]*\]/g) || []) {
        const kv = /^\[([a-z_-]+)(?:([~]?=)'([^']*)')?\]$/i.exec(c);
        if (!kv) { return false; }
        const v = el.attrs[kv[1]];
        if (v == null) { return false; }
        if (kv[2] === "=" && v !== kv[3]) { return false; }
        if (kv[2] === "~=" && !String(v).split(/\s+/).includes(kv[3])) { return false; }
    }
    return true;
}

function run(pageURL, els, extraHTML = "") {
    const html = "<html>"
        + els.map(e => e.bg ? `<div style='background-image:${e.bg}'></div>` : "").join("")
        + extraHTML + "</html>";
    const document = {
        location: new URL(pageURL), baseURI: pageURL, URL: pageURL, title: "dry run",
        documentElement: { innerHTML: html },
        querySelectorAll(sel) {
            return els.filter(e => sel.split(",").some(s => matches(e, s)));
        }
    };
    const ctx = {
        document, URL, console,
        getComputedStyle: (el) => ({ backgroundImage: el.bg || "none" }),
        // Carousel walking is driven by setTimeout; firing straight through
        // keeps the dry run synchronous. It does not model Safari freezing
        // the page's timers, which is a device-only failure.
        setTimeout: (fn) => { fn(); return 0; }
    };
    vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(ACTION, "utf8"), ctx);
    vm.runInContext("ExtensionPreprocessingJS.run({ completionFunction: r => { globalThis.__out = r; } })", ctx);
    return ctx.__out;
}

let failures = 0;
function check(label, ok, detail = "") {
    console.log((ok ? "  ok   " : "  FAIL ") + label + (detail ? "  -- " + detail : ""));
    if (!ok) { failures++; }
}

/// The payload has to survive conversion to a property list.
function checkPlistSafe(payload) {
    const bad = [];
    (function walk(o, at) {
        for (const k of Object.keys(o)) {
            const v = o[k];
            if (v === null || v === undefined) { bad.push(at + "." + k); }
            else if (typeof v === "object") { walk(v, at + "." + k); }
            else if (typeof v === "number" && !isFinite(v)) { bad.push(at + "." + k); }
        }
    })(payload, "payload");
    check("plistに載せられない値が無い", bad.length === 0, bad.join(", "));

    // The guard in handOff drops such a value before it can do harm, which is
    // the point of it -- but a key that had to be dropped is still a mistake
    // in the caller, and silence here would let the next one through.
    const stripped = payload.trace.filter(t => t.includes("送信対象から除外"));
    check("値を落とさずに済んでいる", stripped.length === 0, stripped.join(", "));
}

// ---------------------------------------------------------------------------
// A resize-endpoint page, as sakurazaka46 / hinatazaka46 serve one.
// ---------------------------------------------------------------------------
{
    const H = "https://sakurazaka46.com/images/14";
    const els = [
        El("img", { src: "https://sakurazaka46.com/files/14/s46/img/logo.svg" }, { nw: 120, nh: 30 }),
        El("meta", { property: "og:image", content: `${H}/f0c/2640108dd382a555036b1443cfdde/1200_1200_102400.jpg` }),
        El("div", {}, { bg: `url("${H}/18d/f6c04bd71dbe206e6b322eca7576c/750_750_102400.jpg")` }),
        // One photo offered at two sizes: collapses onto one original, keeping
        // the larger thumbnail to preview it with.
        El("div", {}, { bg: `url("${H}/a8f/5788a167390678252e346a70e89df/300_300_102400.jpg")` }),
        El("div", {}, { bg: `url("${H}/a8f/5788a167390678252e346a70e89df/750_750_102400.jpg")` }),
        El("i", {}, { bg: `url("${H}/ccf/7167e7a550f4f7abd2f5329fe94d2/60_60_102400.jpg")`,
                      rect: { width: 24, height: 24 } })
    ];
    const p = run("https://sakurazaka46.com/s/s46/contents_list?cd=104", els);
    console.log("リサイズ配信のページ:");
    p.trace.forEach(t => console.log("       " + t));
    checkPlistSafe(p);

    const byURL = Object.fromEntries(p.images.map(i => [i.url, i]));
    const dup = byURL[`${H}/a8f/5788a167390678252e346a70e89df.jpg`];
    check("縮小指定が外れている", !!byURL[`${H}/18d/f6c04bd71dbe206e6b322eca7576c.jpg`]);
    check("同じ写真の2サイズが1件に畳まれる",
          p.images.filter(i => i.url.includes("5788a167")).length === 1);
    check("サムネイルは大きいほうの縮小版",
          !!dup && /750_750/.test(dup.rendered || ""), dup && dup.rendered);
    check("ロゴは書き換えない",
          !byURL["https://sakurazaka46.com/files/14/s46/img/logo.svg"].rendered);
}

// ---------------------------------------------------------------------------
// A diary entry's own page (sakurazaka46/hinatazaka46): a "他のメンバーの
// 日記" widget of small portrait thumbnails, each linking to a different
// member's diary entry, must not have its photos upgraded and kept alongside
// this entry's own -- they resolve through the same resize endpoint, so
// nothing about size or URL tells them apart, only the link target.
// ---------------------------------------------------------------------------
{
    const H = "https://sakurazaka46.com/images/14";
    const els = [
        // This entry's own photo, not wrapped in any link.
        El("img", { src: `${H}/f0c/2640108dd382a555036b1443cfdde/1200_1200_102400.jpg` },
           { rect: { width: 1200, height: 800 } }),
        // The widget: a different member's entry, wrapped in a link to that
        // entry's own detail page.
        El("img", { src: `${H}/ccf/7167e7a550f4f7abd2f5329fe94d2/60_60_102400.jpg` },
           { rect: { width: 60, height: 60 },
             link: "https://sakurazaka46.com/s/s46/diary/detail/70664" })
    ];
    const p = run("https://sakurazaka46.com/s/s46/diary/detail/70663?ima=0000", els);
    console.log("\n日記詳細ページ(他メンバーの日記ウィジェットあり):");
    p.trace.forEach(t => console.log("       " + t));
    checkPlistSafe(p);

    const byURL = Object.fromEntries(p.images.map(i => [i.url, i]));
    const own = byURL[`${H}/f0c/2640108dd382a555036b1443cfdde.jpg`];
    const widget = byURL[`${H}/ccf/7167e7a550f4f7abd2f5329fe94d2.jpg`];
    check("自分の投稿の写真はdom扱いのまま", !!own && own.origin !== "other", own && own.origin);
    check("他メンバーの日記へのリンク内の写真はother扱いになる",
          !!widget && widget.origin === "other", widget && widget.origin);
}

// ---------------------------------------------------------------------------
// A page with no resize endpoint: nothing may be rewritten, and no image may
// gain a `rendered` key.
// ---------------------------------------------------------------------------
{
    const els = [
        El("img", { src: "https://example.com/photo.jpg" }, { nw: 1600, nh: 900 }),
        El("img", { src: "https://scontent.cdninstagram.com/v/t51.82787-15/123456789_n.jpg" },
           { nw: 1080, nh: 1080 }),
        El("img", { src: "https://example.com/a/1920_1080_50.jpg" }, { nw: 1920, nh: 1080 })
    ];
    const p = run("https://example.com/gallery", els);
    console.log("\nリサイズ配信でないページ:");
    checkPlistSafe(p);
    check("URLを書き換えない", p.images.every(i => !i.rendered),
          p.images.filter(i => i.rendered).map(i => i.url).join(", "));
    check("画像は取れている", p.images.length >= 3, String(p.images.length));
}

console.log(failures ? `\n${failures}件 失敗` : "\nすべて通過");
process.exit(failures ? 1 : 0);
