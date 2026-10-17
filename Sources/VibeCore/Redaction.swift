import Foundation

/// Masks credentials in text we store or show (commands awaiting approval, tool details, messages):
/// they would otherwise land in notification banners, Notification Center's history and the state files.
///
/// It must stay fast on any input (hooks have a 5 s budget; screens are masked many times a second, and debug
/// builds run it unoptimised), so the rules are written out by hand rather than as regular expressions. An
/// expression engine tries a rule at every place its first letter appears (200 KB of `p` with one `password`
/// in it cost about 10 ms per rule starting with p) and spends a fraction of a microsecond on every match; here
/// a rule only looks where its words are (found with `memmem` in a lowercased copy), reads each character a
/// bounded number of times, and the text is rebuilt once per rule that found something. A rule whose words
/// aren't in the text doesn't run. Each rule's comment has the regular expression it stands for; the tests
/// check the two agree on generated input (`RedactionAgreementTests`, against the expressions as they were).
/// 200 KB of the worst input found takes about 12 ms unoptimised, on its own (`RedactionSpeedTests`, which allow
/// 50); the expressions took up to 80 ms on the same inputs, and minutes on some (200 KB of `eyJ-`).
public enum Redaction {
    static let mask = "•••"

    public static func secrets(in text: String) -> String {
        // A leading newline gives every rule a character before the text's first word.
        let string = "\n" + text
        let present = Folded(string)
        let text = Text(string)
        for rule in rules where present.allows(rule.words) {
            rule.apply(text)
            text.applyMasks()
        }
        return text.string(from: 1)
    }

    struct Rule {
        /// It runs only when the lowercased text has one of these (none: always).
        let words: [String]
        let apply: (Text) -> Void
    }

    private static let rules: [Rule] = [
        Rule(words: ["-----begin "], apply: privateKeys),
        Rule(words: ["-----end "], apply: keyEnd),
        Rule(words: [], apply: maskWrapped),
        Rule(words: ["cookie:"], apply: cookieHeader),
        Rule(words: ["authorization:"], apply: authorizationHeader),
        Rule(words: ["bearer"], apply: bearer),
    ] + Name.allCases.map { name in Rule(words: [name.gate], apply: { named($0, name) }) } + [
        Rule(words: ["token", "secret", "pass", "api", "cookie"], apply: flags),
        Rule(words: ["-u", "--user"], apply: curlUser),
        Rule(words: ["mysql", "mariadb"], apply: mysql),
        Rule(words: ["sshpass"], apply: sshpass),
        Rule(words: ["://"], apply: urlCredentials),
        Rule(words: [], apply: awsSecret),
    ] + shapes

    /// Token shapes recognisable on their own, wherever they appear. Also looked for across a soft-wrapped
    /// line end (see `maskWrapped`).
    static let shapes: [Rule] = [
        Rule(words: ["sk-", "pk-", "rk-", "_live_", "_test_"], apply: secretKey),
        Rule(words: ["akia", "aiza", "age-secret-key-1"], apply: aKeys),
        Rule(words: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-"], apply: gitTokens),
        Rule(words: ["hf_", "hooks.slack.com/"], apply: hTokens),
        Rule(words: ["xox"], apply: slackToken),
        Rule(words: ["npm_"], apply: npmToken),
        Rule(words: ["pypi-age"], apply: pypiToken),
        Rule(words: ["sg."], apply: sendGrid),
        Rule(words: ["eyj"], apply: jwt),
        Rule(words: ["/api/webhooks/"], apply: discordWebhook),
    ]

    // MARK: - Private keys

    private static let begin = Word("-----BEGIN "), end = Word("-----END "), dashes = Word("-----")
    private static let privateKey = Word("PRIVATE KEY"), privateKeyBlock = Word("PRIVATE KEY BLOCK")

    /// `-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----(?:[\s\S]*?-----END <label>|[\s\S]*\z)`: a private key
    /// (PEM, PGP), whole: through its END line, or to the end of the text when it's cut off (a key taller than
    /// the screen, a truncated tool output).
    static func privateKeys(_ t: Text) {
        var at = 0
        while true {
            let b = t.findExact(begin, from: at)
            guard b < t.n else { return }
            guard let header = keyLabelEnd(t, b + 11) else { at = b + 1; continue }
            var stop = t.n, from = header
            while true {
                let e = t.findExact(end, from: from)
                guard e < t.n else { break }
                if let x = keyLabelEnd(t, e + 9) { stop = x; break }
                from = e + 1
            }
            t.mask(b, stop)
            at = stop
        }
    }

    /// `(\A\n)(?:(?!-----BEGIN )[\s\S])*?-----END <label>`: the rest of a key whose start scrolled off the top
    /// (the text up to its first END line, if no BEGIN comes first).
    static func keyEnd(_ t: Text) {
        guard t.n > 0, t.u[0] == 10 else { return }
        var from = 1
        while true {
            let e = t.findExact(end, from: from)
            guard e < t.n else { return }
            if let x = keyLabelEnd(t, e + 9) {
                if t.findExact(begin, from: 1) < e { return }
                t.mask(1, x)
                return
            }
            from = e + 1
        }
    }

    /// After "-----BEGIN " or "-----END ": `[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----`; where it ends. The label is
    /// made of the run's characters and the dashes aren't one, so the whole run must end with the name.
    private static func keyLabelEnd(_ t: Text, _ i: Int) -> Int? {
        let u = t.u, n = t.n
        var j = i
        while j < n && (isUpper(u[j]) || isDigit(u[j]) || u[j] == 32) { j += 1 }
        guard (j - i >= 11 && t.same(privateKey, at: j - 11)) || (j - i >= 17 && t.same(privateKeyBlock, at: j - 17)),
              t.same(dashes, at: j) else { return nil }
        return j + 5
    }

    // MARK: - Headers

    private static let cookieColon = Word("cookie:"), authorization = Word("authorization:")
    private static let bearerWord = Word("bearer"), basicWord = Word("basic"), tokenWord = Word("token")

    /// `(?i)(cookie:[ \t]*+)[^"'\r\n]+`: Cookie and Set-Cookie headers, whole.
    static func cookieHeader(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.find(cookieColon, from: at)
            guard c < n else { return }
            var i = c + 7
            while i < n && (u[i] == 32 || u[i] == 9) { i += 1 }
            var j = i
            while j < n && !(u[j] == 34 || u[j] == 39 || u[j] == 13 || u[j] == 10) { j += 1 }
            if j > i { t.mask(i, j); at = j } else { at = c + 1 }
        }
    }

