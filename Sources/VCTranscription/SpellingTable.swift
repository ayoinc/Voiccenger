import Foundation

/// British ↔ American spellings of common words, inflections expanded. Pairs whose American form is also a
/// different British word ("tire", "check", "program", "meter", "story", "practice", "license", "draft",
/// "curb", "disk") convert only British → American.
enum SpellingTable {
    /// british → american
    static let toAmerican: [String: String] = Dictionary(
        pairs.map { ($0.british, $0.american) }, uniquingKeysWith: { first, _ in first })
    /// american → british
    static let toBritish: [String: String] = Dictionary(
        pairs.filter(\.reversible).map { ($0.american, $0.british) }, uniquingKeysWith: { first, _ in first })

    struct Pair {
        let british: String
        let american: String
        let reversible: Bool
    }

    static let pairs: [Pair] = {
        var pairs: [Pair] = []
        func add(_ british: String, _ american: String, reversible: Bool = true) {
            pairs.append(Pair(british: british, american: american, reversible: reversible))
        }
        // -our / -or. Suffixes after which both spellings keep the u-difference ("humorous" has none in either).
        let ourSuffixes = [
            "", "s", "ed", "ing", "ings", "er", "ers", "ful", "fully", "less", "able", "ably", "ite", "ites", "ist",
            "ists", "ism", "al", "ally", "hood", "hoods", "ly", "y",
        ]
        for stem in ourStems {
            for suffix in ourSuffixes { add(stem + "our" + suffix, stem + "or" + suffix) }
        }
        // -ise / -ize
        let iseEndings = [
            ("ise", "ize"), ("ises", "izes"), ("ised", "ized"), ("ising", "izing"), ("isation", "ization"),
            ("isations", "izations"), ("iser", "izer"), ("isers", "izers"),
        ]
        for stem in iseStems {
            for (b, a) in iseEndings { add(stem + b, stem + a) }
        }
        // -yse / -yze
        for stem in yseStems {
            for (b, a) in [("yse", "yze"), ("yses", "yzes"), ("ysed", "yzed"), ("ysing", "yzing"), ("yser", "yzer")] {
                add(stem + b, stem + a)
            }
        }
        // -re / -er
        for stem in reStems {
            for (b, a) in [("re", "er"), ("res", "ers"), ("red", "ered"), ("ring", "ering")] { add(stem + b, stem + a) }
        }
        // -ogue / -og: American English mostly keeps -ogue except in these three.
        for stem in ["catal", "anal", "dial"] {
            for (b, a) in [("ogue", "og"), ("ogues", "ogs"), ("ogued", "oged"), ("oguing", "oging")] {
                add(stem + b, stem + a)
            }
        }
        for word in ["prologue", "epilogue", "monologue", "homologue", "pedagogue", "demagogue"] {
            let stem = String(word.dropLast(3))
            add(word, stem, reversible: false)
            add(word + "s", stem + "s", reversible: false)
        }
        // Doubled l: British doubles a final single l before -ed, -ing, -er.
        for stem in doubledLStems {
            for suffix in ["ed", "ing", "er", "ers"] { add(stem + "l" + suffix, stem + suffix) }
        }
        for (b, a) in specific { add(b, a) }
        for (b, a) in britishToAmericanOnly { add(b, a, reversible: false) }
        return pairs
    }()

    private static let ourStems = [
        "col", "flav", "hon", "hum", "lab", "neighb", "rum", "fav", "behavi", "harb", "vap", "sav", "od", "arm",
        "clam", "endeav", "parl", "rig", "splend", "tum", "val", "vig", "cand", "demean", "ferv", "succ", "ard",
        "arb", "dishon", "discol", "misbehavi", "disfav",
    ]

    private static let iseStems = [
        "accessor", "agon", "anonym", "apolog", "author", "brutal", "canon", "capital", "carbon", "categor",
        "cauter", "central", "character", "civil", "colon", "commercial", "computer", "contextual", "critic",
        "crystall", "custom", "decentral", "democrat", "demoral", "deodor", "desensit", "digit", "dramat", "econom",
        "emotional", "empath", "emphas", "energ", "equal", "eulog", "evangel", "external", "familiar", "fantas",
        "fertil", "final", "formal", "fossil", "galvan", "general", "global", "harmon", "homogen", "hospital",
        "human", "hypnot", "ideal", "idol", "immun", "industrial", "initial", "institutional", "internal", "italic",
        "item", "jeopard", "legal", "legitim", "liberal", "local", "magnet", "marginal", "material", "maxim",
        "mechan", "memor", "mesmer", "metabol", "miniatur", "minim", "mobil", "modern", "moistur", "monet",
        "monopol", "moral", "motor", "national", "natural", "neutral", "normal", "optim", "organ", "ostrac", "oxid",
        "parallel", "pasteur", "patron", "penal", "personal", "philosoph", "plagiar", "polar", "politic", "popular",
        "pressur", "priorit", "privat", "proselyt", "public", "pulver", "radical", "random", "rational", "real",
        "recogn", "regular", "reorgan", "revital", "revolution", "sanit", "satir", "scrutin", "secular", "sensit",
        "serial", "social", "solemn", "special", "stabil", "standard", "steril", "stigmat", "subsid", "summar",
        "symbol", "sympath", "synchron", "systemat", "tantal", "terror", "theor", "trivial", "union", "urban", "util",
        "vandal", "vapor", "verbal", "victim", "virtual", "visual", "vital", "vocal", "weapon", "western", "winter",
    ]

