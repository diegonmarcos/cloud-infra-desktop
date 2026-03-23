// Email tools — IMAP/SMTP access via openssl s_client
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../exec.js";

const DEFAULT_HOST = process.env.IMAP_HOST ?? "mail.diegonmarcos.com";
const DEFAULT_PORT_IMAP = 993;
const DEFAULT_PORT_SMTP = 465;

/** Build a piped openssl s_client IMAP session */
function imapSession(
  host: string,
  port: number,
  user: string,
  pass: string,
  commands: string[]
): string {
  // Escape single-quotes in credentials
  const u = user.replace(/'/g, "'\\''");
  const p = pass.replace(/'/g, "'\\''");
  const cmds = ["A001 LOGIN " + u + " " + p, ...commands, "Z LOGOUT"].join(
    "\n"
  );
  // Use printf + openssl; -quiet suppresses TLS handshake noise
  return `printf '${cmds.replace(/'/g, "'\\''")}\r\n' | openssl s_client -connect ${host}:${port} -quiet -crlf 2>/dev/null`;
}

export function registerEmailTools(server: McpServer) {
  // ── 1. Fetch recent emails ───────────────────────────────────────────────
  server.tool(
    "email_imap_fetch",
    "Fetch recent emails from an IMAP mailbox via openssl s_client (SSL/TLS). Returns headers (From, Subject, Date) for the N most recent messages.",
    {
      user: z.string().describe("IMAP username / email address"),
      pass: z.string().describe("IMAP password"),
      host: z
        .string()
        .optional()
        .describe(`IMAP host (default: ${DEFAULT_HOST})`),
      port: z
        .number()
        .optional()
        .describe(`IMAP port (default: ${DEFAULT_PORT_IMAP})`),
      mailbox: z
        .string()
        .optional()
        .describe("Mailbox to open (default: INBOX)"),
      count: z
        .number()
        .optional()
        .describe("Number of recent messages to fetch (default: 10, max: 50)"),
    },
    async ({ user, pass, host, port, mailbox, count }) => {
      const h = host ?? DEFAULT_HOST;
      const p = port ?? DEFAULT_PORT_IMAP;
      const mb = mailbox ?? "INBOX";
      const n = Math.min(count ?? 10, 50);

      const cmds = [
        `A002 SELECT "${mb}"`,
        `A003 SEARCH ALL`,
        // FETCH last N messages by sequence — we fetch 1:* then trim client-side
        `A004 FETCH 1:${n} (FLAGS BODY[HEADER.FIELDS (FROM TO SUBJECT DATE)])`,
      ];

      const cmd = imapSession(h, p, user, pass, cmds);
      const result = sh(cmd, { timeout: 20_000 });
      return {
        content: [{ type: "text", text: formatResult(`imap:fetch(${h})`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── 2. List IMAP mailboxes/folders ───────────────────────────────────────
  server.tool(
    "email_imap_list",
    "List all mailboxes/folders on an IMAP server via openssl s_client.",
    {
      user: z.string().describe("IMAP username / email address"),
      pass: z.string().describe("IMAP password"),
      host: z
        .string()
        .optional()
        .describe(`IMAP host (default: ${DEFAULT_HOST})`),
      port: z
        .number()
        .optional()
        .describe(`IMAP port (default: ${DEFAULT_PORT_IMAP})`),
    },
    async ({ user, pass, host, port }) => {
      const h = host ?? DEFAULT_HOST;
      const p = port ?? DEFAULT_PORT_IMAP;

      const cmds = [`A002 LIST "" "*"`];
      const cmd = imapSession(h, p, user, pass, cmds);
      const result = sh(cmd, { timeout: 15_000 });
      return {
        content: [{ type: "text", text: formatResult(`imap:list(${h})`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── 3. Raw IMAP commands ─────────────────────────────────────────────────
  server.tool(
    "email_imap_raw",
    "Send raw IMAP commands to a server via openssl s_client. Useful for advanced queries (SEARCH, FETCH body parts, etc.). Login is handled automatically; provide only post-login commands.",
    {
      user: z.string().describe("IMAP username / email address"),
      pass: z.string().describe("IMAP password"),
      commands: z
        .array(z.string())
        .describe(
          "IMAP commands to run after login (e.g. ['A002 SELECT INBOX', 'A003 SEARCH UNSEEN'])"
        ),
      host: z
        .string()
        .optional()
        .describe(`IMAP host (default: ${DEFAULT_HOST})`),
      port: z
        .number()
        .optional()
        .describe(`IMAP port (default: ${DEFAULT_PORT_IMAP})`),
    },
    async ({ user, pass, commands, host, port }) => {
      const h = host ?? DEFAULT_HOST;
      const p = port ?? DEFAULT_PORT_IMAP;

      const cmd = imapSession(h, p, user, pass, commands);
      const result = sh(cmd, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`imap:raw(${h})`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── 4. Check mail server SSL certificate ────────────────────────────────
  server.tool(
    "email_cert_check",
    "Inspect the SSL/TLS certificate of a mail server (IMAP or SMTP) using openssl s_client.",
    {
      host: z
        .string()
        .optional()
        .describe(`Mail host to check (default: ${DEFAULT_HOST})`),
      port: z
        .number()
        .optional()
        .describe(
          `Port to connect to (default: ${DEFAULT_PORT_IMAP} for IMAP)`
        ),
      protocol: z
        .enum(["imap", "smtp"])
        .optional()
        .describe("Protocol hint — affects starttls mode (default: imap)"),
    },
    async ({ host, port, protocol }) => {
      const h = host ?? DEFAULT_HOST;
      const proto = protocol ?? "imap";
      const p =
        port ?? (proto === "smtp" ? DEFAULT_PORT_SMTP : DEFAULT_PORT_IMAP);

      const starttls =
        proto === "smtp" && p !== 465 ? "-starttls smtp" : "";
      const cmd = `echo Q | openssl s_client -connect ${h}:${p} ${starttls} -showcerts 2>&1 | openssl x509 -noout -text 2>/dev/null | grep -E '(Subject|Issuer|Not Before|Not After|DNS:|IP Address)' | head -40`;
      const result = sh(cmd, { timeout: 15_000 });
      return {
        content: [{ type: "text", text: formatResult(`cert:${h}:${p}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ── 5. SMTP connectivity test ────────────────────────────────────────────
  server.tool(
    "email_smtp_test",
    "Test SMTP server connectivity and TLS handshake via openssl s_client. Does NOT send mail.",
    {
      host: z
        .string()
        .optional()
        .describe(`SMTP host (default: ${DEFAULT_HOST})`),
      port: z
        .number()
        .optional()
        .describe(`SMTP port (default: ${DEFAULT_PORT_SMTP})`),
    },
    async ({ host, port }) => {
      const h = host ?? DEFAULT_HOST;
      const p = port ?? DEFAULT_PORT_SMTP;
      const starttls = p === 587 || p === 25 ? "-starttls smtp" : "";
      const cmd = `echo QUIT | openssl s_client -connect ${h}:${p} ${starttls} -quiet 2>&1 | head -30`;
      const result = sh(cmd, { timeout: 15_000 });
      return {
        content: [{ type: "text", text: formatResult(`smtp:test(${h}:${p})`, result) }],
        isError: !result.ok,
      };
    }
  );
}