    /// `(?i)(authorization:\s*(?:bearer|basic|token)?\s*)[^\s"']+`: keep the scheme, hide the credential.
    static func authorizationHeader(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.find(authorization, from: at)
            guard c < n else { return }
            let q = skipSpace(u, n, c + 14)
            var stop = 0
            let scheme = t.has(bearerWord, at: q) ? 6 : (t.has(basicWord, at: q) || t.has(tokenWord, at: q)) ? 5 : 0
            if scheme > 0 {
                let v = skipSpace(u, n, q + scheme), r = credentialEnd(u, n, v)
                if r > v { t.mask(v, r); stop = r }
            }
            if stop == 0 {
                // No credential after the scheme: the expression takes the scheme word itself.
                let r = credentialEnd(u, n, q)
                if r > q { t.mask(q, r); stop = r }
            }
            at = stop > 0 ? stop : c + 1
        }
    }

    /// `(?i)(bearer\s{1,4}+)(?=[A-Za-z]{0,200}+[0-9._~+/=-]|[A-Za-z]{20})[A-Za-z0-9._~+/=-]{8,}`: a bearer token in
    /// any header (`X-Auth: Bearer …`). One that's a plain word is prose ("Bearer tokens").
    static func bearer(_ t: Text) {
        let u = t.u, f = t.f, n = t.n
        var at = 0
        while true {
            let c = t.find(bearerWord, from: at)
            guard c < n else { return }
            at = c + 1
            var q = c + 6, spaces = 0
            while spaces < 4 && q < n && isSpace(u[q]) { q += 1; spaces += 1 }
            guard spaces > 0 else { continue }
            var letters = 0
            while letters < 200 && q + letters < n && isLower(f[q + letters]) { letters += 1 }
            guard letters >= 20 || (q + letters < n && isBearerMark(f[q + letters])) else { continue }
            var r = q
            while r < n && (isLower(f[r]) || isBearerMark(f[r])) { r += 1 }
            guard r - q >= 8 else { continue }
            t.mask(q, r)
            at = r
        }
    }

    /// `[0-9._~+/=-]`
    private static func isBearerMark(_ c: UInt16) -> Bool {
        isDigit(c) || c == 46 || c == 95 || c == 126 || c == 43 || c == 47 || c == 61 || c == 45
    }

    /// `[^\s"']*`: where it ends.
    private static func credentialEnd(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var r = i
        while r < n && !(isSpace(u[r]) || isQuote(u[r])) { r += 1 }
        return r
    }

    // MARK: - NAME=value

    /// Names with a secret word in them (GITHUB_TOKEN, client-key-data, …), as the expression's start:
    /// the rest of the name after the secret word is up to 16 more name characters, no hyphen.
    enum Name: CaseIterable {
        case token, secret, pass, api, access, privateKey, credential, cookie, key, auth, pwd

        /// The longest name (to where `value` starts) for those made of name characters only; 0 for the others.
        var longest: Int {
            switch self {
            case .token, .auth: 21
            case .secret, .cookie: 22
            case .pass: 26
            case .credential: 27
            case .api, .access, .privateKey, .key, .pwd: 0
            }
        }

        /// The secret word, for the gate.
        var gate: String {
            switch self {
            case .token: "token"
            case .secret: "secret"
            case .pass: "pass"
            case .api: "api"
            case .access: "access"
            case .privateKey: "private"
            case .credential: "credential"
            case .cookie: "cookie"
            case .key: "key"
            case .auth: "auth"
            case .pwd: "pwd"
            }
        }

        var word: Word {
            switch self {
            case .token: Redaction.tokenWord
            case .secret: Redaction.secretWord
            case .pass: Redaction.passWord
            case .api: Redaction.apiWord
            case .access: Redaction.accessWord
            case .privateKey: Redaction.privateWord
            case .credential: Redaction.credentialWord
            case .cookie: Redaction.cookieWord
            case .key: Redaction.keyWord
            case .auth: Redaction.authWord
            case .pwd: Redaction.pwdWord
            }
        }
    }

    private static let secretWord = Word("secret"), passWord = Word("pass"), apiWord = Word("api")
    private static let accessWord = Word("access"), privateWord = Word("private"), credentialWord = Word("credential")
    private static let cookieWord = Word("cookie"), keyWord = Word("key"), authWord = Word("auth"), pwdWord = Word("pwd")
    private static let wordWord = Word("word"), wd = Word("wd"), phrase = Word("phrase"), data = Word("data")

    /// `(?i)(NAME(?![a-z0-9_-])["']?\s{0,4}+[=:]\s*+)(["']?)(?:(?<=["'])(?:(?!\2)[^\\\n]|\\.)*+\2|(?!(?:bearer|basic|token)\s)[^\s"'&,;]+)`
    /// with `$1$2•••$2`: NAME=value, NAME: value, "api_key": "value". A quoted value up to its closing quote
    /// (spaces and escaped quotes included), else up to a space or separator. A scheme word (`Bearer …`) is
    /// left to the bearer rule. Matching starts at the secret word, whatever comes before it.
    static func named(_ t: Text, _ name: Name) {
        let u = t.u, f = t.f, n = t.n, word = name.word, longest = name.longest
        var at = 0, runEnd = 0
        while true {
            let c = t.find(word, from: at)
            guard c < n else { return }
            var nameEnd: Int?
            if name == .pwd {
                // `pwd` or `Pwd` as written, or `_pwd` in any case: MYSQL_PWD, not OLDPWD.
                if c >= 1 && c - 1 >= at && u[c - 1] == 95 || (u[c] == 112 || u[c] == 80) && u[c + 1] == 119 && u[c + 2] == 100 {
                    nameEnd = c + 3
                }
            } else {
                nameEnd = Self.nameEnd(t, name, c)
            }
            if let nameEnd, let stop = value(t, after: nameEnd) { at = stop; continue }
            at = c + 1
            // A name made of name characters only ends inside the run of them it starts in, and must be followed
            // by something else: in a run longer than the longest such name, every start but the last few fails
            // (`tokentoken…`).
            if longest > 0 {
                if c >= runEnd {
                    runEnd = c
                    while runEnd < n && isName(f[runEnd]) { runEnd += 1 }
                }
                if runEnd - longest > at { at = runEnd - longest }
            }
        }
    }

    /// Where the name that starts with `name`'s word at `c` ends.
    private static func nameEnd(_ t: Text, _ name: Name, _ c: Int) -> Int? {
        let f = t.f, n = t.n
        switch name {
        case .token: return nameTail(f, n, c + 5)
        case .secret: return nameTail(f, n, c + 6)
        case .pass:
            // pass(?:w(?:or)?d|wd|phrase)
            guard c + 4 < n else { return nil }
            let next = f[c + 4]
            if next == 119 && t.has(wordWord, at: c + 4) { return nameTail(f, n, c + 8) }
            if next == 119 && t.has(wd, at: c + 4) { return nameTail(f, n, c + 6) }
            if next == 112 && t.has(phrase, at: c + 4) { return nameTail(f, n, c + 10) }
            return nil
        case .api: return keyName(t, c + 3)
        case .access: return keyName(t, c + 6)
        case .privateKey: return keyName(t, c + 7)
        case .credential:
            // credentials?: taking the s never ends the name anywhere else.
            return nameTail(f, n, c + 10 < n && f[c + 10] == 115 ? c + 11 : c + 10)
        case .cookie: return nameTail(f, n, c + 6)
        case .key:
            // key[_-]data
            guard c + 3 < n, f[c + 3] == 95 || f[c + 3] == 45, t.has(data, at: c + 4) else { return nil }
            return nameTail(f, n, c + 8)
        case .auth:
            // `auth` and `pwd` only at the end of the name (ANTHROPIC_AUTH, MYSQL_PWD; not author or OLDPWD):
            // auth(?:_[a-z0-9_]{0,16}+)?
            return c + 4 < n && f[c + 4] == 95 ? nameTail(f, n, c + 5) : c + 4
        case .pwd: return c + 3
        }
    }

    /// `[_-]?key` from `i`, then the rest of the name.
    private static func keyName(_ t: Text, _ i: Int) -> Int? {
        let f = t.f, n = t.n
        if i < n && (f[i] == 95 || f[i] == 45) { return t.has(keyWord, at: i + 1) ? nameTail(f, n, i + 4) : nil }
        return t.has(keyWord, at: i) ? nameTail(f, n, i + 3) : nil
    }

    /// `[a-z0-9_]{0,16}+`
    private static func nameTail(_ f: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        let stop = i + 16 < n ? i + 16 : n
        var j = i
        while j < stop && isName(f[j]) { j += 1 }
        return j
    }

    /// After a secret's name: `(?![a-z0-9_-])["']?\s{0,4}+[=:]\s*+(["']?)` and the value, masked; where the match ends.
    private static func value(_ t: Text, after e: Int) -> Int? {
        let u = t.u, f = t.f, n = t.n
        if e < n && (isName(f[e]) || f[e] == 45) { return nil }
        var i = e
        if i < n && isQuote(u[i]) { i += 1 }
        var spaces = 0
        while spaces < 4 && i < n && isSpace(u[i]) { i += 1; spaces += 1 }
        guard i < n && (u[i] == 61 || u[i] == 58) else { return nil }
        i = skipSpace(u, n, i + 1)
        if i < n && isQuote(u[i]) {
            let quote = u[i]
            var j = i + 1
            while j < n {
                let c = u[j]
                if c == quote || c == 10 { break }
                if c == 92 {
                    guard j + 1 < n && !isLineEnd(u[j + 1]) else { break }
                    j += 2
                    continue
                }
                j += 1
            }
            if j < n && u[j] == quote { t.mask(i + 1, j); return j + 1 }
            // Unterminated: the value up to a space, given the closing quote it lacks.
            guard let stop = plainValueEnd(t, i + 1) else { return nil }
            t.mask(i + 1, stop, then: quote)
            return stop
        }
        guard let stop = plainValueEnd(t, i) else { return nil }
        t.mask(i, stop)
        return stop
    }

    /// `(?!(?:bearer|basic|token)\s)[^\s"'&,;]+`: where it ends.
    private static func plainValueEnd(_ t: Text, _ v: Int) -> Int? {
        let u = t.u, f = t.f, n = t.n
        if v < n && (f[v] == 98 || f[v] == 116),
           (t.has(bearerWord, at: v) && v + 6 < n && isSpace(u[v + 6]))
            || ((t.has(basicWord, at: v) || t.has(tokenWord, at: v)) && v + 5 < n && isSpace(u[v + 5])) { return nil }
        var r = v
        while r < n {
            let c = u[r]
            if isSpace(c) || c == 34 || c == 39 || c == 38 || c == 44 || c == 59 { break }
            r += 1
        }
        return r > v ? r : nil
    }

    // MARK: - Command lines

    private static let password = Word("password"), passwd = Word("passwd"), passphrase = Word("passphrase")

    /// `(?i)(\s--?(?:[a-z0-9]{1,30}+-){0,4}(?:token|secret|passw(?:or)?d|passwd|passphrase|api-?key|cookie|pass(?![a-z]))[a-z0-9-]{0,40}+(?:=|\s++)["']?)[^\s"'<>|&;][^\s"']*`:
    /// --password value, --api-key=value, --pass value (flags only: in prose "the token expired" is fine; the
    /// secret word starts one of the flag's first five words).
    static func flags(_ t: Text) {
        let u = t.u, f = t.f, n = t.n
        let hits = Hits(t, [tokenWord, secretWord, passWord, apiWord, cookieWord])
        // A flag starts after a space, at the start of the run of [a-z0-9-] its secret word is in, at most
        // 126 characters before it. Each word's run start, reusing the previous word's when it's in the same run.
        var previous = -1, previousStart = -1, lastTried = -1, at = 0, from = 0
        while true {
            let w = hits.first(from: from).at
            guard w < n else { return }
            from = w + 1
            let limit = w - 130 > previous + 1 ? w - 130 : previous + 1
            var j = w - 1
            while j >= limit && j >= 0 && (isAlnum(f[j]) || f[j] == 45) { j -= 1 }
            let start = j >= limit || j < 0 ? j + 1 : (limit == previous + 1 ? previousStart : -1)
            previous = w
            previousStart = start
            guard start >= 1, u[start] == 45, isSpace(u[start - 1]) else { continue }
            let s = start - 1
            guard s > lastTried else { continue }
            lastTried = s
            if s >= at, let stop = flag(t, s) { at = stop }
        }
    }

    /// The flag at `s` (the space before it), masked; where it ends.
    private static func flag(_ t: Text, _ s: Int) -> Int? {
        let u = t.u, f = t.f, n = t.n
        guard s + 2 < n else { return nil }
        // --? : with one dash where there are two, the next character is a dash, which starts neither a group
        // nor a secret word.
        let x0 = u[s + 2] == 45 ? s + 3 : s + 2
        // (?:[a-z0-9]{1,30}+-){0,4}: as many as there are, then one fewer at a time.
        var ends = (x0, 0, 0, 0, 0)
        var groups = 0, x = x0
        while groups < 4 {
            var r = x, length = 0
            while length < 30 && r < n && isAlnum(f[r]) { r += 1; length += 1 }
            guard length > 0 && r < n && u[r] == 45 else { break }
            x = r + 1
            groups += 1
            switch groups {
            case 1: ends.1 = x
            case 2: ends.2 = x
            case 3: ends.3 = x
            default: ends.4 = x
            }
        }
        while groups >= 0 {
            let x = groups == 0 ? ends.0 : groups == 1 ? ends.1 : groups == 2 ? ends.2 : groups == 3 ? ends.3 : ends.4
            if let stop = flagValue(t, x) { return stop }
            groups -= 1
        }
        return nil
    }

    /// From a flag's secret word at `x`: the rest of the flag, `=` or spaces, and the value, masked.
    private static func flagValue(_ t: Text, _ x: Int) -> Int? {
        let u = t.u, f = t.f, n = t.n
        guard x < n else { return nil }
        // By its first letter: one or two comparisons instead of trying each word.
        var w = 0
        switch f[x] {
        case 116: if t.has(tokenWord, at: x) { w = x + 5 }
        case 115: if t.has(secretWord, at: x) { w = x + 6 }
        case 112:
            if t.has(passWord, at: x) {
                if t.has(password, at: x) { w = x + 8 }
                else if t.has(passwd, at: x) { w = x + 6 }
                else if t.has(passphrase, at: x) { w = x + 10 }
                else if !(x + 4 < n && isLower(f[x + 4])) { w = x + 4 }
            }
        case 97:
            if t.has(apiWord, at: x) {
                if x + 3 < n && f[x + 3] == 45 && t.has(keyWord, at: x + 4) { w = x + 7 }
                else if t.has(keyWord, at: x + 3) { w = x + 6 }
            }
        case 99: if t.has(cookieWord, at: x) { w = x + 6 }
        default: break
        }
        guard w > 0 else { return nil }
        var length = 0
        while length < 40 && w < n && (isAlnum(f[w]) || f[w] == 45) { w += 1; length += 1 }
        var i: Int
        if w < n && u[w] == 61 { i = w + 1 }
        else if w < n && isSpace(u[w]) { i = skipSpace(u, n, w) }
        else { return nil }
        if i < n && isQuote(u[i]) { i += 1 }
        guard i < n else { return nil }
        let first = u[i]
        if isSpace(first) || isQuote(first) || first == 60 || first == 62 || first == 124 || first == 38 || first == 59 {
            return nil
        }
        let stop = credentialEnd(u, n, i + 1)
        t.mask(i, stop)
        return stop
    }

    private static let dashU = Word("-u"), dashDashUser = Word("--user")

    /// `(\s(?:-u\s*+|--user(?:\s++|=))["']?[^\s:"'@/-][^\s:"'@/]*+:)[^\s"']+`: curl -u user:pass, --user user:pass:
    /// keep the user.
    static func curlUser(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0, from = 1
        while true {
            let o = t.findExact(dashU, from: from)
            guard o < n else { return }
            from = o + 1
            // `--user` starts a dash earlier.
            if o >= 2 && o - 2 >= at && isSpace(u[o - 2]) && t.same(dashDashUser, at: o - 1) {
                var p = o + 5
                if p < n && isSpace(u[p]) { p = skipSpace(u, n, p) } else if p < n && u[p] == 61 { p += 1 } else { p = -1 }
                if p >= 0, let stop = userPassword(t, p) { at = stop; continue }
            }
            if o - 1 >= at && isSpace(u[o - 1]) {
                if let stop = userPassword(t, skipSpace(u, n, o + 2)) { at = stop }
            }
        }
    }

    /// `["']?[^\s:"'@/-][^\s:"'@/]*+:[^\s"']+` at `p`, the password masked; where it ends.
    private static func userPassword(_ t: Text, _ p: Int) -> Int? {
        let u = t.u, n = t.n
        var q = p
        if q < n && isQuote(u[q]) { q += 1 }
        guard q < n, !isUserStop(u[q]), u[q] != 45 else { return nil }
        var r = q + 1
        while r < n && !isUserStop(u[r]) { r += 1 }
        guard r < n && u[r] == 58 else { return nil }
        let stop = credentialEnd(u, n, r + 1)
        guard stop > r + 1 else { return nil }
        t.mask(r + 1, stop)
        return stop
    }

    /// `[\s:"'@/]`
    private static func isUserStop(_ c: UInt16) -> Bool { isSpace(c) || c == 58 || isQuote(c) || c == 64 || c == 47 }

    private static let mysqlWord = Word("mysql"), mariadb = Word("mariadb"), dump = Word("dump"), admin = Word("admin")
    private static let dashP = Word("-p"), sshpassWord = Word("sshpass")

    /// `((?:mysql(?:dump|admin)?|mariadb)\b(?:[ \t]++(?!-p|mysql|mariadb)[^\s|;&]++){0,8}+[ \t]++-p["']?)[^\s"']+`:
    /// mysql -ppassword (attached: `-p name` is a prompt and a database), among the command's next eight words
    /// (up to the next mysql, so floods of them stay linear).
    static func mysql(_ t: Text) {
        let n = t.n
        let hits = Hits(t, [mysqlWord, mariadb])
        var at = 0
        while true {
            let c = hits.first(from: at).at
            guard c < n else { return }
            var e = -1
            if t.same(mysqlWord, at: c) {
                e = c + 5
                if t.same(dump, at: e) { e += 4 } else if t.same(admin, at: e) { e += 5 }
            } else if t.same(mariadb, at: c) {
                e = c + 7
            }
            if e > 0, boundary(t, e), let p = dashPAfterWords(t, e, sshpass: false), let stop = password(t, p) {
                at = stop
            } else {
                at = c + 1
            }
        }
    }

    /// `(sshpass\b(?:[ \t]++(?!-p|sshpass)[^\s|;&]++){0,8}+[ \t]++-p[ \t]*+["']?)[^\s"']+`: sshpass -p password.
    static func sshpass(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.findExact(sshpassWord, from: at)
            guard c < n else { return }
            if boundary(t, c + 7), var p = dashPAfterWords(t, c + 7, sshpass: true) {
                while p < n && (u[p] == 32 || u[p] == 9) { p += 1 }
                if let stop = password(t, p) { at = stop; continue }
            }
            at = c + 1
        }
    }

    /// `(?:[ \t]++(?!-p|<command>)[^\s|;&]++){0,8}+[ \t]++-p` from `i`: where it ends.
    private static func dashPAfterWords(_ t: Text, _ i: Int, sshpass: Bool) -> Int? {
        let u = t.u, n = t.n
        var i = i, words = 0
        while words < 8 {
            var j = i
            while j < n && (u[j] == 32 || u[j] == 9) { j += 1 }
            guard j > i else { break }
            if t.same(dashP, at: j) || (sshpass ? t.same(sshpassWord, at: j) : t.same(mysqlWord, at: j) || t.same(mariadb, at: j)) {
                break
            }
            var k = j
            while k < n && !(isSpace(u[k]) || u[k] == 124 || u[k] == 59 || u[k] == 38) { k += 1 }
            guard k > j else { break }
            i = k
            words += 1
        }
        var j = i
        while j < n && (u[j] == 32 || u[j] == 9) { j += 1 }
        guard j > i && t.same(dashP, at: j) else { return nil }
        return j + 2
    }

    /// `["']?[^\s"']+` at `p`, masked; where it ends.
    private static func password(_ t: Text, _ p: Int) -> Int? {
        let u = t.u, n = t.n
        let v = p < n && isQuote(u[p]) ? p + 1 : p
        let stop = credentialEnd(u, n, v)
        guard stop > v else { return nil }
        t.mask(v, stop)
        return stop
    }

    private static let schemeEnd = Word("://")

    /// `(://[^/\s:@]++:)[^@\s/]++@` with `$1•••@`: credentials inside URLs, scheme://user:pass@host.
    static func urlCredentials(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.find(schemeEnd, from: at)
            guard c < n else { return }
            at = c + 1
            var i = c + 3
            while i < n && !(u[i] == 47 || isSpace(u[i]) || u[i] == 58 || u[i] == 64) { i += 1 }
            guard i > c + 3 && i < n && u[i] == 58 else { continue }
            var j = i + 1
            while j < n && !(u[j] == 64 || isSpace(u[j]) || u[j] == 47) { j += 1 }
            guard j > i + 1 && j < n && u[j] == 64 else { continue }
            t.mask(i + 1, j)
            at = j + 1
        }
    }

    /// `([^A-Za-z0-9/+=])(?=[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+=]))(?=…[A-Z])(?=…[a-z])(?=…[0-9])[A-Za-z0-9/+]{40}`: a
    /// bare AWS secret key, exactly 40 of base64's characters with upper, lower and a digit (a hex hash has one
    /// case only).
    static func awsSecret(_ t: Text) {
        let u = t.u, n = t.n
        // Comparisons written out: this reads every character of every text.
        var i = 1
        while i < n {
            var c = u[i]
            guard (c &- 48) < 10 || ((c | 32) &- 97) < 26 || c == 43 || c == 47 else { i += 1; continue }
            let start = i
            var upper = false, lower = false, digit = false
            while true {
                if (c &- 65) < 26 { upper = true } else if (c &- 97) < 26 { lower = true } else if (c &- 48) < 10 { digit = true }
                else if c != 43 && c != 47 { break }
                i += 1
                guard i < n else { break }
                c = u[i]
            }
            if i - start == 40 && upper && lower && digit && u[start - 1] != 61 && (i == n || u[i] != 61) {
                t.mask(start, i)
            }
        }
    }

    // MARK: - Token shapes (case as written)

    private static let kDash = Word("k-"), kUnder = Word("k_"), live = Word("_live_"), test = Word("_test_")

    /// `[spr]k(?<![A-Za-z0-9_][spr]k)(?:-[A-Za-z0-9_-]{16,}|_(?:live|test)_[A-Za-z0-9]{10,})`: OpenAI, Anthropic, …
    /// (sk-…), Stripe (sk_live_…). Not after a name character: `task-…` isn't `sk-…`.
    static func secretKey(_ t: Text) {
        let u = t.u, n = t.n
        let hits = Hits(t, [kDash, kUnder])
        var at = 0, from = 1
        while true {
            let o = hits.first(from: from).at
            guard o < n else { return }
            from = o + 1
            let c = o - 1
            guard c >= at, u[o] == 107, u[c] == 115 || u[c] == 112 || u[c] == 114, c == 0 || !isWordChar(u[c - 1]) else {
                continue
            }
            var stop = 0
            if u[o + 1] == 45 {
                let r = runToken(u, n, o + 2)
                if r - (o + 2) >= 16 { stop = r }
            } else if t.same(live, at: o + 1) || t.same(test, at: o + 1) {
                let r = runAlnum(u, n, o + 7)
                if r - (o + 7) >= 10 { stop = r }
            }
            if stop > 0 { t.mask(c, stop); at = stop; from = stop + 1 }
        }
    }

    private static let akia = Word("AKIA"), aiza = Word("AIza"), ageKey = Word("AGE-SECRET-KEY-1")

    /// `A(?:KIA[0-9A-Z]{16}\b|Iza[0-9A-Za-z_-]{30,}|GE-SECRET-KEY-1[0-9A-Z]{20,})`: AWS access key, Google API key, age.
    static func aKeys(_ t: Text) {
        let u = t.u, n = t.n
        let hits = Hits(t, [akia, aiza, ageKey])
        var at = 0
        while true {
            let c = hits.first(from: at).at
            guard c < n else { return }
            var stop = 0
            if t.same(akia, at: c) {
                // Exactly 16, then the end of the word.
                var i = c + 4
                while i < c + 20 && i < n && (isUpper(u[i]) || isDigit(u[i])) { i += 1 }
                if i == c + 20 && boundary(t, i) { stop = i }
            } else if t.same(aiza, at: c) {
                let r = runToken(u, n, c + 4)
                if r - (c + 4) >= 30 { stop = r }
            } else if t.same(ageKey, at: c) {
                let r = runUpperDigit(u, n, c + 16)
                if r - (c + 16) >= 20 { stop = r }
            }
            if stop > 0 { t.mask(c, stop); at = stop } else { at = c + 1 }
        }
    }

    private static let gh = Word("gh"), githubPat = Word("github_pat_"), glpat = Word("glpat-")

    /// `g(?:h[pousr]_[A-Za-z0-9]{20,}|ithub_pat_[A-Za-z0-9_]{20,}|lpat-[A-Za-z0-9_-]{20,})`: GitHub, GitLab.
    static func gitTokens(_ t: Text) {
        let u = t.u, n = t.n
        let hits = Hits(t, [gh, githubPat, glpat])
        var at = 0
        while true {
            let c = hits.first(from: at).at
            guard c < n else { return }
            var stop = 0
            if t.same(gh, at: c) {
                if c + 4 <= n, u[c + 3] == 95, u[c + 2] == 112 || u[c + 2] == 111 || u[c + 2] == 117 || u[c + 2] == 115 || u[c + 2] == 114 {
                    let r = runAlnum(u, n, c + 4)
                    if r - (c + 4) >= 20 { stop = r }
                }
            } else if t.same(githubPat, at: c) {
                let r = runWordChars(u, n, c + 11)
                if r - (c + 11) >= 20 { stop = r }
            } else if t.same(glpat, at: c) {
                let r = runToken(u, n, c + 6)
                if r - (c + 6) >= 20 { stop = r }
            }
            if stop > 0 { t.mask(c, stop); at = stop } else { at = c + 1 }
        }
    }

    private static let hf = Word("hf_"), slackHooks = Word("hooks.slack.com/")
    private static let services = Word("services/"), workflows = Word("workflows/"), triggers = Word("triggers/")

    /// `h(?:f_[A-Za-z0-9]{30,}|ooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]+)`: Hugging Face; a
    /// Slack webhook (whoever has one can post).
    static func hTokens(_ t: Text) {
        let u = t.u, n = t.n
        let hits = Hits(t, [hf, slackHooks])
        var at = 0
        while true {
            let c = hits.first(from: at).at
            guard c < n else { return }
            var stop = 0
            if t.same(hf, at: c) {
                let r = runAlnum(u, n, c + 3)
                if r - (c + 3) >= 30 { stop = r }
            } else if t.same(slackHooks, at: c) {
                let i = c + 16
                let path = t.same(services, at: i) || t.same(triggers, at: i) ? i + 9 : t.same(workflows, at: i) ? i + 10 : 0
                if path > 0 {
                    let r = runSlackPath(u, n, path)
                    if r > path { stop = r }
                }
            }
            if stop > 0 { t.mask(c, stop); at = stop } else { at = c + 1 }
        }
    }

    private static let xox = Word("xox")

    /// `xox[abposr]-[A-Za-z0-9-]{10,}`: Slack.
    static func slackToken(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.findExact(xox, from: at)
            guard c < n else { return }
            var stop = 0
            if c + 5 <= n, (u[c + 3] == 97 || u[c + 3] == 98 || u[c + 3] == 112 || u[c + 3] == 111 || u[c + 3] == 115 || u[c + 3] == 114), u[c + 4] == 45 {
                var r = c + 5
                while r < n && (isAlnum(u[r]) || u[r] == 45) { r += 1 }
                if r - (c + 5) >= 10 { stop = r }
            }
            if stop > 0 { t.mask(c, stop); at = stop } else { at = c + 1 }
        }
    }

    private static let npm = Word("npm_"), pypi = Word("pypi-AgE")

    /// `npm_[A-Za-z0-9]{30,}`
    static func npmToken(_ t: Text) { prefixed(t, npm, minimum: 30, run: runAlnum) }

    /// `pypi-AgE[A-Za-z0-9_-]{16,}`
    static func pypiToken(_ t: Text) { prefixed(t, pypi, minimum: 16, run: runToken) }

    /// `word` as written, then at least `minimum` of `run`'s characters.
    private static func prefixed(_ t: Text, _ word: Word, minimum: Int,
                                 run: (UnsafeMutablePointer<UInt16>, Int, Int) -> Int) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.findExact(word, from: at)
            guard c < t.n else { return }
            let r = run(u, n, c + word.count)
            if r - (c + word.count) >= minimum { t.mask(c, r); at = r } else { at = c + 1 }
        }
    }

    private static let sg = Word("SG."), eyJ = Word("eyJ")

    /// `SG\.(?<![A-Za-z0-9_]SG\.)[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}`: SendGrid.
    static func sendGrid(_ t: Text) { dotted(t, sg, parts: 2, minimum: 16) }

    /// `eyJ(?<![A-Za-z0-9_]eyJ)[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`: a JWT.
    static func jwt(_ t: Text) { dotted(t, eyJ, parts: 3, minimum: 8) }

    /// `word` as written, not after a name character, then `parts` runs of `[A-Za-z0-9_-]` of at least `minimum`
    /// between dots.
    private static func dotted(_ t: Text, _ word: Word, parts: Int, minimum: Int) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.findExact(word, from: at)
            guard c < n else { return }
            var stop = 0, firstRun = c + 1
            if c == 0 || !isWordChar(u[c - 1]) {
                var i = c + word.count, part = 0
                while part < parts {
                    let r = runToken(u, n, i)
                    if part == 0 { firstRun = r }
                    guard r - i >= minimum else { break }
                    part += 1
                    if part == parts { stop = r; break }
                    guard r < n && u[r] == 46 else { break }
                    i = r + 1
                }
            }
            // One that failed: any start inside its first run has that run's tail as its first run, and fails too.
            if stop > 0 { t.mask(c, stop); at = stop } else { at = firstRun > c + 1 ? firstRun : c + 1 }
        }
    }

    private static let discord = Word("discord"), app = Word("app"), webhooks = Word(".com/api/webhooks/")

    /// `discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+`: a Discord webhook.
    static func discordWebhook(_ t: Text) {
        let u = t.u, n = t.n
        var at = 0
        while true {
            let c = t.findExact(discord, from: at)
            guard c < n else { return }
            var stop = 0
            var i = c + 7
            if t.same(app, at: i) { i += 3 }
            if t.same(webhooks, at: i) {
                var r = i + 18
                while r < n && isDigit(u[r]) { r += 1 }
                if r > i + 18 && r < n && u[r] == 47 {
                    let e = runToken(u, n, r + 1)
                    if e > r + 1 { stop = e }
                }
            }
            if stop > 0 { t.mask(c, stop); at = stop } else { at = c + 1 }
        }
    }

    // MARK: - Soft-wrapped tokens

    /// A token the terminal soft-wrapped onto the next row (`ghp_AbCd…⏎QrSt…`): neither half looks like a token
    /// on its own. A row as wide as the widest row is taken to continue on the next one; a token shape found
    /// across that line end is masked in both rows.
    static func maskWrapped(_ t: Text) {
        let u = t.u, n = t.n
        var rows = 1, i = 0
        while i < n { if u[i] == 10 { rows += 1 }; i += 1 }
        guard rows > 1 else { return }
        // Where each row starts (and one past the end, so a row's length is starts[r + 1] - 1 - starts[r]).
        let starts = UnsafeMutablePointer<Int>.allocate(capacity: rows + 1)
        defer { starts.deallocate() }
        starts[0] = 0
        var row = 1, width = 0
        i = 0
        while i < n {
            if u[i] == 10 {
                if i - starts[row - 1] > width { width = i - starts[row - 1] }
                starts[row] = i + 1
                row += 1
            }
            i += 1
        }
        starts[rows] = n + 1
        if n - starts[rows - 1] > width { width = n - starts[rows - 1] }
        guard width >= 16 else { return }

        // Runs of rows where every row but the last is full: one line the terminal wrapped. All of them joined
        // into one text, a newline after each (no token shape crosses one), searched once per shape.
        let runs = Ints(), positions = Ints()   // per run: its first row and its offset in `joined`
        var length = 0, first = 0
        while first < rows {
            var last = first
            while last + 1 < rows && starts[last + 1] - 1 - starts[last] == width { last += 1 }
            if last > first {
                runs.add(first)
                runs.add(last)
                positions.add(length)
                length += starts[last + 1] - 1 - starts[first] - (last - first) + 1
            }
            first = last + 1
        }
        guard runs.count > 0 else { return }
        let joined = Text(count: length) { out in
            var k = 0, at = 0
            while k < runs.count {
                var r = runs[k]
                while r <= runs[k + 1] {
                    let rowLength = starts[r + 1] - 1 - starts[r]
                    (out + at).update(from: u + starts[r], count: rowLength)
                    at += rowLength
                    r += 1
                }
                out[at] = 10
                at += 1
                k += 2
            }
        }
        // Each found shape's part in each row it spans, in the text's offsets, as location << 32 | length.
        let pieces = Ints()
        for shape in shapes {
            shape.apply(joined)
            var k = 0, run = 0
            while k < joined.masks {
                let (start, end) = joined.maskRange(k)
                k += 1
                while run + 1 < positions.count && positions[run + 1] <= start { run += 1 }
                let base = positions[run], firstRow = runs[2 * run], rowsInRun = runs[2 * run + 1] - firstRow + 1
                let s = start - base, e = end - base
                let r0 = min(s / width, rowsInRun - 1), r1 = min((e - 1) / width, rowsInRun - 1)
                guard r0 != r1 else { continue }
                var w = r0
                while w <= r1 {
                    let a = max(s, w * width), b = w == rowsInRun - 1 ? e : min(e, (w + 1) * width)
                    pieces.add((starts[firstRow + w] + a - w * width) << 32 | (b - a))
                    w += 1
                }
            }
            joined.discardMasks()
        }
        pieces.sort()
        var at = 0, k = 0
        while k < pieces.count {
            let location = pieces[k] >> 32, stop = location + (pieces[k] & 0xFFFF_FFFF)
            if stop > at { t.mask(location > at ? location : at, stop); at = stop }
            k += 1
        }
    }

    // MARK: - Characters

    /// `\s+` from `i`: where it ends.
    private static func skipSpace(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var j = i
        while j < n && isSpace(u[j]) { j += 1 }
        return j
    }

    /// `[A-Za-z0-9_-]+`
    private static func runToken(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var j = i
        while j < n && (isAlnum(u[j]) || u[j] == 95 || u[j] == 45) { j += 1 }
        return j
    }

    /// `[A-Za-z0-9]+`
    private static func runAlnum(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var j = i
        while j < n && isAlnum(u[j]) { j += 1 }
        return j
    }

    /// `[A-Za-z0-9_]+`
    private static func runWordChars(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var j = i
        while j < n && isWordChar(u[j]) { j += 1 }
        return j
    }

    /// `[0-9A-Z]+`
    private static func runUpperDigit(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var j = i
        while j < n && (isUpper(u[j]) || isDigit(u[j])) { j += 1 }
        return j
    }

    /// `[A-Za-z0-9/_-]+`
    private static func runSlackPath(_ u: UnsafeMutablePointer<UInt16>, _ n: Int, _ i: Int) -> Int {
        var j = i
        while j < n && (isAlnum(u[j]) || u[j] == 47 || u[j] == 95 || u[j] == 45) { j += 1 }
        return j
    }

    /// `\b` right after a word character: what follows isn't a word character (for ICU: a letter, mark, digit or
    /// connector), nor a format character or combining mark, which it reads past.
    private static func boundary(_ t: Text, _ i: Int) -> Bool {
        guard i < t.n else { return true }
        let c = t.u[i]
        if c < 128 { return !isWordChar(c) }
        var value = UInt32(c)
        if UTF16.isLeadSurrogate(c), i + 1 < t.n, UTF16.isTrailSurrogate(t.u[i + 1]) {
            value = 0x10000 + ((value - 0xD800) << 10) + (UInt32(t.u[i + 1]) - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { return true }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation, .format: return false
        default: return !(properties.isAlphabetic || properties.isGraphemeExtend || value == 0x200C || value == 0x200D)
        }
    }

    /// The lowercased text as UTF-8, to check quickly which rules can match. Masking only takes text away,
    /// so what the original lacks no step can add.
    private final class Folded {
        let bytes: Data
        /// Per ASCII character: not looked for yet (-1), absent (0), present (1).
        private var characters = [Int8](repeating: -1, count: 128)

        init(_ text: String) { bytes = (text as NSString).lowercased.data(using: .utf8) ?? Data() }

        func allows(_ words: [String]) -> Bool { words.isEmpty || words.contains(where: contains) }

        /// Each of the word's characters first (`memchr` is quick), then the word: with `Data`'s search, not
        /// `memmem`, which stops at every first letter (1 ms in 200 KB of `a` for "api").
        private func contains(_ word: String) -> Bool {
            for byte in word.utf8 where byte < 128 {
                let i = Int(byte)
                if characters[i] < 0 {
                    characters[i] = bytes.withUnsafeBytes { memchr($0.baseAddress, Int32(byte), $0.count) != nil } ? 1 : 0
                }
                if characters[i] == 0 { return false }
            }
            return bytes.range(of: Data(word.utf8)) != nil
        }
    }
}

