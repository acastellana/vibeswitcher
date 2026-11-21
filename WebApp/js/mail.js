// Between leads on the page (views/mail.js's data, the `mail` kind): the projects' record of the messages their leads
// sent each other with tell_lead, refused ones too, as `vibeswitcher mail` prints them (Sources/VibeNode/Server/
// MailRequest.swift's `MailText`). Read-only: a page reads the record and changes nothing.

const KINDS = { question: 'Question', report: 'Report', answer: 'Answer' };
const OUTCOMES = {
  delivered: 'delivered', waiting: 'waiting in its inbox', refused: 'refused', no_lead: 'no lead to take it', off: 'messaging is off', failed: 'not delivered',
};

// One message as a row says it: which way it went and with whom ("from the lead of acme-api", "to the lead of …"), its
// kind, what became of it, its text, and why when it wasn't sent.
export function mailLine(message) {
  const other = message.received ? message.from : message.to;
  return {
    way: `${message.received ? 'from' : 'to'} the lead of ${other}`,
    kind: KINDS[message.kind] || 'No kind',
    outcome: OUTCOMES[message.outcome] || message.outcome,
    text: message.text,
    why: message.sent ? null : message.detail,
    sent: !!message.sent,
  };
}

// The command that lists a project's whole record in a terminal.
export const mailCommand = (root) => `vibeswitcher mail ${/^[A-Za-z0-9_./~-]+$/.test(root) ? root : `'${root.replace(/'/g, `'\\''`)}'`} --all`;
