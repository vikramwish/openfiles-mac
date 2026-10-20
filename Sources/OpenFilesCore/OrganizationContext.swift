import Foundation

/// Grounded folder suggestions from indexed evidence. No new content reads or network calls.
public struct OrganizationContext: Sendable {
    public let topic: String
    public let folders: [String]
    public let reasons: [String]

    public static func suggest(for file: FileRecord, fallbackTopic: String? = nil) -> Self? {
        let filename = Set(FileSearchQuery.words(file.url.deletingPathExtension().lastPathComponent))
        let parents = Array(file.url.deletingLastPathComponent().pathComponents.suffix(5))
        let pathWords = Set(parents.flatMap(FileSearchQuery.words))
        let content = Set(file.searchTerms ?? []).union(file.imageContent?.textTerms ?? [])
        func score(_ words: [String]) -> Int {
            words.reduce(0) { $0 + (filename.contains($1) ? 4 : 0) + (pathWords.contains($1) ? 2 : 0) + (content.contains($1) ? 1 : 0) }
        }
        func matches(_ words: [String]) -> Bool { score(words) > 0 }
        func folder(after markers: [String]) -> String? {
            guard let marker = parents.lastIndex(where: { markers.contains($0.lowercased()) }), marker + 1 < parents.count else { return nil }
            let generic: Set<String> = ["files", "documents", "downloads", "desktop", "pictures", "images", "photos", "misc", "other", "unsorted", "lectures", "assignments", "bookings", "itineraries", "research", "notes"]
            guard !generic.contains(parents[marker + 1].lowercased()) else { return nil }
            return clean(parents[marker + 1])
        }
        func result(_ topic: String, _ folders: [String], _ evidence: String) -> Self {
            Self(topic: topic, folders: folders.compactMap(clean), reasons: [evidence])
        }
        let image = file.imageContent
        let subjects = image?.subjects.filter { $0.confidence >= 0.45 } ?? []
        let visual = Set(subjects.flatMap { FileSearchQuery.words($0.name) })
        let visualDescriptions = subjects.prefix(3).map(\.name).joined(separator: ", ")
        // Read document intent before scene labels: a photographed receipt is a receipt.
        let transactionWords = ["receipt", "receipts", "invoice", "invoices", "warranty", "warranties", "reimbursement"]
        if score(transactionWords) >= 2 || (image != nil && !content.isDisjoint(with: transactionWords)) {
            let kind = matches(["warranty", "warranties"]) ? "Warranties" : matches(["invoice", "invoices"]) ? "Invoices" : "Receipts"
            let context = folder(after: ["purchases", "shopping", "expenses"])
            return result("Purchases", ["Purchases", kind] + context.map { [$0] }.defaultEmpty, "Document terms or existing folder identify \(kind.lowercased()).")
        }
        if image != nil {
            let trip = folder(after: ["trips", "travel", "holidays", "vacations"])
            let event = folder(after: ["events", "celebrations", "weddings", "birthdays"])
            let embeddedPlace = image?.location?.names.compactMap(clean).first
            let place = embeddedPlace ?? image?.location?.searchKeys.sorted().first.map { $0.capitalized }
            let placeReason = embeddedPlace != nil ? "Embedded place" : "Approximate place from embedded GPS"
            let subjectsToFolders: [(Set<String>, String, String)] = [
                (["zebra", "zebras", "elephant", "elephants", "giraffe", "giraffes", "lion", "tiger", "wildlife"], "Wildlife", "Wildlife"),
                (["dog", "dogs", "cat", "cats", "puppy", "kitten", "pet", "pets"], "Pets", "Pets"),
                (["beach", "beaches", "seashore", "coast", "coastal"], "Landscapes", "Beaches"),
                (["mountain", "mountains", "alpine"], "Landscapes", "Mountains"),
                (["forest", "forests", "woodland"], "Landscapes", "Forests"),
                (["sunset", "sunrise"], "Landscapes", "Sunsets and Sunrises"),
                (["flower", "flowers", "plant", "plants", "garden"], "Nature", "Plants and Gardens"),
                (["food", "meal", "dish", "cuisine", "dessert"], "Food", "Food"),
                (["building", "architecture", "skyscraper"], "Places", "Architecture"),
                (["car", "cars", "motorcycle", "vehicle"], "Vehicles", "Vehicles")
            ]
            if visual.contains("screenshot") || matches(["screenshot", "screenshots"]) {
                return result("Creative", ["Creative", "Screenshots"] + folder(after: ["screenshots"]).map { [$0] }.defaultEmpty, "Screenshot evidence in image labels, filename, or current folder.")
            }
            if let event { return result("Photos", ["Photos", "Events", event], "Existing event folder: \(event). Image labels: \(visualDescriptions.isEmpty ? "no specific scene" : visualDescriptions).") }
            if let scene = subjectsToFolders.first(where: { !$0.0.isDisjoint(with: visual) }) {
                let species: [(String, String)] = [("zebra", "Zebras"), ("elephant", "Elephants"), ("giraffe", "Giraffes"), ("lion", "Lions"), ("tiger", "Tigers"), ("dog", "Dogs"), ("cat", "Cats")]
                let leaf = species.first(where: { visual.contains($0.0) || visual.contains($0.0 + "s") })?.1 ?? scene.2
                var folders = ["Photos"]
                if let trip { folders += ["Trips", trip] }
                else if let place { folders += ["Places", place] }
                else { folders.append(scene.1) }
                if folders.last != leaf { folders.append(leaf) }
                return result("Photos", folders, "On-device image labels: \(visualDescriptions)." + (trip.map { " Existing trip folder: \($0)." } ?? place.map { " \(placeReason): \($0)." } ?? ""))
            }
            if let trip { return result("Photos", ["Photos", "Trips", trip], "Existing trip folder: \(trip); image content was indexed.") }
            if let place { return result("Photos", ["Photos", "Places", place], "\(placeReason): \(place).") }
        }
        let routes: [(topic: String, words: [String])] = [
            ("Study", ["education", "study", "university", "college", "course", "courses", "lecture", "lectures", "assignment", "assignments", "homework", "research"]),
            ("Travel", ["travel", "itinerary", "flight", "flights", "hotel", "booking", "bookings", "vacation", "holiday"]),
            ("Work", ["work", "business", "client", "clients", "proposal", "proposals", "meeting", "meetings", "presentation", "presentations"]),
            ("Home", ["household", "renovation", "maintenance", "appliance", "gardening", "furniture"]),
            ("Cooking", ["recipe", "recipes", "cooking", "ingredients", "baking"]),
            ("Events", ["invitation", "invitations", "concert", "conference", "celebration", "wedding"]),
            ("Creative", ["design", "illustration", "artwork", "logo", "logos", "music", "composition", "script"])
        ]
        let ranked = routes.map { ($0.topic, score($0.words)) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let topic: String
        if let best = ranked.first, best.1 >= 2, best.1 > (ranked.dropFirst().first?.1 ?? 0) { topic = best.0 }
        else if let fallbackTopic { topic = fallbackTopic }
        else { return nil }
        var folders = [topic]
        switch topic {
        case "Study":
            if let course = folder(after: ["courses", "university", "college", "study"]) { folders += ["Courses", course] }
            let kind = matches(["assignment", "assignments", "homework"]) ? "Assignments" : matches(["lecture", "lectures"]) ? "Lectures" : matches(["research", "paper", "papers"]) ? "Research Papers" : "Course Materials"
            if folders.last != kind { folders.append(kind) }
        case "Travel":
            if let trip = folder(after: ["trips", "travel", "holidays", "vacations"]) { folders += ["Trips", trip] }
            folders.append(matches(["flight", "flights", "hotel", "booking", "bookings"]) ? "Bookings" : "Itineraries")
        case "Work":
            if let client = folder(after: ["clients", "client"]) { folders += ["Clients", client] }
            folders.append(matches(["proposal", "proposals"]) ? "Proposals" : matches(["meeting", "meetings"]) ? "Meeting Notes" : matches(["presentation", "presentations"]) ? "Presentations" : "Documents")
        case "Creative": folders.append(matches(["logo", "logos"]) ? "Logos" : matches(["music", "composition"]) ? "Music" : matches(["script"]) ? "Scripts" : "Design")
        case "Home": folders.append(matches(["appliance", "manual", "instructions"]) ? "Appliance Manuals" : matches(["renovation"]) ? "Renovation" : "Household")
        case "Cooking": folders.append("Recipes")
        case "Events": folders.append(matches(["invitation", "invitations"]) ? "Invitations" : "Plans and Tickets")
        default: break
        }
        let context = folders.count > 2 ? " Preserved existing context: \(folders.dropFirst().dropLast().joined(separator: "/"))." : ""
        let routeWords = Set(routes.first(where: { $0.topic == topic })?.words ?? [])
        let filenameHits = filename.intersection(routeWords).sorted()
        let folderHits = pathWords.intersection(routeWords).sorted()
        let contentHits = content.intersection(routeWords).sorted()
        var evidence = "Content and available context support \(topic.lowercased())." + context
        if !filenameHits.isEmpty { evidence += " Filename terms: \(filenameHits.prefix(5).joined(separator: ", "))." }
        if !folderHits.isEmpty { evidence += " Folder terms: \(folderHits.prefix(5).joined(separator: ", "))." }
        if !contentHits.isEmpty { evidence += " Indexed terms: \(contentHits.prefix(5).joined(separator: ", "))." }
        return result(topic, folders, evidence)
    }

    /// Folder components must remain single, readable names, never executable paths.
    private static func clean(_ input: String) -> String? {
        let text = input.components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !text.isEmpty, !FileRules.sensitive(text) else { return nil }
        return String(text.prefix(64))
    }
}

private extension Optional where Wrapped == [String] {
    var defaultEmpty: [String] { self ?? [] }
}