// Character classes on UTF-16 units (or the folded copy, for those written as `(?i)`), as comparisons: integer
// conversions and tables are slow in unoptimised builds.

/// ICU's `\s`: Unicode White_Space.
private func isSpace(_ c: UInt16) -> Bool {
    if c < 128 { return c == 32 || (c &- 9) < 5 }
    return c == 0x85 || c == 0xA0 || c == 0x1680 || (c &- 0x2000) < 11 || c == 0x2028 || c == 0x2029 || c == 0x202F
        || c == 0x205F || c == 0x3000
}

/// What `.` doesn't match: the line terminators.
private func isLineEnd(_ c: UInt16) -> Bool { (c &- 10) < 4 || c == 0x85 || c == 0x2028 || c == 0x2029 }
private func isDigit(_ c: UInt16) -> Bool { (c &- 48) < 10 }
private func isUpper(_ c: UInt16) -> Bool { (c &- 65) < 26 }
private func isLower(_ c: UInt16) -> Bool { (c &- 97) < 26 }
private func isAlnum(_ c: UInt16) -> Bool { (c &- 48) < 10 || ((c | 32) &- 97) < 26 }
private func isWordChar(_ c: UInt16) -> Bool { isAlnum(c) || c == 95 }
private func isQuote(_ c: UInt16) -> Bool { c == 34 || c == 39 }
/// `(?i)[a-z0-9_]`, on the folded copy.
private func isName(_ f: UInt16) -> Bool { (f &- 97) < 26 || (f &- 48) < 10 || f == 95 }

