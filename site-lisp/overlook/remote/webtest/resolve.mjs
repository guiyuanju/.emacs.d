// Module resolve hook mapping import-map keys to web/ files, as the daemon's import map does in the browser.
const web = new URL("../web/", import.meta.url);

export async function resolve(specifier, context, next) {
  if (/^(js|vendor)\//.test(specifier)) return { url: new URL(specifier, web).href, shortCircuit: true };
  return next(specifier, context);
}
