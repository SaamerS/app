import Foundation
import Observation
import BindersKit

/// One question answered from the binders as it goes, for what shows it (the Knowledge page, Command Mode's panel): the
/// passages with its words at once, then the passages the answer draws on, then the answer as it's written.
@MainActor
@Observable
final class AskRun: Identifiable {
    let id = UUID()
    let question: String
    /// How far it has got; nil until something is found.
    private(set) var stage: AskStage?
    private(set) var sources: [KnowledgeHit] = []
    /// The answer so far, then all of it.
    private(set) var text = ""
    /// The finished answer; nil while it's on its way.
    private(set) var answer: KnowledgeService.Answer?

    init(question: String) {
        self.question = question
    }

    /// One already answered, such as the boards' digest.
    init(answer: KnowledgeService.Answer) {
        question = answer.question
        sources = answer.sources
        text = answer.text
        self.answer = answer
    }

    var isWorking: Bool { answer == nil }

    /// What it's doing while there's no answer to show yet; nil once the answer is coming.
    var status: String? {
        isWorking && text.isEmpty ? AskStage.waiting(stage, found: sources.count) : nil
    }

    /// Answers it from the binders, showing how it goes, and returns the answer.
    @discardableResult
    func run(with knowledge: KnowledgeService, searchQuery: String? = nil, binder: UUID? = nil) async -> KnowledgeService.Answer {
        let answer = await knowledge.ask(question, searchQuery: searchQuery, binder: binder, progress: { [weak self] progress in
            self?.show(progress)
        })
        finish(answer)
        return answer
    }

    private func show(_ progress: KnowledgeService.AskProgress) {
        guard isWorking else { return }
        if stage != progress.stage { stage = progress.stage }
        if sources != progress.sources { sources = progress.sources }
        if progress.stage == .writing, text != progress.text { text = progress.text }
    }

    private func finish(_ answer: KnowledgeService.Answer) {
        if sources != answer.sources { sources = answer.sources }
        if text != answer.text { text = answer.text }
        self.answer = answer
    }
}