/// A word to look for: as written, and lowercased to search the folded text.
/// A struct of pointers (allocated once, for the rules' static words): passing one costs no reference counting.
struct Word {
    let exact: UnsafeMutablePointer<UInt16>
    let lower: UnsafeMutablePointer<UInt16>
    let count: Int

    init(_ text: String) {
        let units = Array(text.utf16)
        count = units.count
        exact = .allocate(capacity: count)
        lower = .allocate(capacity: count)
        for (i, c) in units.enumerated() {
            exact[i] = c
            lower[i] = (c &- 65) < 26 ? c | 32 : c
        }
    }
}

/// The text being masked, as UTF-16 (`u`), and a copy to search (`f`): ASCII letters lowercased, ſ and K (Kelvin)
/// as s and k (what `(?i)` matches them to), anything else outside ASCII as 0x80. Same length, same offsets.
/// A rule notes what to mask (`mask`); `applyMasks` then rebuilds the text once, front to back.
final class Text {
    private(set) var u: UnsafeMutablePointer<UInt16>
    private(set) var f: UnsafeMutablePointer<UInt16>
    private(set) var n: Int
    /// `f`'s bytes (not a copy).
    private var bytes: Data
    private var from: UnsafeMutablePointer<Int>, to: UnsafeMutablePointer<Int>, then: UnsafeMutablePointer<UInt16>
    private(set) var masks = 0
    private var room = 64

