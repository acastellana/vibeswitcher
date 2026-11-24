// Acting at the `confirm` level: a passkey per acting request (the node's `web_acts confirm`), and adding one when the
// terminal asks (`vibeswitcher web --passkey`). The browser's own WebAuthn does the asking; this module only turns
// the node's messages into its options and its answers into the node's base64url fields. Nothing here is kept.
//
// - Registration: the node's {kind:"passkey", op:"register", register, challenge, rp, user, exclude, expires} becomes
//   navigator.credentials.create's options; its answer `passkey.registered` {register, id, clientDataJSON,
//   attestationObject}.
// - An acting request at confirm: refused `assertion-needed`, the page asks `act.challenge` {kind, args, action} (the
//   request exactly), shows the line it answers with, asks navigator.credentials.get, and sends the request again
//   (same action) with a top-level `assertion` {id, clientDataJSON, authenticatorData, signature}.

// base64url of bytes (an ArrayBuffer or a view), and back to an ArrayBuffer.
export function toB64url(bytes) {
  const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let binary = '';
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function fromB64url(text) {
  const base64 = String(text).replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

// Whether this browser can ask for a passkey here (a secure context with WebAuthn).
export const canAsk = (env = globalThis) => !!(env.navigator?.credentials && env.PublicKeyCredential);

// The node's registration offer as navigator.credentials.create's `publicKey`.
export function createOptions(offer) {
  return {
    challenge: fromB64url(offer.challenge),
    rp: { id: offer.rp?.id, name: offer.rp?.name },
    user: { id: fromB64url(offer.user.id), name: offer.user.name, displayName: offer.user.displayName },
    // ES256, and RS256 for the platform keys that only make that (Windows Hello on older builds).
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
    authenticatorSelection: { userVerification: 'required', residentKey: 'discouraged' },
    attestation: 'none',
    excludeCredentials: (offer.exclude || []).map((id) => ({ type: 'public-key', id: fromB64url(id) })),
    timeout: 60000,
  };
}

// Adds a passkey for `offer`: the args of `passkey.registered`. Throws the browser's error (NotAllowedError when the
// user cancels or the time runs out).
export async function register(offer, credentials = globalThis.navigator?.credentials) {
  const made = await credentials.create({ publicKey: createOptions(offer) });
  return {
    register: offer.register, id: toB64url(made.rawId),
    clientDataJSON: toB64url(made.response.clientDataJSON), attestationObject: toB64url(made.response.attestationObject),
  };
}

// The node's challenge (`act.challenge`'s result) as navigator.credentials.get's `publicKey`.
export function getOptions(challenge) {
  return {
    challenge: fromB64url(challenge.challenge),
    rpId: challenge.rpId,
    allowCredentials: (challenge.allow || []).map((id) => ({ type: 'public-key', id: fromB64url(id) })),
    userVerification: 'required',
    timeout: challenge.timeout || 60000,
  };
}

// The assertion a confirmed request carries, from the user's passkey. Throws the browser's error.
export async function assert(challenge, credentials = globalThis.navigator?.credentials) {
  const got = await credentials.get({ publicKey: getOptions(challenge) });
  return {
    id: toB64url(got.rawId), clientDataJSON: toB64url(got.response.clientDataJSON),
    authenticatorData: toB64url(got.response.authenticatorData), signature: toB64url(got.response.signature),
  };
}
