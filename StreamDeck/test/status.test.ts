import { expect, test } from "vitest";
import { parseStatus, readStatus, statusPath } from "../src/status";

const now = Date.parse("2026-11-27T10:00:00Z");
const ok = (o: object = {}) =>
	JSON.stringify({ version: 1, writtenAt: "2026-11-27T09:59:00Z", running: 2, waiting: 1, finished: 3, unreadable: [], ...o });

test("live state", () =>
	expect(parseStatus(ok(), now)).toEqual({ kind: "live", running: 2, waiting: 1, finished: 3, unreadable: false }));
test("unreadable source flagged", () => expect(parseStatus(ok({ unreadable: ["Codex"] }), now)).toMatchObject({ unreadable: true }));
test("missing file is offline", () => expect(parseStatus(null, now)).toEqual({ kind: "offline" }));
test("truncated JSON is offline", () => expect(parseStatus(ok().slice(0, 20), now)).toEqual({ kind: "offline" }));
test("stale after 180 s", () => {
	expect(parseStatus(ok({ writtenAt: "2026-11-27T09:57:01Z" }), now).kind).toBe("live");
	expect(parseStatus(ok({ writtenAt: "2026-11-27T09:56:59Z" }), now).kind).toBe("offline");
});
test("future writtenAt is accepted", () => expect(parseStatus(ok({ writtenAt: "2026-11-27T10:00:30Z" }), now).kind).toBe("live"));
test("unknown version is offline", () => expect(parseStatus(ok({ version: 2 }), now).kind).toBe("offline"));
test("non-numeric count is offline", () => expect(parseStatus(ok({ running: "2" }), now).kind).toBe("offline"));
test("unreadable writtenAt is offline", () => expect(parseStatus(ok({ writtenAt: "hier" }), now).kind).toBe("offline"));
test("readStatus on missing path is offline", async () =>
	expect(await readStatus("/nonexistent/status.json", now)).toEqual({ kind: "offline" }));
test("status path", () =>
	expect(statusPath("/Users/x")).toBe("/Users/x/Library/Application Support/EZAIStatus/status.json"));