    convenience init(_ string: String) {
        let ns = string as NSString
        self.init(count: ns.length) { ns.getCharacters($0, range: NSRange(location: 0, length: ns.length)) }
    }

    init(count: Int, fill: (UnsafeMutablePointer<UInt16>) -> Void) {
        let units = UnsafeMutablePointer<UInt16>.allocate(capacity: count + 1)
        let folded = UnsafeMutablePointer<UInt16>.allocate(capacity: count + 1)
        fill(units)
        var i = 0
        while i < count {
            let c = units[i]
            folded[i] = c < 128 ? ((c &- 65) < 26 ? c | 32 : c) : (c == 0x17F ? 115 : (c == 0x212A ? 107 : 0x80))
            i += 1
        }
        u = units
        f = folded
        n = count
        bytes = Data(bytesNoCopy: folded, count: count * 2, deallocator: .none)
        from = .allocate(capacity: room)
        to = .allocate(capacity: room)
        then = .allocate(capacity: room)
    }

    deinit {
        u.deallocate()
        f.deallocate()
        from.deallocate()
        to.deallocate()
        then.deallocate()
    }

    func string(from start: Int) -> String { String(utf16CodeUnits: u + start, count: n - start) }

    /// Where `word` is next, at or after `start`, in any case (`n` if nowhere). The folded copy's units are all
    /// below 0x100, so a byte search can't match across two of them. `memmem` for the next few characters (it's
    /// cheap to call); `Data`'s search beyond, as `memmem` stops at every first letter on the way.
    func find(_ word: Word, from start: Int) -> Int {
        guard start >= 0, n - start >= word.count else { return n }
        let window = n - start < 64 + word.count ? n - start : 64 + word.count
        if let hit = memmem(f + start, window * 2, word.lower, word.count * 2) {
            return (UnsafeRawPointer(hit) - UnsafeRawPointer(f)) / 2
        }
        guard n - start > window,
              let found = bytes.range(of: Data(bytesNoCopy: word.lower, count: word.count * 2, deallocator: .none), in: (start + window - word.count + 1) * 2 ..< n * 2) else { return n }
        return found.lowerBound / 2
    }

