import SwiftUI

struct AutoReplyJobDeleteButton: View {
    @ObservedObject var model: AutoReplyViewModel
    let job: AutoReplyJob

    var body: some View {
        Button(role: .destructive) { model.deleteJob(job.id) } label: {
            Label("删除 / Delete", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!model.canDeleteJob(job.id))
        .help("删除任务，保留聊天记录 / Delete task; preserve chat history")
        .accessibilityLabel("删除任务 #\(job.sequence) / Delete task #\(job.sequence)")
        .accessibilityIdentifier("delete-job-\(job.id.uuidString)")
    }
}
