import SwiftUI

struct DateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    let onApply: (Date, Date) -> Void

    init(start: Date, end: Date, onApply: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { onApply(start, end); dismiss() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium])
    }
}
