// The vendored UMD libraries, loaded as modules; each sets its global.
import "vendor/framework7.js";
import "vendor/marked.js";
import "vendor/purify.js";

export const Framework7 = globalThis.Framework7;
export const marked = globalThis.marked;
export const DOMPurify = globalThis.DOMPurify;

// Framework7 injects its colour variables as an inline <style>, which the CSP blocks; vendor/framework7-colors.css carries them.
Framework7.prototype.colorsStyleEl = document.createElement("style");

export const app = new Framework7({ el: "#app", name: "overlook", theme: "ios", darkMode: "auto" });
