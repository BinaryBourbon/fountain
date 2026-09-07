import { ControlledReceiverSession } from './controlled-receiver.mjs';
import { MCP_VERSION } from '../receivers/mcp.mjs';
export { controlledOrigin as mcpOrigin } from './controlled-receiver.mjs';

export class McpReceiverSession extends ControlledReceiverSession {
  constructor(options) { super({ ...options, version: MCP_VERSION }); }
}
