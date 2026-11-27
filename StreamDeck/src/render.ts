import type { KeyState } from "./status";

/** Couleurs système macOS, les mêmes que dans la barre des menus d'EZAIStatus. */
export const COLORS = {
	running: "#0A84FF",
	finished: "#30D158",
	waiting: "#FF9F0A",
	neutral: "#8E8E93",
	background: "#000000",
} as const;

const FONT = `font-family="-apple-system, Helvetica Neue, Helvetica, Arial, sans-serif" font-weight="700"`;

const count = (n: number) => (n >= 100 ? "99+" : String(n));

const ICON_RADIUS = 16;
const ICON_WIDTH = ICON_RADIUS * 2 + 5;
const GAP = 10;
/** Largeur moyenne d'un chiffre gras, en proportion de la taille de police (estimation, sans mesure de texte). */
const GLYPH_WIDTH = 0.6;
/** Hauteur des chiffres en proportion de la police : la moitié place leur milieu sur le centre de l'icône. */
const DIGIT_HALF_HEIGHT = 0.36;

/**
 * Position d'une ligne icône + nombre, centrée horizontalement dans la touche de 144 px. Les nombres de trois
 * caractères (« 99+ ») passent en plus petit pour tenir.
 */
export function rowLayout(value: string) {
	const fontSize = value.length >= 3 ? 36 : 46;
	const width = ICON_WIDTH + GAP + GLYPH_WIDTH * fontSize * value.length;
	const left = 72 - width / 2;
	return {
		left,
		right: left + width,
		iconCx: left + ICON_WIDTH / 2,
		textX: left + ICON_WIDTH + GAP,
		fontSize,
		baselineOffset: fontSize * DIGIT_HALF_HEIGHT,
	};
}

/** Cercle pointillé : « en cours », comme le symbole de la barre des menus. */
const runningIcon = (cx: number, cy: number) =>
	`<circle cx="${cx}" cy="${cy}" r="${ICON_RADIUS}" fill="none" stroke="${COLORS.running}" stroke-width="5" stroke-dasharray="6.5 6" stroke-linecap="round"/>`;

const checkIcon = (cx: number, cy: number, color: string) =>
	`<path d="M${cx - 15} ${cy + 1} l10 10 l20 -21" fill="none" stroke="${color}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>`;

type Row = { value: string; icon: (cx: number, cy: number) => string; color: string };

/** Lignes empilées : même colonne d'icônes et même police, bloc centré sur le nombre le plus long. */
function rowsBlock(rows: Row[], centers: number[]): string {
	const widest = rows.reduce((a, r) => (r.value.length > a.length ? r.value : a), "");
	const l = rowLayout(widest);
	return rows
		.map((r, i) => r.icon(l.iconCx, centers[i]) + text(l.textX, centers[i] + l.baselineOffset, l.fontSize, r.color, r.value))
		.join("");
}

const badge = (cx: number, cy: number, r: number) =>
	`<circle cx="${cx}" cy="${cy}" r="${r}" fill="${COLORS.waiting}"/>` +
	`<text x="${cx}" y="${cy + r * 0.5}" text-anchor="middle" font-size="${Math.round(r * 1.45)}" fill="#000000" ${FONT}>!</text>`;

const text = (x: number, y: number, size: number, color: string, value: string, anchor = "start") =>
	`<text x="${x}" y="${y}" text-anchor="${anchor}" font-size="${size}" fill="${color}" ${FONT}>${value}</text>`;

function body(state: KeyState, lang: "fr" | "en"): string {
	if (state.kind === "offline") {
		return (
			text(72, 66, 30, COLORS.neutral, "EZAI", "middle") +
			text(72, 100, 21, COLORS.neutral, lang === "fr" ? "hors ligne" : "offline", "middle")
		);
	}

	const rows: Row[] = [];
	if (state.running > 0) rows.push({ value: count(state.running), icon: runningIcon, color: COLORS.running });
	if (state.finished > 0)
		rows.push({ value: count(state.finished), icon: (cx, cy) => checkIcon(cx, cy, COLORS.finished), color: COLORS.finished });

	let parts = "";
	if (rows.length === 0) {
		// Rien ne tourne ni n'est terminé : soit un agent attend (grande pastille), soit tout est calme (coche grise).
		parts += state.waiting > 0
			? badge(72, 72, 34)
			: `<circle cx="72" cy="72" r="34" fill="none" stroke="${COLORS.neutral}" stroke-width="5"/>` + checkIcon(70, 72, COLORS.neutral);
	} else {
		parts += rowsBlock(rows, rows.length === 1 ? [72] : [48, 100]);
		if (state.waiting > 0) parts += badge(126, 18, 13);
	}
	// Une source illisible : les nombres peuvent être incomplets, on le signale sans les cacher.
	if (state.unreadable) parts += text(10, 136, 24, COLORS.neutral, "?");
	return parts;
}

/** Image de la touche, carré de 144 px (touches Retina), réduit par Stream Deck pour les touches de 72 px. */
export function renderKey(state: KeyState, lang: "fr" | "en"): string {
	return (
		`<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">` +
		`<rect width="144" height="144" fill="${COLORS.background}"/>` +
		body(state, lang) +
		`</svg>`
	);
}

export function toDataUrl(svg: string): string {
	return `data:image/svg+xml;charset=utf8,${encodeURIComponent(svg)}`;
}