    /// Where `word` is next, at or after `start`, exactly as written.
    func findExact(_ word: Word, from start: Int) -> Int {
        var at = start
        while true {
            let i = find(word, from: at)
            if i == n || same(word, at: i) { return i }
            at = i + 1
        }
    }

    /// Whether `word` is at `i`, in any case.
    func has(_ word: Word, at i: Int) -> Bool {
        i >= 0 && n - i >= word.count && memcmp(f + i, word.lower, word.count * 2) == 0
    }

    /// Whether `word` is at `i`, as written.
    func same(_ word: Word, at i: Int) -> Bool {
        i >= 0 && n - i >= word.count && memcmp(u + i, word.exact, word.count * 2) == 0
    }

    /// Mask `start..<end`, then add `quote` if it's not 0. Called front to back, never overlapping.
    func mask(_ start: Int, _ end: Int, then quote: UInt16 = 0) {
        if masks == room {
            room *= 2
            from = Text.grow(from, masks, room)
            to = Text.grow(to, masks, room)
            then = Text.grow(then, masks, room)
        }
        from[masks] = start
        to[masks] = end
        then[masks] = quote
        masks += 1
    }

    func maskRange(_ k: Int) -> (Int, Int) { (from[k], to[k]) }

    func discardMasks() { masks = 0 }

