/**
 * Le SDK retire la touche de sa liste avant d'appeler onWillDisappear : on ne coupe la surveillance que s'il ne reste
 * plus aucune touche visible.
 */
export function shouldStopWatching(remainingKeys: number): boolean {
	return remainingKeys === 0;
}
