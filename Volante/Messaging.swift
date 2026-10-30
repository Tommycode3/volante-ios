import Foundation

/// Reaching people by speaking.
///
/// iOS doesn't let a third-party app send iMessage or SMS, full stop. So we
/// use what can actually be used, programmatically: Slack, Telegram, and —
/// when the Mac is available — the channel that goes through it. Each person
/// has their preferred channel, so by voice the name is enough.
enum Messaging {

    static var telegramToken = ""

    /// The result is read back aloud: it must be a sentence, not a code.
    @MainActor
    static func send(to person: Person, text: String,
                     drafts: DraftStore,
                     viaMac: ((String, String?) async -> String)?) async -> String {
        guard !text.isEmpty else { return "Errore: messaggio vuoto." }

        // WhatsApp first, if there's a number: it's the channel they actually use.
        // It doesn't send by itself — iOS doesn't allow that for any app other than
        // WhatsApp — but it stays ready, one tap away.
        if !person.whatsappNumber.isEmpty {
            drafts.add(MessageDraft(personName: person.name,
                                    phone: person.whatsappNumber,
                                    text: text))
            return "Messaggio pronto per \(person.name) su WhatsApp. Ti basta un tocco quando sei fermo: lo trovi in Archivio, sotto Persone."
        }
        if !person.telegramChatID.isEmpty, !telegramToken.isEmpty {
            return await telegram(chatID: person.telegramChatID, text: text, name: person.name)
        }
        if !person.slackChannel.isEmpty, !Integrations.slackToken.isEmpty {
            return await Integrations.execute(name: "slack_messaggio",
                                              input: ["canale": person.slackChannel,
                                                      "testo": text])
        }
        if !person.email.isEmpty, let viaMac {
            let prompt = """
            Manda una mail a \(person.email) da parte dell'utente, che sta guidando \
            e l'ha dettata. Scrivi un oggetto sensato e sistema la punteggiatura \
            senza cambiare il contenuto. Testo dettato:

            \(text)
            """
            _ = await viaMac(prompt, nil)
            return "Mail a \(person.name) affidata al Mac."
        }
        return "Non so come raggiungere \(person.name): metti almeno il numero di telefono nella sua scheda."
    }

    private static func telegram(chatID: String, text: String, name: String) async -> String {
        guard let url = URL(string: "https://api.telegram.org/bot\(telegramToken)/sendMessage")
        else { return "Token Telegram non valido." }

        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": chatID, "text": text
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Telegram non raggiungibile."
        }
        if (json["ok"] as? Bool) == true { return "Messaggio mandato a \(name) su Telegram." }
        let desc = (json["description"] as? String) ?? "errore sconosciuto"
        return "Telegram ha rifiutato: \(desc)."
    }
}
