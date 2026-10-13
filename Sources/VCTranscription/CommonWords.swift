import Foundation

/// Ordinary English words that vocabulary correction must never rewrite into a name or term.
///
/// The macOS system dictionary (`/usr/share/dict/words`, Webster's 2nd) supplies the long tail: its
/// lower-case entries are common nouns, verbs and so on, while proper nouns are capitalised there. It
/// predates modern vocabulary, so frequent everyday and technology words it lacks are listed here too.
enum CommonWords {
    /// True for dictionary words and their regular inflections ("meetings", "walked", "cities", "running").
    static func contains(_ word: String) -> Bool {
        let key = word.lowercased()
        return isListed(key) || stems(of: key).contains(where: isListed)
    }

    private static func isListed(_ word: String) -> Bool {
        modern.contains(word) || system.contains(word)
    }

    /// Candidate base forms under regular English inflection: plurals and 3rd person (-s, -es, -ies),
    /// past (-ed, -ied, doubled consonant), -ing, comparatives (-er, -est, -ier), -ly and agent -ers.
    static func stems(of word: String) -> [String] {
        var stems: [String] = []
        func strip(_ suffix: String, _ replacements: [String] = [""]) {
            guard word.hasSuffix(suffix), word.count > suffix.count + 2 else { return }
            let base = String(word.dropLast(suffix.count))
            for replacement in replacements { stems.append(base + replacement) }
            // Doubled final consonant: "stopped" → "stop", "running" → "run", "bigger" → "big".
            if let last = base.last, base.count >= 3, base.dropLast().last == last, !"aeiouls".contains(last) {
                stems.append(String(base.dropLast()))
            }
        }
        strip("ies", ["y"])
        strip("ied", ["y"])
        strip("ier", ["y"])
        strip("iest", ["y"])
        strip("es")
        strip("s")
        strip("ed", ["", "e"])
        strip("ing", ["", "e"])
        strip("ers", ["", "e"])
        strip("er", ["", "e"])
        strip("est", ["", "e"])
        strip("ly")
        return stems
    }

    static let systemDictionary = URL(fileURLWithPath: "/usr/share/dict/words")

    /// Lower-case entries of the system word list (loaded on first use, ~210k words).
    private static let system: Set<String> = {
        guard let text = try? String(contentsOf: systemDictionary, encoding: .utf8) else {
            transcriptionLog.error("System word list unavailable at \(systemDictionary.path, privacy: .public); vocabulary correction relies on the built-in list")
            return []
        }
        var words = Set<String>()
        words.reserveCapacity(220_000)
        for line in text.split(separator: "\n") where line.first?.isLowercase == true {
            words.insert(String(line))
        }
        return words
    }()