    func applyMasks() {
        guard masks > 0 else { return }
        var length = n, k = 0
        while k < masks {
            length += 3 - (to[k] - from[k]) + (then[k] != 0 ? 1 : 0)
            k += 1
        }
        let units = UnsafeMutablePointer<UInt16>.allocate(capacity: length + 1)
        let folded = UnsafeMutablePointer<UInt16>.allocate(capacity: length + 1)
        var at = 0, out = 0
        k = 0
        while k < masks {
            let gap = from[k] - at
            if gap > 0 {
                memcpy(units + out, u + at, gap * 2)
                memcpy(folded + out, f + at, gap * 2)
                out += gap
            }
            var dot = 0
            while dot < 3 { units[out] = 0x2022; folded[out] = 0x80; out += 1; dot += 1 }
            if then[k] != 0 { units[out] = then[k]; folded[out] = then[k]; out += 1 }
            at = to[k]
            k += 1
        }
        memcpy(units + out, u + at, (n - at) * 2)
        memcpy(folded + out, f + at, (n - at) * 2)
        bytes = Data(bytesNoCopy: folded, count: length * 2, deallocator: .none)
        u.deallocate()
        f.deallocate()
        u = units
        f = folded
        n = length
        masks = 0
    }

    private static func grow<T>(_ old: UnsafeMutablePointer<T>, _ count: Int, _ room: Int) -> UnsafeMutablePointer<T> {
        let new = UnsafeMutablePointer<T>.allocate(capacity: room)
        new.update(from: old, count: count)
        old.deallocate()
        return new
    }
}

