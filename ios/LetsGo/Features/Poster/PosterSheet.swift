import SwiftUI
import SwiftData
import UIKit
import OSLog

/// "Make a poster": the preview at real proportions, Letter or A4, then print (AirPrint) or share
/// the PDF or the link. Opened from a gathering you host.
struct PosterSheet: View {
    @Bindable var gathering: Gathering
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var paper = PosterPaper.local()
    @State private var pdf: URL?
    @State private var loading = false
    @State private var problem: String?
    @State private var confirmTakeDown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let content = PosterCopy.content(gathering) {
                        preview(content)
                        Picker("Paper", selection: $paper) {
                            ForEach(PosterPaper.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        actions(content)
                        fromThePoster
                        if PosterCopy.isWeekly(gathering.recurring) {
                            TipNote(text: "It's weekly, so the same poster keeps working: after each one ends, its link moves on to next \(PosterCopy.englishWeekdays[Calendar.current.component(.weekday, from: gathering.start) - 1]).")
                        }
                        Button("Take the poster down", role: .destructive) { confirmTakeDown = true }
                            .font(.system(size: 14, weight: .semibold))
                    } else if loading {
                        ProgressView("Making your link…").frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        Text(PosterCopy.unavailable(gathering, now: .now) ?? "Couldn't make the poster's link.")
                            .foregroundStyle(Palette.muted)
                            .padding(.top, 40)
                    }
                }
                .padding(18)
            }
            .background(Palette.bg)
            .navigationTitle("Poster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .errorAlert($problem)
            .task { await makeLink() }
            .onChange(of: paper) { renderPDF() }
            .confirmationDialog("Take the poster down?", isPresented: $confirmTakeDown, titleVisibility: .visible) {
                Button("Take it down", role: .destructive) { takeDown() }
            } message: {
                Text("Its page will say so and take no more sign-ups. Paper already up stops working.")
            }
        }
    }

    private func preview(_ content: PosterContent) -> some View {
        GeometryReader { geo in
            let scale = geo.size.width / paper.size.width
            PosterView(content: content, paper: paper)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: paper.size.height * scale, alignment: .topLeading)
                .clipShape(.rect(cornerRadius: 4))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Poster preview: \(content.title), \(content.when)")
        }
        .aspectRatio(paper.size.width / paper.size.height, contentMode: .fit)
    }

    private func actions(_ content: PosterContent) -> some View {
        VStack(spacing: 10) {
            Button { printPoster(content) } label: { Label("Print", systemImage: "printer") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pdf == nil)
            HStack(spacing: 10) {
                if let pdf {
                    ShareLink(item: pdf) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let link = URL(string: content.url) {
                    ShareLink(item: link, message: Text("\(content.title) · \(content.when.capitalized)")) {
                        Label("Share link", systemImage: "link")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    /// Who said they're in from the web. Only the host gets their first names.
    @ViewBuilder
    private var fromThePoster: some View {
        if !gathering.webNames.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("From the poster · \(gathering.webNames.count)").eyebrow()
                Text(gathering.webNames.joined(separator: ", "))
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
            }
        }
    }

    private func makeLink() async {
        guard PosterCopy.unavailable(gathering, now: .now) == nil else { return }
        loading = true
        await attempt($problem) { () throws(APIError) in
            _ = try await Sync.makePoster(for: gathering, context: context)
        }
        loading = false
        renderPDF()
    }

    private func renderPDF() {
        guard let content = PosterCopy.content(gathering) else { return }
        do {
            pdf = try PosterPDF.write(content, paper: paper)
        } catch {
            problem = "Couldn't make the PDF."
        }
    }

    private func printPoster(_ content: PosterContent) {
        guard let pdf else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "\(content.title) poster"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = pdf
        _ = controller.present(animated: true)
    }

    private func takeDown() {
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.retirePoster(for: gathering, context: context)
                dismiss()
            }
        }
    }
}

/// Writes the poster as a one-page vector PDF at the paper's size.
enum PosterPDF {
    private static let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "poster")

    enum Failure: Error { case couldNotWrite }

    static func write(_ content: PosterContent, paper: PosterPaper) throws -> URL {
        let name = content.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name) poster (\(paper.label)).pdf")
        let renderer = ImageRenderer(content: PosterView(content: content, paper: paper, fillsPaper: false))
        renderer.proposedSize = ProposedViewSize(paper.size)
        var box = CGRect(origin: .zero, size: paper.size)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else {
            log.error("Couldn't open a PDF context at \(url.path(), privacy: .public)")
            throw Failure.couldNotWrite
        }
        renderer.render { _, draw in
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }
}
