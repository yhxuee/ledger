import EventKit
import Foundation
import SwiftUI

struct RecurringImportDraft: Identifiable {
    let id = UUID()
    var title: String
    var nextRunAt: Date
    var interval: RecurringInterval
    var customDays: Int
}

struct CalendarImportCandidate: Identifiable {
    var id: String
    var title: String
    var startDate: Date
    var draft: RecurringImportDraft?
    var warning: String?
}

@MainActor
final class CalendarImportModel: ObservableObject {
    @Published var candidates: [CalendarImportCandidate] = []
    @Published var loading = false
    @Published var errorMessage: String?
    private let store = EKEventStore()

    func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            guard try await store.requestFullAccessToEvents() else { throw CalendarImportError.accessDenied }
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .month, value: -1, to: .now) ?? .now
            let end = calendar.date(byAdding: .year, value: 2, to: .now) ?? .now
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            var seen = Set<String>()
            candidates = events.compactMap { event in
                let identifier = event.calendarItemIdentifier
                guard seen.insert(identifier).inserted else { return nil }
                let mapping = Self.map(event)
                return .init(id: identifier, title: event.title?.isEmpty == false ? event.title! : "Untitled Event", startDate: event.startDate, draft: mapping.draft, warning: mapping.warning)
            }.sorted { $0.startDate < $1.startDate }
        } catch { errorMessage = error.localizedDescription }
    }

    private static func map(_ event: EKEvent) -> (draft: RecurringImportDraft?, warning: String?) {
        guard let rules = event.recurrenceRules, rules.count == 1, let rule = rules.first else { return (nil, "This event does not contain one supported recurrence rule.") }
        let hasMultipleDays = (rule.daysOfTheWeek?.count ?? 0) > 1 || (rule.daysOfTheMonth?.count ?? 0) > 1 || (rule.monthsOfTheYear?.count ?? 0) > 1 || (rule.weeksOfTheYear?.count ?? 0) > 0 || (rule.daysOfTheYear?.count ?? 0) > 0 || (rule.setPositions?.count ?? 0) > 0
        guard !hasMultipleDays else { return (nil, "This event uses a complex recurrence pattern that cannot be imported safely.") }
        let schedule: (RecurringInterval, Int)?
        switch rule.frequency {
        case .daily: schedule = (.customDays, max(1, rule.interval))
        case .weekly where rule.interval == 1: schedule = (.weekly, 7)
        case .monthly where rule.interval == 1: schedule = (.monthly, 30)
        case .yearly where rule.interval == 1: schedule = (.yearly, 365)
        default: schedule = nil
        }
        guard let schedule else { return (nil, "Only daily, weekly, monthly, and yearly recurrence patterns are supported.") }
        return (.init(title: event.title ?? "", nextRunAt: max(event.startDate, .now), interval: schedule.0, customDays: schedule.1), nil)
    }
}

enum CalendarImportError: LocalizedError {
    case accessDenied
    var errorDescription: String? { "Calendar access was not granted." }
}

struct CalendarEventPickerView: View {
    @StateObject private var model = CalendarImportModel()
    @Environment(\.dismiss) private var dismiss
    let selection: (RecurringImportDraft) -> Void
    var body: some View {
        NavigationStack {
            List(model.candidates) { event in
                Button {
                    guard let draft = event.draft else { model.errorMessage = event.warning; return }
                    selection(draft); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.body.weight(.semibold))
                        Text(event.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        if let warning = event.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                }.disabled(event.draft == nil)
            }
            .overlay { if model.loading { ProgressView() } else if model.candidates.isEmpty { ContentUnavailableView("No Calendar Events", systemImage: "calendar") } }
            .navigationTitle("Import from Calendar").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await model.load() }
            .alert("Calendar Import", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        }
    }
}
