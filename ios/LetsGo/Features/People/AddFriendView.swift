import SwiftUI
import SwiftData

/// Adding a friend: hand them your code, or type in theirs. A code works once, for a week.
struct AddFriendView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var myCode: FriendCodeDTO?
    @State private var theirCode = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var added: String?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add a friend").display(34)
                        Text("Friends see your porch light and what you're out at. Nobody else does.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.soft)
                    }
                    if !APIConfig.isConfigured {
                        TipNote(text: "Friends need the server. Add one at the bottom of Passport, under **Server**.")
                    } else if !ServerFeatures.shared.has(.people) {
                        TipNote(text: ServerFeatures.Feature.people.comingSoon)
                    }
                    if let added {
                        Label("You and \(added) are friends now.", systemImage: "person.2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.live)
                    }
                    theirs
                    mine
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.bg)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .errorAlert($problem)
        }
        .presentationBackground(Palette.bg)
    }

    private var theirs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Got a code?").eyebrow()
            HStack(spacing: 10) {
                TextField("Like 7KQ4 MX2P", text: $theirCode)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit(accept)
                Button("Add", action: accept)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.onProminent)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(Palette.prominent, in: .capsule)
                    .disabled(theirCode.filter(\.isLetter).count + theirCode.filter(\.isNumber).count < 6 || busy || !ready)
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .card(radius: 26)
        }
    }

    private var mine: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your code").eyebrow()
            if let myCode {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.spaced(myCode.code))
                        .font(.system(size: 34, weight: .heavy, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                    Text("Good for one friend, until \(myCode.expiresAt.formatted(.dateTime.weekday(.wide).month().day())).")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                    ShareLink(item: "Come out with me on Let's Go. My friend code is \(Self.spaced(myCode.code)).") {
                        Label("Send it", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
                .card(radius: 22)
            } else {
                Button { makeCode() } label: { Label("Make my code", systemImage: "qrcode") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || !ready)
            }
        }
    }

    /// A server that keeps friends.
    private var ready: Bool { APIConfig.isConfigured && ServerFeatures.shared.has(.people) }

    /// "7KQ4MX2P" → "7KQ4 MX2P", easier to read out.
    static func spaced(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4)) \(code.suffix(4))"
    }

    private func makeCode() {
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in myCode = try await Sync.friendCode() }
            busy = false
        }
    }

    private func accept() {
        let code = theirCode
        let here = location.center
        busy = true
        typing = false
        Task {
            await attempt($problem) { () throws(APIError) in
                added = try await Sync.accept(code: code, around: here, context: context)
                theirCode = ""
            }
            busy = false
        }
    }
}

/// A new crew: a name and the friends in it.
struct NewCrewView: View {
    var people: [Person]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: Set<UUID> = []
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name it, like \u{201C}Tuesday trivia\u{201D}", text: $name)
                        .font(.system(size: 17, weight: .semibold))
                }
                Section("Who's in it") {
                    ForEach(people) { p in
                        Button {
                            if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) }
                        } label: {
                            HStack(spacing: 12) {
                                FriendAvatar(friend: p.snapshot, size: 32)
                                Text(p.name).foregroundStyle(Palette.ink)
                                Spacer()
                                Image(systemName: picked.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(p.id) ? Palette.accent : Palette.muted)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("New crew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make it") { make() }
                        .fontWeight(.bold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty || busy)
                }
            }
            .errorAlert($problem)
        }
    }

    private func make() {
        let members = people.filter { picked.contains($0.id) }
        let title = name
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.makeCrew(title, members: members, context: context)
                dismiss()
            }
            busy = false
        }
    }
}
