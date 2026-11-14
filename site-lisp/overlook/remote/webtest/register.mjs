// Lets Node resolve the page's import-map keys (js/…, vendor/…) to files in web/.
import { register } from "node:module";

register("./resolve.mjs", import.meta.url);
