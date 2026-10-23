import SwiftUI

func meetingDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

struct MeetingsView: View {
    @Environment(MeetingStore.self) private var meetings
    @Environment(\.dismiss) private var dismiss
    @State private var recording = false
    @State private var opened: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { recording = true } label: {
                        Label("Grabar reunión", systemImage: "mic.circle.fill").font(.headline)
                    }
                } footer: {
                    Text("Se graba con el micrófono del iPhone, también con la pantalla bloqueada. La transcripción, quién dijo qué y las notas se hacen dentro de este iPhone; nada se envía a internet. En cuanto termina la transcripción el audio se borra y solo queda el texto. Avisa a los participantes que estás grabando.")
                }
                if !meetings.meetings.isEmpty {
                    Section("Reuniones") {
                        ForEach(meetings.meetings) { meeting in
                            NavigationLink(value: meeting.id) { MeetingRow(meeting: meeting) }
                        }
                        .onDelete { offsets in
                            for index in offsets { meetings.delete(meetings.meetings[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Reuniones")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { MeetingDetailView(meetingID: $0) }
            .navigationDestination(item: $opened) { MeetingDetailView(meetingID: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } } }
            .fullScreenCover(isPresented: $recording) {
                MeetingRecorderView { meeting in
                    recording = false
                    if let meeting {
                        meetings.process(meeting.id)
                        opened = meeting.id
                    }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    @Environment(MeetingStore.self) private var meetings
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(planningDayLabel(meeting.date))
                Text("·")
                Text(meetingDuration(meeting.duration))
                if let step = meetings.progress[meeting.id] {
                    Text("· \(step)").foregroundStyle(Color.marcelitoAmber)
                } else if meeting.status == .failed {
                    Text("· No se pudo procesar").foregroundStyle(Color.marcelitoDanger)
                } else if meeting.status == .ready {
                    Text("· \(meeting.speakers.count) \(meeting.speakers.count == 1 ? "voz" : "voces")")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MeetingRecorderView: View {
    @Environment(MeetingStore.self) private var meetings
    @State private var recorder = MeetingRecorder()
    @State private var fileName = ""
    @State private var started = false
    @State private var confirmDiscard = false
    let finish: (Meeting?) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(meetingDuration(recorder.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
            GeometryReader { proxy in
                Capsule().fill(Color.marcelitoNavy.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(recorder.state == .recording ? Color.marcelitoDanger : Color.secondary)
                            .frame(width: max(8, proxy.size.width * recorder.level))
                            .animation(.easeOut(duration: 0.2), value: recorder.level)
                    }
            }
            .frame(height: 10)
            .padding(.horizontal, 40)
            Text(recorder.state == .paused ? "En pausa" : started ? "Grabando…" : recorder.errorMessage == nil ? "Preparando el micrófono…" : "No se está grabando")
                .foregroundStyle(.secondary)
            if let error = recorder.errorMessage {
                Text(error).foregroundStyle(Color.marcelitoDanger).multilineTextAlignment(.center).padding(.horizontal)
                Button("Reintentar") { Task { await startRecording() } }
                    .buttonStyle(.marcelitoSecondary)
            }
            Spacer()
            HStack(spacing: 18) {
                Button {
                    recorder.state == .paused ? recorder.resume() : recorder.pause()
                } label: {
                    Label(recorder.state == .paused ? "Reanudar" : "Pausar", systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.marcelitoSecondary)
                .disabled(!started)
                Button {
                    let duration = recorder.stop()
                    let meeting = Meeting(title: "Reunión del \(planningDayLabel(.now))", date: .now, duration: duration, audioFileName: fileName)
                    meetings.add(meeting)
                    finish(meeting)
                } label: {
                    Label("Terminar", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.marcelitoPrimary)
                .disabled(!started)
            }
            .padding(.horizontal, 24)
            Button("Descartar", role: .destructive) { confirmDiscard = true }
                .padding(.bottom, 24)
        }
        .background(MarcelitoAmbientBackground())
        .foregroundStyle(Color.marcelitoNavy)
        .interactiveDismissDisabled()
        .confirmationDialog("¿Descartar la grabación?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Descartar", role: .destructive) { recorder.discard(); finish(nil) }
            Button("Seguir grabando", role: .cancel) {}
        }
        .task { await startRecording() }
        // Keep the screen awake while recording; locking it also works.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension MeetingRecorderView {
    fileprivate func startRecording() async {
        let target = meetings.newAudioURL()
        fileName = target.name
        started = await recorder.start(to: target.url)
    }
}

struct MeetingDetailView: View {
    @Environment(MeetingStore.self) private var meetings
    let meetingID: UUID
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let meeting = meetings.meeting(meetingID) {
            List {
                Section {
                    TextField("Título", text: Binding(
                        get: { meeting.title },
                        set: { var updated = meeting; updated.title = $0; meetings.update(updated) }
                    ))
                    .font(.headline)
                    LabeledContent("Fecha", value: planningDayLabel(meeting.date))
                    LabeledContent("Duración", value: meetingDuration(meeting.duration))
                    LabeledContent("Audio", value: meeting.hasAudio ? "Guardado hasta transcribir" : "Borrado · solo queda el texto")
                    if let step = meetings.progress[meeting.id] {
                        HStack { ProgressView(); Text(step).foregroundStyle(.secondary) }
                    } else if meeting.status == .failed || meeting.status == .recorded {
                        if let detail = meeting.statusDetail { Text(detail).font(.caption).foregroundStyle(Color.marcelitoDanger) }
                        Button(meeting.status == .failed ? "Volver a intentar" : "Transcribir ahora") { meetings.process(meeting.id) }
                    } else if let detail = meeting.statusDetail {
                        Text(detail).font(.caption).foregroundStyle(Color.marcelitoAmber)
                        if meeting.hasAudio {
                            Button("Volver a procesar") { meetings.process(meeting.id) }
                            Button("Quedarme solo con el texto y borrar el audio", role: .destructive) { meetings.deleteAudio(of: meeting.id) }
                        }
                    }
                }
                if let notes = meeting.notes {
                    Section("Resumen") { Text(notes.summary) }
                    if !notes.decisions.isEmpty {
                        Section("Acuerdos") { ForEach(notes.decisions, id: \.self) { Label($0, systemImage: "checkmark.seal") } }
                    }
                    if !notes.actionItems.isEmpty {
                        Section("Pendientes") {
                            ForEach(notes.actionItems) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task)
                                    Text(item.owner).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if meeting.status == .ready {
                    Section("Notas") {
                        Text(MeetingNotesWriter.available
                             ? "No se pudieron generar las notas de esta reunión."
                             : "Las notas automáticas requieren Apple Intelligence (iPhone 15 Pro o posterior, activado en Ajustes).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !meeting.speakers.isEmpty {
                    Section {
                        ForEach(meeting.speakers, id: \.self) { speaker in
                            HStack {
                                TextField("Hablante \((meeting.speakers.firstIndex(of: speaker) ?? 0) + 1)", text: Binding(
                                    get: { meeting.speakerNames[speaker] ?? "" },
                                    set: { var updated = meeting; updated.speakerNames[speaker] = $0; meetings.update(updated) }
                                ))
                                Spacer()
                                Text(talkTime(meeting, speaker)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("¿Quién es quién?")
                    } footer: {
                        Text("Escribe el nombre de cada voz; la transcripción se actualiza. Después usa «Volver a escribir las notas» para que los pendientes lleven los nombres.")
                    }
                    Section("Transcripción") {
                        ForEach(meeting.utterances) { utterance in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(meeting.displayName(for: utterance.speaker)).font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(meetingDuration(utterance.start)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Text(utterance.text).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle(meeting.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !meeting.utterances.isEmpty {
                            ShareLink(item: shareText(meeting)) { Label("Compartir notas y transcripción", systemImage: "square.and.arrow.up") }
                            Button { meetings.rewriteNotes(meeting.id) } label: { Label("Volver a escribir las notas", systemImage: "text.badge.star") }
                                .disabled(meetings.progress[meeting.id] != nil || !MeetingNotesWriter.available)
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Eliminar", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("¿Eliminar esta reunión y su audio?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Eliminar", role: .destructive) { meetings.delete(meeting); dismiss() }
            }
        } else {
            ContentUnavailableView("Reunión eliminada", systemImage: "mic.slash")
        }
    }

    private func talkTime(_ meeting: Meeting, _ speaker: String) -> String {
        let seconds = meeting.utterances.filter { $0.speaker == speaker }.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return meetingDuration(seconds)
    }

    private func shareText(_ meeting: Meeting) -> String {
        var parts = ["\(meeting.title) · \(planningDayLabel(meeting.date))"]
        if let notes = meeting.notes {
            parts.append("Resumen:\n\(notes.summary)")
            if !notes.decisions.isEmpty { parts.append("Acuerdos:\n" + notes.decisions.map { "• \($0)" }.joined(separator: "\n")) }
            if !notes.actionItems.isEmpty { parts.append("Pendientes:\n" + notes.actionItems.map { "• \($0.task) — \($0.owner)" }.joined(separator: "\n")) }
        }
        parts.append("Transcripción:\n\(meeting.transcriptText)")
        return parts.joined(separator: "\n\n")
    }
}
