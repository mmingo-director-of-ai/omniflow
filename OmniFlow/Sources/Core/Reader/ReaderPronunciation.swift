import Foundation

/// Rewrites a sentence into what a listener expects to hear: acronyms as words
/// or letters, links shortened, numbers, versions and identifiers read
/// naturally. Only the text sent to the voice changes; positions use the
/// original. Natural by default; the user's dictation replacements override.
struct ReaderPronunciation: Sendable {
    /// Acronym → spoken form, from the user's replacement rules (for example
    /// "sim" → "SIEM" means SIEM is read "sim").
    var overrides: [String: String] = [:]

    init(overrides: [String: String] = [:]) { self.overrides = overrides }

    /// Dictation replacements whose written side is an acronym tell the reader
    /// how the user says it. Other replacements map mishearings and are ignored.
    init(vocabulary: DictationVocabulary) {
        var overrides: [String: String] = [:]
        for rule in vocabulary.replacements + vocabulary.learnedReplacements {
            let written = rule.to.trimmingCharacters(in: .whitespaces), said = rule.from.trimmingCharacters(in: .whitespaces)
            guard written.range(of: #"^[A-Z][A-Z0-9&]{1,9}$"#, options: .regularExpression) != nil,
                  said.range(of: #"^[A-Za-z][A-Za-z' -]{0,40}$"#, options: .regularExpression) != nil,
                  said.lowercased() != written.lowercased(), overrides[written] == nil else { continue }
            overrides[written] = said
        }
        self.overrides = overrides
    }

    func spoken(_ sentence: String) -> String {
        var text = sentence
        text = Self.replace(text, #"\b(?:https?://|www\.)[^\s<>"')\]]+[^\s<>"')\].,;:!?]"#) { match in
            let host = Self.host(of: match[0])
            return host.isEmpty ? "a link" : "a link to \(Self.dotted(host))"
        }
        text = Self.replace(text, #"\b[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})\b"#) { "an email address at \(Self.dotted($0[1]))" }
        text = Self.replace(text, #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#) { _ in "a long identifier" }
        text = Self.replace(text, #"\b(?=[0-9a-fA-F]*[a-fA-F])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{16,}\b"#) { _ in "a long hash" }
        text = Self.replace(text, #"\b0[xX]([0-9a-fA-F]+)\b"#) { m in
            m[1].count > 8 ? "a hex value" : "hex " + m[1].uppercased().map(String.init).joined(separator: " ")
        }
        text = Self.replace(text, #"\b(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?\b"#) { m in
            m[1].replacingOccurrences(of: ".", with: " dot ") + (m[2].isEmpty ? "" : " slash \(m[2])")
        }
        text = Self.replace(text, #"\bv(\d+(?:\.\d+)*)\b"#) { "version " + $0[1].replacingOccurrences(of: ".", with: " point ") }
        text = Self.replace(text, #"\b(\d+\.\d+\.\d+(?:\.\d+)*)\b"#) { $0[1].replacingOccurrences(of: ".", with: " point ") }
        text = Self.replace(text, #"\bpp?\.\s?(\d+)\s?[–-]\s?(\d+)"#) { "pages \($0[1]) to \($0[2])" }
        text = Self.replace(text, #"\b(\d+)\s?–\s?(\d+)\b"#) { "\($0[1]) to \($0[2])" }
        text = Self.replace(text, #"(\d)\s?(ms|µs|ns|KB|MB|GB|TB|KiB|MiB|GiB|TiB|Kbps|Mbps|Gbps|GHz|MHz|kHz|Hz)\b"#) { m in
            "\(m[1]) \(Self.units[m[2]] ?? m[2])"
        }
        text = Self.replace(text, #"\b(Chapter|Part|Book|Volume|Appendix|Section|Act|Phase|Stage|Level|Article)\s+([IVXLC]+)\b"#) { m in
            Self.roman(m[2]).map { "\(m[1]) \($0)" } ?? m[0]
        }
        text = Self.replace(text, #"\bWorld War\s+(I{1,3})\b"#) { m in Self.roman(m[1]).map { "World War \(Self.cardinals[$0] ?? String($0))" } ?? m[0] }
        text = Self.replace(text, #"\b(Henry|Louis|Charles|George|Edward|Elizabeth|James|William|Richard|Pope \w+|Pius|Benedict|Gregory|Leo|Peter|Frederick|Philip|Ramesses|Napoleon|Catherine|Mary|Alexander|Constantine|Nicholas)\s+([IVX]{1,5})\b"#) { m in
            Self.roman(m[2]).flatMap { Self.ordinals[$0] }.map { "\(m[1]) the \($0)" } ?? m[0]
        }
        text = Self.replace(text, #"(?<![\w.])e\.g\.(?=\s|,)"#) { _ in "for example" }
        text = Self.replace(text, #"(?<![\w.])i\.e\.(?=\s|,)"#) { _ in "that is" }
        text = Self.replace(text, #"(?<![\w.])vs\.(?=\s)"#) { _ in "versus" }
        text = Self.replace(text, #"(?<![\w/.~])((?:/[\w.-]+){1,8})/?(?![\w/])"#) { m in
            let parts = m[1].split(separator: "/").map(String.init)
            return parts.count <= 3 ? "slash " + parts.joined(separator: " slash ") : "a file path ending in \(parts.last!)"
        }
        text = Self.replace(text, #"(?<![\w-])--([a-z][a-z0-9-]+)"#) { "dash dash \($0[1])" }
        text = Self.replace(text, #"\b([A-Za-z]\w*)\(\)"#) { $0[1] }
        text = Self.replace(text, #"\b([a-z0-9]+(?:_[a-zA-Z0-9]+)+)\b"#) { $0[1].replacingOccurrences(of: "_", with: " ") }
        text = Self.replace(text, #"\b([a-z]+[a-z0-9]*(?:[A-Z][a-z0-9]+)+)\b"#) { m in
            m[1].replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
        let mostlyCaps = Self.mostlyCaps(sentence)
        text = Self.replace(text, #"\b([A-Z][A-Za-z0-9&]*[A-Z0-9][A-Z0-9&]*)(s|'s)?\b"#) { m in
            guard let reading = reading(m[1], mostlyCaps: mostlyCaps) else { return m[0] }
            return reading + (m[2].isEmpty ? "" : (m[2] == "s" && reading.hasSuffix(" ") == false && Self.isLetters(reading) ? "'s" : m[2]))
        }
        return text.replacingOccurrences(of: "  ", with: " ")
    }

    /// How to say one all-caps token, or nil to leave it as written.
    func reading(_ token: String, mostlyCaps: Bool = false) -> String? {
        if let said = overrides[token] { return said }
        if let word = Self.words[token] { return word }
        guard token.count >= 2, token == token.uppercased() else { return nil }
        if Self.letterAcronyms.contains(token) { return Self.letters(token) }
        // A heading or label set in capitals: read its words as words.
        if mostlyCaps || Self.shoutedWords.contains(token) { return token.contains(where: \.isNumber) ? Self.letters(token) : token.lowercased() }
        if token.contains(where: \.isNumber) { return Self.letters(token) }
        // A bare Roman numeral ("Part II" is handled earlier): leave it to the voice.
        if Self.roman(token) != nil { return nil }
        if token.count <= 3 { return Self.letters(token) }
        return Self.pronounceable(token) ? token.prefix(1) + token.dropFirst().lowercased() : Self.letters(token)
    }

    // MARK: - Lexicon v1 (seeded from the most frequent capitalised terms in a technical library)

    /// Spelled out letter by letter.
    static let letterAcronyms = Set<String>([
        "IP", "API", "TCP", "ID", "HTTP", "HTTPS", "DNS", "CPU", "GPU", "AWS", "URL", "URI", "HTML", "CSS", "OS", "SQL", "SSH", "XML",
        "VM", "DLL", "UDP", "TLS", "SSL", "DHCP", "XSS", "CSRF", "USB", "FTP", "SFTP", "PE", "RFC", "RSA", "CD", "PDF", "PF", "IT",
        "ICMP", "EAX", "EBX", "ECX", "EDX", "ESP", "EBP", "EIP", "RIP", "RAX", "RSP", "SVG", "SNMP", "GUI", "CVE", "AES", "DES", "PID",
        "ARP", "AI", "ML", "BSD", "PC", "NFS", "GDB", "MBR", "IEEE", "US", "UK", "EU", "PHP", "SID", "SDK", "WMI", "ISO", "UEFI", "XP",
        "IAM", "DOM", "DI", "NSM", "ACK", "SYN", "VPN", "MS", "IDS", "IPS", "PPP", "BGP", "IDC", "AST", "IPC", "IOC", "IOCs", "EDR", "XDR",
        "MDR", "TTP", "KQL", "SPL", "EQL", "SOC", "MITRE", "APT", "C2", "LLM", "NLP", "GPT", "CLI", "IDE", "JVM", "JDK", "NPM", "SSO",
        "MFA", "OTP", "LDAP", "AD", "DC", "GPO", "SMB", "RDP", "SMTP", "IMAP", "POP", "MX", "TXT", "CNAME", "SPF", "DKIM", "DMARC",
        "NTP", "VLAN", "LAN", "WAN", "MAC", "NIC", "OSI", "QA", "CI", "CD", "PR", "MR", "UI", "UX", "CMS", "CRM", "ERP", "HR", "CEO",
        "CTO", "CISO", "CFO", "KPI", "ROI", "PII", "PHI", "PCI", "HIPAA", "GDPR", "IAAS", "PAAS", "SAAS", "EC", "RDS", "VPC", "KMS",
        "ECS", "EKS", "SNS", "SQS", "ARN", "CPE", "CVSS", "OWASP", "RCE", "LFI", "RFI", "SSRF", "IDOR", "XXE", "JWT", "SAML", "OIDC",
        "TOTP", "HMAC", "SHA", "MD", "PKI", "CA", "CSR", "CRL", "TPM", "HSM", "BIOS", "ROM", "EPROM", "FPGA", "ASIC", "ARM", "RISC",
        "CISC", "ISA", "ALU", "MMU", "TLB", "DMA", "IRQ", "PCIE", "SATA", "SSD", "HDD", "NVME", "RAID", "LVM", "ZFS", "NTFS", "FAT",
        "EXT", "PE32", "ELF", "COFF", "PDB", "IAT", "EAT", "SEH", "ASLR", "DEP", "NX", "ROP", "JOP", "UAF", "TOCTOU", "IOT", "OT",
        "ICS", "PLC", "HMI", "DCS", "RTU", "CAN", "OBD", "GPS", "RF", "SDR", "BLE", "NFC", "RFID", "WPA", "WEP", "WPS", "AP", "SSID",
        "BSSID", "EAP", "PEAP", "RADIUS", "IPSEC", "IKE", "GRE", "MPLS", "OSPF", "EIGRP", "STP", "VRRP", "HSRP", "QOS", "CDN", "WAF",
        "LB", "HA", "DR", "RPO", "RTO", "SLA", "SLO", "SLI", "OKR", "BI", "ETL", "DB", "DBA", "ORM", "CRUD", "ACID", "CAP", "JS", "TS",
        "VS", "CR", "LF", "CRLF", "EOF", "UTF", "ASN", "BER", "DER", "PEM", "PGP", "GPG", "OTX", "TI", "IR", "DFIR", "EDR", "SIEM",
        "SOAR", "UEBA", "NDR", "DLP", "CASB", "ZTNA", "SASE", "CSPM", "CWPP", "CNAPP", "IAC", "SBOM", "SAST", "DAST", "IAST", "RASP",
        "WSL", "VBA", "VBS", "HTA", "LNK", "MSI", "UAC", "LSA", "LSASS", "SAM", "NTLM", "KDC", "TGT", "TGS", "SPN", "ACL", "ACE",
        "DACL", "SACL", "UNC", "WMIC", "COM", "DCOM", "RPC", "IPv4", "IPv6", "NAT", "PAT", "DMZ", "IDP", "SP", "NIST", "CIS", "SOX",
        "FIPS", "HTTP2", "HTTP3", "QUIC", "MQTT", "AMQP", "REST", "GRPC", "RPCS", "TTL", "MTU", "MSS", "RTT", "BPF", "EBPF", "XDP",
        "PCAP", "IDA", "IDE", "LLVM", "GCC", "CLR", "JIT", "AOT", "GC", "OOP", "FP", "TDD", "BDD", "DDD", "MVC", "MVVM", "SPA", "PWA",
        "SEO", "SMS", "MMS", "VOIP", "SIP", "RTP", "PSTN", "ISP", "OEM", "ODM", "SKU", "FAQ", "TL", "DR", "FYI", "ASAP", "ETA", "AM",
        "PM", "EST", "PST", "UTC", "GMT", "BC", "AD", "TV", "DVD", "CD", "PS", "RGB", "CMYK", "DPI", "PPI", "FPS", "HDR", "LED", "LCD",
        "OLED", "AC", "DC", "UPS", "PSU", "HVAC", "NYC", "LA", "DOJ", "FBI", "CIA", "NSA", "DHS", "DOD", "UN", "WHO", "NHS", "MIT",
        "UCLA", "IBM", "HP", "AMD", "AT&T", "BBC", "CNN", "NBA", "NFL"])

    /// Read as words. The value is a spelling the voice reads correctly.
    static let words = [String: String]([
        ("NASA", "Nasa"), ("SCUBA", "scuba"), ("GNU", "guh-new"), ("UNIX", "Unix"), ("GIMP", "gimp"), ("NULL", "null"), ("ASCII", "ask-ee"),
        ("POSIX", "pozz-icks"), ("BIND", "bind"), ("RAM", "ram"), ("ROM", "rom"), ("ARM", "arm"), ("NAT", "nat"), ("ELF", "elf"), ("JSON", "jay-son"),
        ("YAML", "yamel"), ("YARA", "yara"), ("SOAR", "soar"), ("SIEM", "sim"), ("CAPTCHA", "captcha"), ("SCSI", "scuzzy"), ("XOR", "ex-or"),
        ("CTRL", "control"), ("ALT", "alt"), ("ESC", "escape"), ("DEL", "delete"), ("BIOS", "bye-oss"), ("NIST", "nist"), ("OWASP", "oh-wasp"),
        ("SCADA", "scada"), ("CRUD", "crud"), ("ACID", "acid"), ("REST", "rest"), ("SOAP", "soap"), ("AJAX", "ajax"), ("WASM", "wazm"),
        ("LASER", "laser"), ("RADAR", "radar"), ("SONAR", "sonar"), ("NATO", "nato"), ("UNESCO", "unesco"), ("FEMA", "fema"), ("OPEC", "opec"),
        ("FIFO", "fife-oh"), ("LIFO", "life-oh"), ("GIF", "gif"), ("JPEG", "jay-peg"), ("PNG", "ping"), ("MIME", "mime"), ("WIFI", "wifi"),
        ("PIN", "pin"), ("SIM", "sim"), ("LAN", "lan"), ("WAN", "wan"), ("SaaS", "sass"), ("SAAS", "sass"), ("PAAS", "pass"), ("IAAS", "eye-ass"),
        ("CAN", "can"), ("SAM", "sam"), ("COM", "com"), ("CAP", "cap"), ("OKR", "O.K.R"), ("MITRE", "miter"), ("RADIUS", "radius"), ("QUIC", "quick"),
        ("LSASS", "el-sass"), ("TOCTOU", "tock-too"), ("DOS", "doss"), ("DDoS", "dee-doss"), ("DDOS", "dee-doss"), ("GUID", "goo-id"),
        ("UUID", "U.U.I.D"), ("SQL", "S.Q.L"), ("OK", "okay"), ("OAUTH", "oh-auth"), ("WEP", "wep"), ("WAF", "waf"), ("PEAP", "peep"),
        ("IPSEC", "I.P sec"), ("IPV4", "I.P v4"), ("IPV6", "I.P v6"), ("IPv4", "I.P v4"), ("IPv6", "I.P v6"), ("SPA", "spa"), ("PWA", "P.W.A"),
        ("VOIP", "voyp"), ("ASAP", "A sap"), ("FAQ", "F.A.Q"), ("IEEE", "I triple E"), ("AT&T", "A.T and T"), ("SHA", "sha"), ("AES", "A.E.S"),
        ("DES", "dez"), ("IDA", "eye-da"), ("UCLA", "U.C.L.A"), ("NYC", "N.Y.C"), ("KQL", "K.Q.L"), ("EBPF", "E.B.P.F"), ("IDOR", "eye-door"),
        ("MAC", "mac"), ("WHO", "W.H.O"), ("LLVM", "L.L.V.M"), ("NVME", "N.V.M.E"), ("PCIE", "P.C.I.E"), ("GRPC", "G.R.P.C"), ("SAML", "sam-el"), ("LDAP", "el-dap"), ("ZIP", "zip"), ("MNIST", "em-nist"), ("UMAP", "you-map"), ("LASSO", "lasso"),
        ("CART", "cart"), ("CRAN", "cran"), ("GAN", "gan"), ("LSTM", "L.S.T.M"), ("BERT", "bert"), ("GLUE", "glue"), ("SQuAD", "squad")], uniquingKeysWith: { first, _ in first })

    /// Common English words often set in capitals for emphasis or as labels.
    static let shoutedWords = Set<String>([
        "A", "AN", "AND", "OR", "NOT", "THE", "OF", "TO", "IN", "ON", "AT", "BY", "FOR", "WITH", "FROM", "INTO", "IS", "ARE", "WAS",
        "BE", "IF", "THEN", "ELSE", "WHEN", "WHERE", "WHILE", "DO", "DONE", "SO", "NO", "YES", "ALL", "ANY", "EVERY", "EACH", "NONE",
        "NOTE", "NOTES", "TIP", "TIPS", "WARNING", "CAUTION", "IMPORTANT", "DANGER", "KEY", "KEYS", "GET", "POST", "PUT", "PATCH",
        "DELETE", "HEAD", "OPTIONS", "SELECT", "INSERT", "UPDATE", "CREATE", "DROP", "TABLE", "JOIN", "LEFT", "RIGHT", "INNER",
        "OUTER", "GROUP", "ORDER", "LIMIT", "UNION", "VALUES", "SET", "TRUE", "FALSE", "NEW", "FREE", "NOW", "ONE", "TWO", "THREE",
        "FOUR", "FIVE", "TEN", "STOP", "START", "END", "BEGIN", "RETURN", "EXIT", "HELP", "READ", "WRITE", "EXECUTE", "RUN", "OPEN",
        "CLOSE", "SAVE", "LOAD", "MOVE", "COPY", "PASTE", "CUT", "UNDO", "REDO", "ENTER", "SPACE", "TAB", "SHIFT", "HOME", "PAGE",
        "UP", "DOWN", "BACK", "NEXT", "LAST", "FIRST", "STEP", "PART", "CHAPTER", "SECTION", "FIGURE", "EXAMPLE", "LISTING",
        "EXERCISE", "SUMMARY", "INTRODUCTION", "CONCLUSION", "PREFACE", "FOREWORD", "CONTENTS", "INDEX", "APPENDIX", "THIS", "THAT",
        "IT", "WE", "YOU", "THEY", "HE", "SHE", "MY", "YOUR", "OUR", "THEIR", "WHAT", "WHY", "HOW", "WHO", "VERY", "MUST", "SHALL",
        "SHOULD", "MAY", "MIGHT", "CAN", "WILL", "WOULD", "NEVER", "ALWAYS", "ONLY", "NOTHING", "EVERYTHING", "SOMETHING", "BUT",
        "TOTAL", "ERROR", "FAIL", "FAILED", "PASS", "PASSED", "SUCCESS", "WARN", "INFO", "DEBUG", "TRACE", "FATAL", "CRITICAL",
        "HIGH", "LOW", "MEDIUM", "ROOT", "ADMIN", "USER", "GUEST", "SYSTEM", "LOCAL", "GLOBAL", "PUBLIC", "PRIVATE", "STATIC",
        "CONST", "VOID", "INT", "CHAR", "LONG", "SHORT", "FLOAT", "DOUBLE", "STRING", "BOOL", "NULL", "TODO", "FIXME", "README",
        "LICENSE", "MAIN", "MASTER", "EOF"])

    // MARK: - Helpers

    static let units: [String: String] = ["ms": "milliseconds", "µs": "microseconds", "ns": "nanoseconds", "KB": "kilobytes",
        "MB": "megabytes", "GB": "gigabytes", "TB": "terabytes", "KiB": "kibibytes", "MiB": "mebibytes", "GiB": "gibibytes",
        "TiB": "tebibytes", "Kbps": "kilobits per second", "Mbps": "megabits per second", "Gbps": "gigabits per second",
        "GHz": "gigahertz", "MHz": "megahertz", "kHz": "kilohertz", "Hz": "hertz"]
    static let cardinals: [Int: String] = [1: "One", 2: "Two", 3: "Three"]
    static let ordinals: [Int: String] = [1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth", 6: "Sixth", 7: "Seventh",
        8: "Eighth", 9: "Ninth", 10: "Tenth", 11: "Eleventh", 12: "Twelfth", 13: "Thirteenth", 14: "Fourteenth", 15: "Fifteenth",
        16: "Sixteenth", 17: "Seventeenth", 18: "Eighteenth", 19: "Nineteenth", 20: "Twentieth", 21: "Twenty-first",
        22: "Twenty-second", 23: "Twenty-third"]

    static func roman(_ numeral: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0, previous = 0
        for c in numeral.reversed() {
            guard let v = values[c] else { return nil }
            if v < previous { total -= v } else { total += v; previous = v }
        }
        // Reject non-canonical forms such as "IIII" or "VX".
        return total > 0 && total < 400 && canonicalRoman(total) == numeral ? total : nil
    }

    private static func canonicalRoman(_ value: Int) -> String {
        let table: [(Int, String)] = [(100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = value, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out
    }

    /// Letters joined by dots ("I.O.C"), digits apart ("M.D 5"): on-device
    /// transcription of the voice shows dotted capitals spelled out, where
    /// spaced ones are sometimes read as words ("I A M" as "I am").
    static func letters(_ token: String) -> String {
        var parts: [String] = []
        var run = "", digits = ""
        for c in token where c != "&" {
            if c.isNumber {
                if !run.isEmpty { parts.append(run); run = "" }
                digits.append(c)
            } else {
                if !digits.isEmpty { parts.append(digits); digits = "" }
                run += run.isEmpty ? String(c).uppercased() : "." + String(c).uppercased()
            }
        }
        if !run.isEmpty { parts.append(run) }
        if !digits.isEmpty { parts.append(digits) }
        return parts.joined(separator: " ")
    }

    static func isLetters(_ reading: String) -> Bool {
        reading.split(separator: " ").allSatisfy { part in
            part.allSatisfy(\.isNumber) || part.split(separator: ".").allSatisfy { $0.count == 1 && $0.first!.isUppercase }
        } && reading.contains(where: \.isLetter)
    }

    /// A rough English phonotactics test: vowels present, no impossible
    /// consonant clusters at the start, no long consonant runs.
    static func pronounceable(_ token: String) -> Bool {
        let word = token.lowercased()
        let vowels = Set("aeiouy")
        let letters = Array(word)
        guard letters.allSatisfy(\.isLetter), letters.contains(where: { vowels.contains($0) }) else { return false }
        let onsets: Set<String> = ["bl", "br", "cl", "cr", "dr", "fl", "fr", "gl", "gr", "pl", "pr", "sc", "sk", "sl", "sm", "sn",
                                   "sp", "st", "sw", "tr", "tw", "th", "sh", "ch", "wh", "ph", "qu", "wr", "kn", "gn"]
        if letters.count >= 2, !vowels.contains(letters[0]), !vowels.contains(letters[1]), !onsets.contains(String(letters[0...1])) { return false }
        var run = 0
        for c in letters {
            run = vowels.contains(c) ? 0 : run + 1
            if run >= 3 { return false }
        }
        if vowels.contains(letters[0]) && letters.count >= 2 && vowels.contains(letters[1]) && letters[0] != letters[1] && "ae ai au ea ee ei eu ie oa oe oi oo ou ue".contains(String(letters[0...1])) == false { return false }
        let vowelCount = letters.filter { vowels.contains($0) }.count
        return Double(vowelCount) / Double(letters.count) >= 0.25
    }

    static func mostlyCaps(_ sentence: String) -> Bool {
        let words: [Substring] = sentence.split(whereSeparator: { !$0.isLetter }).filter { $0.count > 1 }
        guard words.count >= 3 else { return false }
        return Double(words.filter { $0 == $0.uppercased() }.count) / Double(words.count) > 0.6
    }

    static func host(of url: String) -> String {
        var rest = url
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        var host = String(rest.split(whereSeparator: { "/?#:".contains($0) }).first ?? "")
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.lowercased()
    }

    static func dotted(_ host: String) -> String { host.replacingOccurrences(of: ".", with: " dot ") }

    /// Regex replacement with capture groups (missing groups are "").
    static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
