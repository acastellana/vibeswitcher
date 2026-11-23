// Between leads on the page (views/mail.js's data, the `mail` kind): the projects' record of the messages their leads
// sent each other with tell_lead, refused ones too, as `vibeswitcher mail` prints them (Sources/VibeNode/Server/
// MailRequest.swift's `MailText`). Read-only: a page reads the record and changes nothing.
import { t } from './i18n.js';


const KINDS = { question: t('mlQuestion'), report: t('mlReport'), answer: t('mlAnswer') };
const OUTCOMES = {
  delivered: t('mlDelivered'), waiting: t('mlWaitingInbox'), refused: t('mlRefused'), no_lead: t('mlNoLead'), off: t('mlOff'), failed: t('mlFailed'),
};

// One message as a row says it: which way it went and with whom ("from the lead of acme-api", "to the lead of …"), its
// kind, what became of it, its text, and why when it wasn't sent.
export function mailLine(message) {
  const other = message.received ? message.from : message.to;
  return {
    way: t(message.received ? 'mlFromLead' : 'mlToLead', { other }),
    kind: KINDS[message.kind] || t('mlNoKind'),
    outcome: OUTCOMES[message.outcome] || message.outcome,
    text: message.text,
    why: message.sent ? null : message.detail,
    sent: !!message.sent,
  };
}

// The command that lists a project's whole record in a terminal.
export const mailCommand = (root) => `vibeswitcher mail ${/^[A-Za-z0-9_./~-]+$/.test(root) ? root : `'${root.replace(/'/g, `'\\''`)}'`} --all`;
