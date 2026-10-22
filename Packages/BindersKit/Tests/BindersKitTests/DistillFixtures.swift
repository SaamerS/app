import Foundation

/// Replies a small local model gives when it distills the bench's spec notes (`DistillBench.specs`), written the ways
/// such models write them: clean, in a code fence after a sentence, with trailing commas and numbers as strings, cut off
/// by its last token, repeating itself, waiting in a circle, naming sections loosely, wrapped in an object, after a
/// thinking block. Each is read by `DistillReading` in the tests and scored against the bench's gold items.
enum DistillFixtures {
    /// The checkout spec, cleanly.
    static let checkoutClean = """
        [
          {"title": "Combine checkout into one page", "brief": "Put address, delivery and card on one page instead of three.", "done_when": "Checkout is a single page with all three parts.", "section": "Payment form", "waits_for": [], "size": "medium", "for": "agent"},
          {"title": "Check card numbers as they're typed", "brief": "Validate the card number while typing and show the error under the field.", "done_when": "A wrong number shows an error under the field before submitting.", "section": "Payment form", "waits_for": [1], "size": "small", "for": "agent"},
          {"title": "Add Apple Pay and Google Pay buttons", "brief": "Show both buttons above the form.", "done_when": "Both buttons appear above the form and work.", "section": "Payment form", "waits_for": [1], "size": "medium", "for": "agent"},
          {"title": "Keep entered details and offer Retry", "brief": "When the bank declines or the connection drops, keep what the customer typed and offer Retry.", "done_when": "A failed payment keeps the form filled and shows Retry.", "section": "Retry after a failed payment", "waits_for": [1], "size": "medium", "for": "agent"},
          {"title": "Log each payment failure with its reason code", "brief": "Every failed payment is logged with the reason code.", "done_when": "Failures show in the log with reason codes.", "section": "Retry after a failed payment", "waits_for": [], "size": "small", "for": "agent"},
          {"title": "Show a live order summary", "brief": "Items, delivery cost and total beside the form, updated when delivery changes.", "done_when": "Changing delivery updates the total in the summary.", "section": "Order summary", "waits_for": [1], "size": "small", "for": "agent"},
          {"title": "Ship behind a flag to 10% of visitors", "brief": "Release the new checkout to 10% once form, retry and summary are done.", "done_when": "10% of visitors see the new checkout.", "section": "Rollout", "waits_for": [1, 4, 6], "size": "small", "for": "agent"},
          {"title": "Compare abandonment and decide on 100%", "brief": "After two weeks, compare abandonment and decide whether to go to 100%.", "done_when": "A decision on 100% is written down.", "section": "Rollout", "waits_for": [7], "size": "small", "for": "person"}
        ]
        """

    /// The onboarding spec, in a fence after a sentence, with a trailing comma, numbers as strings, other key names, and a
    /// section with its number.
    static let onboardingFenced = """
        Here are the work items for the onboarding note:

        ```json
        [
          {"title": "Order the laptop and accounts", "description": "Order them a week before the start date.", "doneWhen": "Laptop and accounts are ready a week ahead.", "section": "Before day one", "depends_on": [], "size": "S", "for": "human"},
          {"title": "Send the welcome email", "description": "Email the first week's plan.", "done": "The new starter has the plan before day one.", "section": "before day one", "depends_on": ["1"], "size": "small", "for": "agent"},
          {"title": "Pair the new starter with a buddy", "section": "First Week", "size": "S", "for": "person"},
          {"title": "Book the day-three check-in with the manager", "brief": "30 minutes on day three.", "section": "First week", "waits_for": "", "size": "S", "for": "either"},
          {"title": "Write the one-page handbook", "brief": "Where things are, who to ask, how leave works; keep it in the shared drive.", "done_when": "The handbook is in the shared drive.", "section": "3. Handbook", "size": "M", "for": "agent"},
          {"title": "Send the five-question survey", "brief": "After two weeks.", "section": "Feedback", "size": "S", "for": "agent"},
          {"title": "Share the survey results with team leads", "section": "Feedback", "waits_for": ["Send the five-question survey"], "size": "S", "for": "person",},
        ]
        ```

        Let me know if you'd like changes.
        """

