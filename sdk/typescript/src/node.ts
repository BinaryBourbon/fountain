/**
 * The Node entry point.
 *
 * Everything the SDK does works in a browser, and `src/index.ts` is what a
 * bundler gets. The one thing that cannot work there is reading
 * `~/.fountain/credentials`, so that lives here: importing `fountain-sdk`
 * under Node resolves to this module, which installs the reader and then
 * re-exports the same API.
 */
import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { parseCredentials, setCredentialsReader } from "./config.ts";

setCredentialsReader((profile) => {
  const override = (process.env.FOUNTAIN_CREDENTIALS_FILE ?? "").trim();
  const path = override || join(homedir(), ".fountain", "credentials");
  return parseCredentials(readFileSync(path, "utf8"), profile);
});

export * from "./index.ts";
export { default } from "./index.ts";
