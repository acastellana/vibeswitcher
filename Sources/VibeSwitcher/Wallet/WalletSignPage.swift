import CryptoKit
import Foundation
import VibeCore

/// The page `WalletSignServer` serves for one wallet request: plain HTML, CSS and JavaScript shipped in the app, no
/// external script, font, image or request. It shows the request and has the browser's wallet extension
/// (`window.ethereum` only) add or switch the chain, check the connected accounts include `from`, and send the
/// transaction; the hash, or the user's rejection, is posted back to the same origin. The request rides in a JSON data
/// block (never run, `<` escaped), shown with textContent only. The script and style are fixed, so the CSP names their
/// hashes and nothing else runs.
enum WalletSignPage {
    /// The page's data for `request`, nil when it can't go this way (`from` isn't an address). `requestedBy`: the asking
    /// session's name as VibeSwitcher knows it. The rows are drawn in order, with textContent only: for a contract call,
    /// what it does (`WalletCall`, decoded here: nothing else on this path decodes it) comes first, then the native value
    /// it sends; `confirm`, for one that lets someone spend the wallet's tokens, is the sentence the user ticks before
    /// Sign in wallet works.
    static func data(for request: WalletRequest, requestedBy: String = "") -> [String: Any]? {
        guard let tx = WalletBrowser.transaction(for: request) else { return nil }
        let card = WalletCardModel(request: request, requestedBy: requestedBy, label: request.requestedBy.label, state: .waiting)
        let chainHex = "0x" + String(request.chainId, radix: 16)
        var txData: [String: Any] = ["from": tx.from, "to": tx.to, "value": tx.value]
        if let data = tx.data { txData["data"] = data }
        func row(_ label: String, _ value: String, _ kind: String = "") -> [String: String] { ["label": label, "value": value, "kind": kind] }
        var rows: [[String: String]] = []
        if let call = card.call {
            rows.append(row("Call", call.headline, call.alarming ? "big bad" : "big"))
            if let function = call.function { rows.append(row("Function", function, "mono")) }
            for field in call.fields {
                rows.append(row(field.name, field.value, [WalletRequestFormat.isAddress(field.value) ? "mono" : "", field.alarming ? "bad" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")))
            }
            rows.append(row("Value sent", "\(card.amount) \(card.asset)"))
            rows.append(row("Chain", card.chainText))
            rows.append(row("From", request.from, "mono"))
            rows.append(row("Contract", request.to, "mono"))
            rows.append(row("Calldata", "\(card.calldataBytes ?? 0) bytes"))
        } else {
            rows.append(row("Amount", "\(card.amount) \(card.asset)", "big"))
            rows.append(row("Chain", card.chainText))
            rows.append(row("From", request.from, "mono"))
            rows.append(row("To", request.to, "mono"))
            if request.asset != "native" {
                rows.append(row("Data", "a token transfer (\(tx.data.map { ($0.utf8.count - 2) / 2 } ?? 0) bytes)"))
            }
        }
        rows.append(row("Requested by", card.requestedByText))
        var page: [String: Any] = [
            "id": request.id, "line": card.line, "chain": card.chainText, "chainHex": chainHex, "rows": rows,
            "reasonTitle": WalletCardModel.reasonTitle, "reason": "“\(request.reason)”", "tx": txData,
        ]
        if let confirm = card.call?.confirmation { page["confirm"] = confirm }
        if card.call?.alarming == true { page["lineBad"] = true }
        if let chain = WalletBrowser.addableChains[request.chainId], let rpc = chain.rpc {
            page["addChain"] = ["chainId": chainHex, "chainName": chain.name, "rpcUrls": [rpc], "blockExplorerUrls": [chain.explorer],
                                "nativeCurrency": ["name": chain.symbol, "symbol": chain.symbol, "decimals": chain.decimals]] as [String: Any]
        }
        return page
    }

    /// The whole page for `request`, or nil when it can't go this way.
    static func html(for request: WalletRequest, requestedBy: String = "") -> String? {
        guard let data = data(for: request, requestedBy: requestedBy),
              let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return nil }
        return html(json: String(decoding: json, as: UTF8.self))
    }

    static func html(json: String) -> String {
        // Nothing in the data can end its block or start markup.
        var safe = ""
        for scalar in json.unicodeScalars {
            switch scalar {
            case "<": safe += "\\u003c"
            case ">": safe += "\\u003e"
            case "&": safe += "\\u0026"
            case "\u{2028}": safe += "\\u2028"
            case "\u{2029}": safe += "\\u2029"
            default: safe.unicodeScalars.append(scalar)
            }
        }
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <title>Sign in browser wallet · VibeSwitcher</title>
            <style>\(style)</style>
            </head>
            <body>
            <main>
            <h1>Transaction request</h1>
            <p id="line" class="line"></p>
            <p class="warn">This skips the Wallet Manager's checks. Your wallet's own popup shows the real transaction: read it there before you confirm.</p>
            <dl id="rows"></dl>
            <section class="reason"><h2 id="reasonTitle"></h2><blockquote id="reason"></blockquote></section>
            <p id="confirmRow" class="confirm" hidden><label><input type="checkbox" id="confirm"> <span id="confirmText"></span></label></p>
            <button id="sign" type="button" disabled>Sign in wallet</button>
            <p id="status" role="status" aria-live="polite"></p>
            <p id="hash" class="mono"></p>
            </main>
            <script type="application/json" id="request">\(safe)</script>
            <script>\(script)</script>
            </body>
            </html>
            """
    }

    /// The Content-Security-Policy: only this page's own script and style, requests only to its own origin.
    static let csp: String = {
        func hash(_ text: String) -> String { "'sha256-" + Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString() + "'" }
        return "default-src 'none'; script-src \(hash(script)); style-src \(hash(style)); connect-src 'self'; img-src 'none'; "
            + "font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }()

    static let style = """
        :root{color-scheme:light dark;--bg:#fafafa;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7;--warn:#a05a00;--bad:#c62828;--good:#1b7f3b;--accent:#0a66d8}
        @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--line:#3a3a3c;--warn:#ffb340;--bad:#ff6b6b;--good:#4cd964;--accent:#4c9bff}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        main{max-width:640px;margin:0 auto;padding:28px 16px}
        h1{font-size:20px;margin:0 0 8px}
        .line{font-size:18px;font-weight:600;margin:0 0 10px}
        .warn{color:var(--warn);margin:0 0 18px}
        dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 14px;margin:0 0 20px;padding:14px;border:1px solid var(--line);border-radius:10px}
        dt{color:var(--muted);text-align:right}
        dd{margin:0;overflow-wrap:anywhere;white-space:pre-wrap}
        .big{font-size:18px;font-weight:600}
        .bad{color:var(--bad);font-weight:600}
        .reason{margin:0 0 20px}
        .reason h2{font-size:13px;font-weight:400;color:var(--muted);margin:0 0 4px}
        blockquote{margin:0;padding:2px 0 2px 12px;border-left:3px solid var(--line);font-style:italic;white-space:pre-wrap;overflow-wrap:anywhere}
        .confirm{margin:0 0 16px;padding:10px 12px;border:1px solid var(--bad);border-radius:8px}
        .confirm label{display:flex;gap:8px;align-items:flex-start;cursor:pointer}
        .confirm input{margin-top:4px}
        .mono{font-family:ui-monospace,Menlo,monospace;font-size:13px;overflow-wrap:anywhere}
        button{font:inherit;font-weight:600;padding:9px 18px;border-radius:8px;border:0;background:var(--accent);color:#fff;cursor:pointer}
        button:disabled{opacity:.45;cursor:default}
        #status{min-height:1.5em}
        .error{color:var(--bad)}
        .done{color:var(--good)}
        """

    static let script = #"""
        (function () {
          "use strict";
          var req = JSON.parse(document.getElementById("request").textContent);
          function el(id) { return document.getElementById(id); }
          var rows = el("rows");
          req.rows.forEach(function (row) {
            var dt = document.createElement("dt"), dd = document.createElement("dd");
            dt.textContent = row.label;
            dd.textContent = row.value;
            if (row.kind) dd.className = row.kind;
            rows.appendChild(dt);
            rows.appendChild(dd);
          });
          el("line").textContent = req.line;
          if (req.lineBad === true) el("line").className = "line bad";
          el("reasonTitle").textContent = req.reasonTitle;
          el("reason").textContent = req.reason;
          var button = el("sign");
          // A call that lets someone spend the wallet's tokens: Sign in wallet works only once the user ticks the sentence
          // naming the spender and the amount.
          var confirm = el("confirm");
          if (req.confirm) {
            el("confirmText").textContent = req.confirm;
            el("confirmRow").hidden = false;
            confirm.addEventListener("change", function () { ready(); });
          }
          function confirmed() { return !req.confirm || confirm.checked === true; }
          var finished = false;
          function say(text, kind) { el("status").textContent = text; el("status").className = kind || ""; }
          function lower(text) { return String(text).toLowerCase(); }
          function errorText(e) { return e && e.message ? String(e.message) : e && e.code ? "error " + e.code : String(e); }
          function ready() {
            if (finished) return;
            if (!window.ethereum) {
              button.disabled = true;
              say("No wallet extension was found in this browser. Turn one on (Rabby, MetaMask) for this page, then reload it.", "error");
              return;
            }
            if (!confirmed()) {
              button.disabled = true;
              say("Tick the box above first: this call lets someone else spend from this wallet.");
              return;
            }
            button.disabled = false;
            say("Ready. The wallet's popup shows the transaction: read it there before you confirm.");
          }
          window.addEventListener("ethereum#initialized", ready, { once: true });
          ready();

          async function post(body) {
            var response = await fetch("result", { method: "POST", headers: { "Content-Type": "application/json" },
              body: JSON.stringify(body), credentials: "omit", cache: "no-store", referrerPolicy: "no-referrer" });
            if (!response.ok) throw new Error("VibeSwitcher answered " + response.status);
          }
          async function hasFrom(eth, method) {
            var accounts = await eth.request({ method: method });
            return Array.isArray(accounts) && accounts.map(lower).indexOf(lower(req.tx.from)) >= 0;
          }

          async function sign() {
            var eth = window.ethereum;
            if (!eth || finished || !confirmed()) return;
            button.disabled = true;
            try {
              say("Asking the wallet for its accounts…");
              if (!(await hasFrom(eth, "eth_requestAccounts"))) {
                say("The wallet's connected accounts don't include " + req.tx.from + ". Connect that account in the wallet, then try again. Nothing was sent.", "error");
                return;
              }
              var chain = await eth.request({ method: "eth_chainId" });
              if (lower(chain) !== req.chainHex) {
                say("Asking the wallet to switch to " + req.chain + "…");
                try {
                  await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: req.chainHex }] });
                } catch (e) {
                  if (!req.addChain || (e && e.code === 4001)) throw e;
                  say("Adding " + req.chain + " to the wallet…");
                  await eth.request({ method: "wallet_addEthereumChain", params: [req.addChain] });
                  await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: req.chainHex }] });
                }
                chain = await eth.request({ method: "eth_chainId" });
                if (lower(chain) !== req.chainHex) {
                  say("The wallet is still on another chain (" + chain + "). Nothing was sent.", "error");
                  return;
                }
              }
              // A contract at `from` (a Safe) isn't signed here; an account delegated by EIP-7702 is still an account.
              var code = await eth.request({ method: "eth_getCode", params: [req.tx.from, "latest"] });
              if (typeof code !== "string" || !(code === "0x" || code === "0x0" || /^0xef0100[0-9a-fA-F]{40}$/.test(code))) {
                say("The sending address is a contract (a Safe?), which this page doesn't sign for. Nothing was sent.", "error");
                return;
              }
              if (!(await hasFrom(eth, "eth_accounts"))) {
                say("The wallet's connected accounts don't include " + req.tx.from + " any more. Nothing was sent.", "error");
                return;
              }
              say("Confirm or reject it in the wallet's popup.");
              var tx = { from: req.tx.from, to: req.tx.to, value: req.tx.value };
              if (req.tx.data) tx.data = req.tx.data;
              var hash;
              try {
                hash = await eth.request({ method: "eth_sendTransaction", params: [tx] });
              } catch (e) {
                // Once it's asked to send, any error but the user's rejection may come after the transaction went out
                // (an RPC that timed out after taking it): no second try from here.
                finished = true;
                if (!(e && e.code === 4001)) {
                  say("The wallet said: " + errorText(e) + ". It may or may not have been sent: check the wallet's activity before doing anything else.", "error");
                  return;
                }
                try {
                  await post({ rejected: true });
                  say("Rejected in the wallet. VibeSwitcher has been told; you can close this tab.", "done");
                } catch (failure) {
                  say("Rejected in the wallet, but VibeSwitcher couldn't be told (" + errorText(failure) + ").", "error");
                }
                return;
              }
              finished = true;
              if (typeof hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
                say("The wallet answered something that isn't a transaction hash. Check the wallet's activity before trying again.", "error");
                return;
              }
              el("hash").textContent = "Transaction: " + hash;
              try {
                await post({ txHash: hash });
                say("Sent. VibeSwitcher has the transaction hash; you can close this tab.", "done");
              } catch (failure) {
                say("Sent, but VibeSwitcher couldn't be told (" + errorText(failure) + "). Give the agent the transaction hash below.", "error");
              }
            } catch (e) {
              say("The wallet said: " + errorText(e) + ". Nothing was sent; you can try again.", "error");
            } finally {
              if (!finished) button.disabled = !window.ethereum || !confirmed();
            }
          }
          button.addEventListener("click", sign);
        })();
        """#
}
