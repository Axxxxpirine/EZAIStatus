import streamDeck, { action, KeyDownEvent, SingletonAction, WillAppearEvent, WillDisappearEvent } from "@elgato/streamdeck";
import { watch, type FSWatcher } from "node:fs";
import os from "node:os";
import path from "node:path";

import { shouldStopWatching } from "../lifecycle";
import { renderKey, toDataUrl } from "../render";
import { readStatus, statusPath } from "../status";

/** Relecture regroupée : un remplacement atomique déclenche plusieurs événements fichier. */
const DEBOUNCE_MS = 300;
/** Fait expirer un fichier périmé (app plantée) et raccroche la surveillance si le dossier apparaît. */
const TICK_MS = 15_000;

/** Une touche : en cours, terminées non lues et attente suivies par EZAIStatus. L'appui ouvre la prochaine terminée. */
@action({ UUID: "dev.xprn.ezaistatus.agents" })
export class AgentsAction extends SingletonAction {
	private readonly file = statusPath(os.homedir());
	private watcher?: FSWatcher;
	private timer?: NodeJS.Timeout;
	private debounce?: NodeJS.Timeout;
	private image?: string;

	override async onWillAppear(ev: WillAppearEvent): Promise<void> {
		this.start();
		if (this.image === undefined) await this.refresh();
		else if (ev.action.isKey()) await ev.action.setImage(this.image);
	}

	override onWillDisappear(_ev: WillDisappearEvent): void {
		if (shouldStopWatching([...this.actions].length)) this.stop();
	}

	override async onKeyDown(_ev: KeyDownEvent): Promise<void> {
		await streamDeck.system.openUrl("ezaistatus://next");
	}

	private start(): void {
		if (this.timer) return;
		this.attachWatcher();
		this.timer = setInterval(() => {
			this.attachWatcher();
			void this.refresh();
		}, TICK_MS);
	}

	private stop(): void {
		clearInterval(this.timer);
		clearTimeout(this.debounce);
		this.watcher?.close();
		this.timer = this.debounce = this.watcher = undefined;
		this.image = undefined;
	}

	/** Surveille le dossier plutôt que le fichier : l'app le remplace à chaque écriture. */
	private attachWatcher(): void {
		if (this.watcher) return;
		try {
			this.watcher = watch(path.dirname(this.file), (_event, name) => {
				if (name && name !== path.basename(this.file)) return;
				clearTimeout(this.debounce);
				this.debounce = setTimeout(() => void this.refresh(), DEBOUNCE_MS);
			});
			this.watcher.on("error", () => {
				this.watcher?.close();
				this.watcher = undefined;
			});
		} catch {
			// Dossier absent (EZAIStatus jamais lancé) : la minuterie réessaiera.
			this.watcher = undefined;
		}
	}

	private async refresh(): Promise<void> {
		const lang = streamDeck.info.application.language?.startsWith("fr") ? "fr" : "en";
		const image = toDataUrl(renderKey(await readStatus(this.file, Date.now()), lang));
		if (image === this.image) return;
		this.image = image;
		await Promise.all([...this.actions].map((a) => (a.isKey() ? a.setImage(image) : undefined)));
	}
}