    /// Frequent words missing from Webster's 2nd: function words and contractions as engines write them,
    /// inflections, and post-1934 everyday, business and technology vocabulary.
    static let modern: Set<String> = [
        "a", "i", "im", "ive", "id", "ill", "youre", "youve", "youll", "youd", "hes", "shes", "its", "were", "weve",
        "well", "wed", "theyre", "theyve", "theyll", "theyd", "thats", "theres", "heres", "whats", "whos", "wheres",
        "hows", "lets", "dont", "doesnt", "didnt", "cant", "couldnt", "wont", "wouldnt", "shouldnt", "isnt", "arent",
        "wasnt", "werent", "havent", "hasnt", "hadnt", "mustnt", "neednt", "aint", "gonna", "wanna", "gotta", "kinda",
        "sorta", "yeah", "yep", "yes", "no", "nope", "ok", "okay", "hey", "hi", "hello", "bye", "goodbye", "thanks",
        "please", "sorry", "um", "uh", "hmm", "mm", "oh", "ah", "wow", "huh", "alright", "whatever", "anyway",
        "anyways", "everyone", "everybody", "someone", "somebody", "anyone", "anybody", "nobody", "everything",
        "something", "anything", "nothing", "everywhere", "somewhere", "anywhere", "nowhere", "maybe", "today",
        "tomorrow", "yesterday", "tonight", "weekend", "weekday", "online", "offline", "email", "emails", "emailed",
        "website", "websites", "web", "internet", "app", "apps", "laptop", "laptops", "smartphone", "phone", "phones",
        "mobile", "tablet", "computer", "computers", "software", "hardware", "download", "downloads", "upload",
        "uploads", "login", "logout", "password", "passwords", "username", "account", "accounts", "database",
        "server", "servers", "cloud", "data", "dataset", "datasets", "video", "videos", "audio", "podcast", "blog",
        "blogs", "chat", "chats", "text", "texts", "texted", "texting", "call", "calls", "meeting", "meetings",
        "zoom", "teams", "slack", "google", "googled", "facebook", "twitter", "instagram", "linkedin", "youtube",
        "whatsapp", "tiktok", "iphone", "ipad", "mac", "android", "windows", "microsoft", "apple", "amazon",
        "netflix", "uber", "spotify", "bluetooth", "wifi", "usb", "pdf", "api", "apis", "ai", "ml", "it", "hr", "ceo",
        "cfo", "cto", "coo", "vp", "pm", "am", "tv", "uk", "us", "eu", "un", "kpi", "kpis", "roi", "faq", "id", "ids",
        "feedback", "deadline", "deadlines", "roadmap", "workflow", "workflows", "stakeholder", "stakeholders",
        "onboarding", "offboarding", "teammate", "teammates", "standup", "standups", "agenda", "agendas", "budget",
        "budgets", "forecast", "forecasts", "revenue", "revenues", "invoice", "invoices", "payroll", "startup",
        "startups", "marketing", "branding", "brand", "brands", "customer", "customers", "client", "clients",
        "vendor", "vendors", "partner", "partners", "partnership", "manager", "managers", "management", "team",
        "project", "projects", "product", "products", "service", "services", "strategy", "strategies", "analytics",
        "dashboard", "dashboards", "metric", "metrics", "update", "updates", "updated", "updating", "upgrade",
        "upgrades", "deploy", "deployed", "deployment", "release", "releases", "bug", "bugs", "fix", "fixes",
        "fixed", "test", "tests", "testing", "tested", "review", "reviews", "reviewed", "approve", "approved",
        "approval", "schedule", "scheduled", "scheduling", "reschedule", "rescheduled", "calendar", "slides",
        "spreadsheet", "spreadsheets", "document", "documents", "doc", "docs", "file", "files", "folder", "folders",
        "link", "links", "click", "clicked", "share", "shared", "screen", "screens", "mute", "muted", "unmute",
        "camera", "microphone", "mic", "headphones", "earphones", "transcript", "transcripts", "transcribe",
        "covid", "pandemic", "vaccine", "vaccines", "lockdown", "remote", "hybrid", "office", "offices", "commute",
        "airport", "flight", "flights", "hotel", "hotels", "taxi", "bus", "train", "trains", "station", "car", "cars",
        "kids", "kid", "mum", "mom", "dad", "mummy", "mommy", "daddy", "grandma", "grandpa", "auntie", "uncle",
        "brother", "sister", "cousin", "friend", "friends", "boss", "colleague", "colleagues", "guys", "guy",
        "folks", "people", "person", "children", "child", "family", "families", "home", "house", "school", "college",
        "university", "church", "mosque", "market", "shop", "shops", "store", "stores", "supermarket", "bank",
        "banks", "money", "cash", "dollar", "dollars", "pound", "pounds", "euro", "euros", "cent", "cents", "pence",
        "price", "prices", "cost", "costs", "pay", "paid", "paying", "payment", "payments", "salary", "tax", "taxes",
        "spoon", "spoons", "peas", "slabs", "cheese", "snack", "snake", "frog", "scoop", "bags", "plastic", "toy",
        "fresh", "thick", "blue", "red", "big", "small", "need", "also", "bring", "ask", "things", "these", "those",
        "go", "going", "goes", "gone", "went", "come", "coming", "came", "get", "getting", "got", "gotten", "make",
        "making", "made", "take", "taking", "took", "taken", "know", "knowing", "knew", "known", "think", "thinking",
        "thought", "see", "seeing", "saw", "seen", "look", "looking", "looked", "want", "wanted", "wanting", "give",
        "giving", "gave", "given", "use", "using", "used", "find", "finding", "found", "tell", "telling", "told",
        "work", "working", "worked", "seem", "seemed", "feel", "feeling", "felt", "try", "trying", "tried", "leave",
        "leaving", "left", "put", "putting", "mean", "meaning", "meant", "keep", "keeping", "kept", "let", "letting",
        "begin", "began", "begun", "help", "helping", "helped", "talk", "talking", "talked", "turn", "turned",
        "start", "starting", "started", "show", "showing", "showed", "shown", "hear", "hearing", "heard", "play",
        "playing", "played", "run", "running", "ran", "move", "moving", "moved", "live", "living", "lived",
        "believe", "believed", "happen", "happened", "happening", "write", "writing", "wrote", "written", "sit",
        "sitting", "sat", "stand", "standing", "stood", "lose", "losing", "lost", "meet", "met", "include",
        "included", "including", "continue", "continued", "set", "setting", "learn", "learning", "learned", "learnt",
        "change", "changed", "changing", "lead", "leading", "led", "understand", "understood", "watch", "watching",
        "watched", "follow", "following", "followed", "stop", "stopping", "stopped", "create", "created", "speak",
        "speaking", "spoke", "spoken", "read", "reading", "spend", "spending", "spent", "grow", "growing", "grew",
        "open", "opened", "walk", "walking", "walked", "win", "winning", "won", "offer", "offered", "remember",
        "remembered", "love", "loved", "consider", "considered", "appear", "appeared", "buy", "buying", "bought",
        "wait", "waiting", "waited", "serve", "served", "die", "died", "send", "sending", "sent", "expect",
        "expected", "build", "building", "built", "stay", "stayed", "fall", "fell", "fallen", "cut", "reach",
        "reached", "kill", "killed", "remain", "remained", "suggest", "suggested", "raise", "raised", "pass",
        "passed", "sell", "selling", "sold", "require", "required", "report", "reported", "decide", "decided",
        "pull", "pulled", "good", "great", "nice", "fine", "bad", "better", "best", "worse", "worst", "new", "old",
        "first", "last", "long", "little", "own", "other", "right", "high", "different", "large", "next", "early",
        "young", "important", "few", "public", "same", "able", "very", "really", "actually", "basically",
        "literally", "probably", "definitely", "obviously", "exactly", "just", "still", "already", "always",
        "never", "sometimes", "often", "usually", "again", "too", "quite", "pretty", "super", "so", "then", "now",
        "here", "there", "where", "when", "why", "how", "what", "which", "who", "whom", "whose", "the", "an", "and",
        "or", "but", "if", "because", "since", "while", "although", "though", "unless", "until", "of", "to", "in",
        "on", "at", "by", "for", "with", "about", "from", "into", "onto", "over", "under", "after", "before",
        "between", "through", "during", "without", "within", "against", "among", "around", "up", "down", "out",
        "off", "away", "back", "be", "is", "are", "was", "been", "being", "have", "has", "had", "having", "do", "does",
        "did", "doing", "done", "say", "says", "said", "saying", "can", "could", "will", "would", "shall", "should",
        "may", "might", "must", "he", "she", "we", "they", "you", "me", "him", "her", "us", "them", "my", "your",
        "his", "our", "their", "mine", "yours", "hers", "ours", "theirs", "this", "that", "not", "all", "some",
        "any", "each", "every", "both", "either", "neither", "more", "most", "less", "least", "many", "much",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "hundred", "thousand",
        "million", "billion", "percent", "time", "year", "years", "day", "days", "week", "weeks", "month", "months",
        "hour", "hours", "minute", "minutes", "second", "seconds", "morning", "afternoon", "evening", "night",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "june", "july", "august", "september", "october", "november", "december",
    ]
}
