import {createLawSpecHighlighter} from "./textmate-highlighter.mjs";

export const lawSpecHighlighter = await (async () => {
  try {
    if (!globalThis.vscodetextmate || !globalThis.onig)
      throw new Error("The TextMate highlighting runtime did not load.");
    const [grammar, wasm] = await Promise.all([
      fetch(new URL("./lawspec.tmLanguage.json", import.meta.url)),
      fetch(new URL("./vendor/" + /*@ oniguruma-vendor @*/ + "/release/onig.wasm", import.meta.url)),
    ]);
    if (!grammar.ok || !wasm.ok) throw new Error("The LawSpec highlighting assets did not load.");
    return await createLawSpecHighlighter(globalThis.vscodetextmate, globalThis.onig,
      await grammar.json(), await wasm.arrayBuffer());
  } catch (error) {
    // Editing and compiler checks remain available when highlighting cannot load.
    console.warn("LawSpec highlighting unavailable:", error);
    return null;
  }
})();