    private static let yseStems = ["anal", "paral", "catal", "breathal", "electrol", "dial", "hydrol", "psychoanal"]

    /// "metre" is British → American only (a "meter" measures things in both); compounds are safe both ways.
    private static let reStems = [
        "cent", "epicent", "theat", "lit", "fib", "calib", "lust", "meag", "somb", "spect", "sab", "scept", "mit",
        "kilomet", "centimet", "millimet", "goit", "och", "sepulch", "saltpet", "reconnoit", "nit",
    ]

    private static let doubledLStems = [
        "travel", "cancel", "label", "model", "level", "fuel", "signal", "counsel", "marvel", "quarrel", "equal",
        "total", "dial", "channel", "tunnel", "funnel", "panel", "pencil", "refuel", "rival", "shovel", "snorkel",
        "swivel", "jewel", "duel", "grovel", "libel", "pedal", "revel", "shrivel", "spiral", "tassel", "towel",
        "trowel", "unravel", "yodel", "cudgel", "dishevel", "enamel", "gravel", "initial", "kennel", "marshal",
        "barrel", "bevel", "chisel", "drivel",
    ]

    private static let specific: [(String, String)] = [
        ("grey", "gray"), ("greys", "grays"), ("greyed", "grayed"), ("greying", "graying"), ("greyish", "grayish"),
        ("aluminium", "aluminum"), ("defence", "defense"), ("defences", "defenses"), ("offence", "offense"),
        ("offences", "offenses"), ("pretence", "pretense"), ("ageing", "aging"), ("judgement", "judgment"),
        ("judgements", "judgments"), ("acknowledgement", "acknowledgment"), ("acknowledgements", "acknowledgments"),
        ("cosy", "cozy"), ("cosier", "cozier"), ("cosiest", "coziest"), ("pyjamas", "pajamas"),
        ("sceptic", "skeptic"), ("sceptics", "skeptics"), ("sceptical", "skeptical"), ("scepticism", "skepticism"),
        ("plough", "plow"), ("ploughs", "plows"), ("ploughed", "plowed"), ("ploughing", "plowing"), ("mould", "mold"),
        ("moulds", "molds"), ("mouldy", "moldy"), ("moult", "molt"), ("smoulder", "smolder"),
        ("smouldering", "smoldering"), ("paediatric", "pediatric"), ("paediatrician", "pediatrician"),
        ("anaesthetic", "anesthetic"), ("anaesthesia", "anesthesia"), ("anaemia", "anemia"), ("anaemic", "anemic"),
        ("encyclopaedia", "encyclopedia"), ("orthopaedic", "orthopedic"), ("leukaemia", "leukemia"),
        ("haemoglobin", "hemoglobin"), ("oestrogen", "estrogen"), ("foetus", "fetus"), ("manoeuvre", "maneuver"),
        ("manoeuvres", "maneuvers"), ("manoeuvred", "maneuvered"), ("manoeuvring", "maneuvering"),
        ("moustache", "mustache"), ("sulphur", "sulfur"), ("artefact", "artifact"), ("artefacts", "artifacts"),
        ("yoghurt", "yogurt"), ("aeroplane", "airplane"), ("aeroplanes", "airplanes"), ("jewellery", "jewelry"),
        ("marvellous", "marvelous"), ("woollen", "woolen"), ("enrol", "enroll"), ("enrols", "enrolls"),
        ("enrolment", "enrollment"), ("enrolments", "enrollments"), ("fulfil", "fulfill"), ("fulfils", "fulfills"),
        ("fulfilment", "fulfillment"), ("instil", "instill"), ("instils", "instills"), ("distil", "distill"),
        ("skilful", "skillful"), ("skilfully", "skillfully"), ("wilful", "willful"), ("appal", "appall"),
        ("appals", "appalls"), ("instalment", "installment"), ("instalments", "installments"),
        ("tranquillity", "tranquility"), ("counsellor", "counselor"), ("counsellors", "counselors"),
        ("doughnut", "donut"), ("doughnuts", "donuts"),
    ]

    /// British → American only: the American spelling is also a different British word.
    private static let britishToAmericanOnly: [(String, String)] = [
        ("tyre", "tire"), ("tyres", "tires"), ("cheque", "check"), ("cheques", "checks"), ("chequebook", "checkbook"),
        ("programme", "program"), ("programmes", "programs"), ("metre", "meter"), ("metres", "meters"),
        ("storey", "story"), ("storeys", "stories"), ("practise", "practice"), ("practised", "practiced"),
        ("practises", "practices"), ("practising", "practicing"), ("licence", "license"), ("licences", "licenses"),
        ("draught", "draft"), ("draughts", "drafts"), ("kerb", "curb"), ("kerbs", "curbs"), ("disc", "disk"),
        ("discs", "disks"),
    ]
}
