import streamDeck from "@elgato/streamdeck";

import { AgentsAction } from "./actions/agents";

streamDeck.logger.setLevel("info");
streamDeck.actions.registerAction(new AgentsAction());
streamDeck.connect();
