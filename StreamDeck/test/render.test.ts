import { expect, test } from "vitest";
import { renderKey, toDataUrl } from "../src/render";

const live = (o = {}) => ({ kind: "live", running: 0, waiting: 0, finished: 0, unreadable: false, ...o }) as const;

test("offline text by language", () => {
	expect(renderKey({ kind: "offline" }, "fr")).toContain("hors ligne");
	expect(renderKey({ kind: "offline" }, "en")).toContain("offline");
});
test("running and finished colors and counts", () => {
	const svg = renderKey(live({ running: 3, finished: 2 }), "fr");
	expect(svg).toContain("#0A84FF");
	expect(svg).toContain(">3<");
	expect(svg).toContain("#30D158");
	expect(svg).toContain(">2<");
	expect(svg).not.toContain("#FF9F0A");
});
test("zero lines are hidden", () => expect(renderKey(live({ running: 1 }), "fr")).not.toContain("#30D158"));
test("waiting badge", () => expect(renderKey(live({ waiting: 1 }), "fr")).toContain("#FF9F0A"));
test("all zero shows neutral check", () => {
	const svg = renderKey(live(), "fr");
	expect(svg).toContain("#8E8E93");
	expect(svg).not.toContain("#0A84FF");
});
test("unreadable mark", () => expect(renderKey(live({ running: 1, unreadable: true }), "fr")).toContain(">?<"));
test("large counts clamp", () => expect(renderKey(live({ running: 250 }), "fr")).toContain(">99+<"));
test("square 144 svg", () => expect(renderKey(live(), "fr")).toMatch(/^<svg [^>]*viewBox="0 0 144 144"/));
test("data url", () => expect(toDataUrl("<svg/>")).toBe("data:image/svg+xml;charset=utf8,%3Csvg%2F%3E"));

import { rowLayout } from "../src/render";

// Le groupe rond + nombre est centré dans la touche, quelle que soit la longueur du nombre.
test.each(["1", "12", "99+"])("row %s is horizontally centered", (value) => {
	const { left, right } = rowLayout(value);
	expect((left + right) / 2).toBeCloseTo(72, 0);
	expect(left).toBeGreaterThanOrEqual(6);
	expect(right).toBeLessThanOrEqual(138);
});
// Le chiffre est centré verticalement sur le rond : ligne de base = centre + moitié de la hauteur des chiffres.
test("number baseline sits on the icon center", () => {
	const { baselineOffset, fontSize } = rowLayout("3");
	expect(baselineOffset).toBeCloseTo(fontSize * 0.36, 1);
});

// Deux lignes : les icônes sont alignées en colonne et le bloc est centré sur la ligne la plus large.
test("two rows share the icon column", () => {
	const svg = renderKey(live({ running: 3, finished: 12 }), "fr");
	const circleCx = Number(svg.match(/<circle cx="([\d.]+)"[^>]*stroke="#0A84FF"/)![1]);
	const checkStart = Number(svg.match(/<path d="M([\d.]+) [\d.]+ l10 10 l20 -21"[^>]*stroke="#30D158"/)![1]);
	expect(checkStart + 15).toBeCloseTo(circleCx, 5);
	expect(circleCx).toBeCloseTo(rowLayout("12").iconCx, 5);
});