    /// The booth spec, cut off by the model's last token in the middle of an item.
    static let boothCutOff = """
        [{"title": "Book the stand and a power socket", "brief": "Stand 14 with power.", "done_when": "The booking is confirmed.", "section": "Stand", "waits_for": [], "size": "small", "for": "person"},
        {"title": "Order the backdrop banner", "brief": "3 by 2 metres.", "done_when": "The banner is ordered.", "section": "Stand", "waits_for": [], "size": "small", "for": "agent"},
        {"title": "Build the offline demo", "brief": "A five-minute demo of the board that runs offline with sample data.", "done_when": "The demo runs with the network off.", "section": "Demo", "waits_for": [], "size": "large", "for": "agent"},
        {"title": "Order stickers and tote bags", "brief": "300 stickers and 100 tote bags, arriving a week before.", "done_when": "They arrive a week before the summit.", "section": "Swag", "waits_for": [], "size": "small", "for": "person"},
        {"title": "Draw up the stand rota", "brief": "Two people at the stand at all times.", "done_when": "Every hour has two names.", "section": "On the day", "waits_for": [], "size": "small", "for": "person"},
        {"title": "Send every lead a thank-you email", "brief": "Within two days of the summit.", "done_when": "Every lead has an email.", "section": "After", "wai
        """

    /// The offline spec, with a repeat, a circle (sync and storage waiting on each other), a wait on itself and one past
    /// the end, inside an object, after a thinking block.
    static let offlineMessy = """
        <think>The note has five sections. Storage first, then sync. [Maybe 6 items]</think>
        {"items": [
          {"title": "Store the last 7 days of jobs, encrypted", "brief": "Keep 7 days of jobs on the device, encrypted.", "done_when": "Jobs from the last 7 days open offline.", "section": "Storage", "waits_for": [2], "size": "medium", "for": "agent"},
          {"title": "Queue offline changes and send them in order", "brief": "Changes made offline are sent in order when the signal is back.", "done_when": "Offline edits reach the server in order.", "section": "Sync", "waits_for": [1], "size": "large", "for": "agent"},
          {"title": "Ask which version to keep when a job changed on both sides", "brief": "Keep both and ask the user.", "done_when": "A conflict shows both versions and a choice.", "section": "Sync", "waits_for": [3, 2], "size": "medium", "for": "agent"},
          {"title": "Show an offline banner", "brief": "A banner while offline.", "done_when": "The banner shows with no signal.", "section": "interface", "waits_for": [12], "size": "small", "for": "agent"},
          {"title": "Show an offline banner.", "brief": "A banner while offline.", "section": "Interface", "size": "small", "for": "agent"},
          {"title": "Mark jobs that haven't synced", "brief": "Each unsynced job is marked.", "done_when": "Unsynced jobs carry a mark.", "section": "Interface", "waits_for": [2], "size": "small", "for": "agent"},
          {"title": "Test an hour offline and a flaky connection", "brief": "Cut the network for an hour, then make it flaky.", "done_when": "Both tests are written up.", "section": "Testing", "waits_for": [2], "size": "medium", "for": "either"},
          {"title": "Write down what happens to photos", "section": "Testing", "waits_for": [7], "size": "small", "for": "agent"},
          {"title": "Offline maps", "brief": "Not now.", "section": "Offline maps", "size": "large"}
        ]}
        """

    /// The documentation note: nothing to do.
    static let releaseNamesEmpty = "[]"

    /// Replies that aren't a list at all, or barely.
    static let noList = "I couldn't find any work items in this note. It looks like documentation."
    static let brokenItems = """
        [{"title": "Fix the header", "section": "Design"}, {"brief": "no title here"}, "just a string", {"title": 42}, {"title": "   "}]
        """
}
