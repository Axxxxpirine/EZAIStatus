import { readFile } from "node:fs/promises";
import path from "node:path";

/** Ce que la touche doit montrer. `offline` : EZAIStatus ne tourne pas, ou son fichier est illisible ou trop vieux. */
export type KeyState =
	| { kind: "offline" }
	| { kind: "live"; running: number; waiting: number; finished: number; unreadable: boolean };

/** L'app réécrit le fichier au moins toutes les 60 s : au-delà de trois battements manqués, elle ne tourne plus. */
export const STALE_AFTER_MS = 180_000;

const OFFLINE: KeyState = { kind: "offline" };

const isCount = (value: unknown): value is number => Number.isInteger(value) && (value as number) >= 0;

export function parseStatus(text: string | null, now: number): KeyState {
	if (text === null) return OFFLINE;
	let data: Record<string, unknown>;
	try {
		data = JSON.parse(text);
	} catch {
		return OFFLINE;
	}
	if (typeof data !== "object" || data === null || data.version !== 1) return OFFLINE;
	const { running, waiting, finished, writtenAt, unreadable } = data;
	if (!isCount(running) || !isCount(waiting) || !isCount(finished)) return OFFLINE;
	const written = typeof writtenAt === "string" ? Date.parse(writtenAt) : NaN;
	if (Number.isNaN(written) || now - written > STALE_AFTER_MS) return OFFLINE;
	return { kind: "live", running, waiting, finished, unreadable: Array.isArray(unreadable) && unreadable.length > 0 };
}

export function statusPath(home: string): string {
	return path.join(home, "Library", "Application Support", "EZAIStatus", "status.json");
}

export async function readStatus(file: string, now: number): Promise<KeyState> {
	let text: string | null;
	try {
		text = await readFile(file, "utf8");
	} catch {
		text = null;
	}
	return parseStatus(text, now);
}
