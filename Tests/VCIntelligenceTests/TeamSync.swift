import Foundation
import VCModels

/// A realistic 40-line team meeting (billing bug, conference, release estimate) with line start and end times.
enum TeamSync {
    private static let lines: [(speaker: String, start: Double, end: Double, text: String)] = [
        ("Maya", 1.0, 5.23, "Morning everyone, let's get going, we've got a full agenda today."),
        ("Leo", 5.83, 10.83, "Morning. Sorry I'm a bit late, the train was stuck outside the station."),
        ("Maya", 11.43, 17.2, "No worries. First up is the billing bug from last week. Tom, where are we?"),
        ("Tom", 17.8, 25.88, "So the double-charge bug hit about forty customers on annual plans, all of them renewed between the third and the fifth."),
        ("Tom", 26.48, 31.86, "Support has twenty-six open tickets about it, and two customers have asked to cancel."),
        ("Maya", 32.46, 35.15, "Do we know the root cause yet?"),
        ("Leo", 35.75, 46.14, "Yes, the retry job in the payment service fired twice when the card processor timed out. We shipped a fix on Monday that makes the retry idempotent."),
        ("Maya", 46.74, 49.82, "Okay. And the refunds, have they gone out?"),
        ("Tom", 50.42, 55.8, "Not yet. Finance needs the list of affected accounts before they can issue refunds."),
        ("Maya", 56.4, 60.25, "Tom, please send finance the list of affected accounts today."),
        ("Tom", 60.85, 63.92, "Sure, I'll send it to finance this afternoon."),
        ("Priya", 64.52, 71.06, "Should we also email the affected customers? A short apology with a discount might stop the cancellations."),
        ("Maya", 71.66, 74.74, "I like that. What discount were you thinking?"),
        ("Priya", 75.34, 81.11, "Maybe one month free on their next renewal. That's roughly two thousand euros in total."),
        ("Maya", 81.71, 85.55, "Agreed, let's offer one month free to the affected customers."),
        ("Priya", 86.15, 92.31, "I'll draft the apology email by Thursday and share it with Tom before it goes out."),
        ("Leo", 92.91, 101.75, "I'd also like to add an alert on duplicate charges, so we catch this within an hour next time instead of a week."),
        ("Maya", 102.35, 108.89, "Good idea. Can you have that alert in place before the next billing run on the fifteenth?"),
        ("Leo", 109.49, 112.95, "Yes, I can have it done by the twelfth."),
        ("Maya", 117.55, 121.02, "Great. Next topic, the developer conference in Lisbon. Priya?"),
        ("Priya", 121.62, 132.0, "The conference is on the twentieth of next month. Early-bird passes end on the twentieth of this month, and they're four hundred euros instead of six hundred."),
        ("Maya", 132.6, 134.91, "How many of us are going?"),
        ("Priya", 135.51, 139.35, "Three, I think: me, Leo and one person from sales."),
        ("Maya", 139.95, 142.65, "What's the travel budget for this quarter?"),
        ("Tom", 143.25, 148.25, "I think about six thousand euros, but I'd have to double-check with finance."),
        ("Maya", 148.85, 152.69, "Priya, could you book the early-bird passes before the twentieth?"),
        ("Priya", 153.29, 155.6, "Sure, I'll book them this week."),
        ("Leo", 156.2, 160.43, "Do we have a talk accepted, or are we just attending?"),
        ("Priya", 161.03, 165.65, "Our talk on offline sync was accepted. Leo, you'd be presenting it."),
        ("Leo", 166.25, 174.32, "Okay, then I need the slides reviewed two weeks before. I'll have a first draft by the end of the month."),
        ("Maya", 179.92, 186.46, "Last thing, the mobile release estimate. Leo, can you estimate the work once Priya's designs are ready?"),
        ("Leo", 187.06, 192.06, "I can, but the designs aren't final. Priya, when do you expect them?"),
        ("Priya", 192.66, 198.82, "The final designs should be ready next Wednesday. The onboarding screens are the only open part."),
        ("Leo", 199.42, 207.11, "Then I'll send the estimate on Friday next week. My rough guess is six to eight weeks with two engineers."),
        ("Maya", 207.71, 213.86, "Six to eight weeks puts us in early December, which is tight before the holiday freeze."),
        ("Tom", 214.46, 220.62, "Support would prefer we don't release in the last two weeks of December, we're short-staffed then."),
        ("Maya", 221.22, 228.14, "Who's covering support while Tom and Anna are away is still open; we'll figure that out next week."),
        ("Maya", 228.74, 231.43, "Okay, I think that's everything. Thanks all."),
        ("Tom", 232.03, 233.23, "Thanks, Maya."),
        ("Leo", 233.83, 235.37, "Cheers, see you tomorrow."),
    ]

    static let transcript: [ContextLine] = lines.enumerated().map { index, line in
        ContextLine(segmentID: Fixture.segmentID(400 + index), speaker: line.speaker, time: line.start, text: line.text, end: line.end)
    }
}
