import Foundation

@main struct DateInputTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func reject(_ text: String, message: String) throws {
        do { _ = try PlistValueKind.date.parse(text) }
        catch is GestaltFailure { return }
        throw Failure(message: message)
    }

    static func controls() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12, minute: 34, second: 56))!
        for text in ["2026-11-12T12:34:56Z", "2026-11-12T20:34:56+08:00",
                     "2026-11-12T07:04:56-05:30", " \n2026-11-12T12:34:56Z\t "] {
            let actual = try PlistValueKind.date.parse(text) as! Date
            try expect(actual == expected, "Valid ISO dates, timezone offsets and outer whitespace retain their values")
        }
        let fractional = try PlistValueKind.date.parse("2026-11-12T12:34:56.125Z") as! Date
        try expect(fractional == expected.addingTimeInterval(0.125), "Fractional seconds remain supported")
        try reject("not a date", message: "Malformed input must remain rejected")
    }

    static func main() throws {
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        if selected == "suffix" || selected == "all" {
            try reject("2026-11-12T12:34:56Z-not-a-date", message: "A valid date prefix must not hide a trailing suffix")
        }
        if selected == "second-value" || selected == "all" {
            try reject("2026-11-12T12:34:56.125Z 2027-01-01T00:00:00Z", message: "A date field must not silently discard a second value")
        }
        if selected == "all" { try controls() }
        print("PASS: date fields consume the complete input and preserve valid values")
    }
}