/// The places of several words in a text (in any case), in order, each looked up again only once passed.
final class Hits {
    private let t: Text
    private let words: [Word]
    private let next: UnsafeMutablePointer<Int>
    private let count: Int

    init(_ t: Text, _ words: [Word]) {
        self.t = t
        self.words = words
        count = words.count
        next = .allocate(capacity: count)
        var k = 0
        while k < count { next[k] = -1; k += 1 }
    }

    deinit { next.deallocate() }

    /// The first place at or after `start` one of the words is (`t.n` if none).
    func first(from start: Int) -> (at: Int, word: Int) {
        var best = t.n, which = -1, k = 0
        while k < count {
            if next[k] < start { next[k] = t.find(words[k], from: start) }
            if next[k] < best { best = next[k]; which = k }
            k += 1
        }
        return (best, which)
    }
}

/// A growable list of integers.
final class Ints {
    private var items = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    private var room = 64
    private(set) var count = 0

    deinit { items.deallocate() }

    subscript(i: Int) -> Int { items[i] }

    func add(_ value: Int) {
        if count == room {
            let new = UnsafeMutablePointer<Int>.allocate(capacity: room * 2)
            new.update(from: items, count: count)
            items.deallocate()
            items = new
            room *= 2
        }
        items[count] = value
        count += 1
    }

    /// Ascending (heapsort: no recursion, no generic code).
    func sort() {
        var end = count
        var i = count / 2 - 1
        while i >= 0 { siftDown(i, end); i -= 1 }
        while end > 1 {
            end -= 1
            let top = items[0]
            items[0] = items[end]
            items[end] = top
            siftDown(0, end)
        }
    }

    private func siftDown(_ start: Int, _ end: Int) {
        var root = start
        while 2 * root + 1 < end {
            var child = 2 * root + 1
            if child + 1 < end && items[child] < items[child + 1] { child += 1 }
            guard items[root] < items[child] else { return }
            let swap = items[root]
            items[root] = items[child]
            items[child] = swap
            root = child
        }
    }
}
