import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { shouldStopWatching } from "../src/lifecycle";

// Le SDK retire la touche de sa liste avant onWillDisappear : le nombre reçu est celui des touches restantes.
test("keeps watching while another key is visible", () => expect(shouldStopWatching(1)).toBe(false));
test("stops when no key remains", () => expect(shouldStopWatching(0)).toBe(true));

// `Debug` est une liste d'arguments passés à Node en mode développeur (« enabled » = --inspect) : toute valeur
// autre qu'un argument valide fait planter le plugin. Pas de débogueur = pas de champ.
test("no node debugger arguments in the manifest", () => {
	const manifest = JSON.parse(readFileSync(new URL("../dev.xprn.ezaistatus.sdPlugin/manifest.json", import.meta.url), "utf8"));
	expect(manifest.Nodejs).toEqual({ Version: "24" });
});
